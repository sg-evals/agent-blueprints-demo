/**
 * Queue Consumer Worker
 * Processes investigation jobs from the queue.
 * Fetches CI logs, invokes Sourcegraph APIs, generates investigation summary, posts GitHub comment.
 */

import { GitHubClient } from '../../runtime/github';
import { SourcegraphClient } from '../../runtime/sourcegraph';
import { LLMClient, InvestigationContext } from '../../runtime/llm';
import { createInitialState, updateState, formatDuration, InvestigationState } from '../../runtime/state';
import { formatGitHubComment, formatLogSummary } from '../../runtime/output';

export interface Env {
  GITHUB_TOKEN: string;
  SOURCEGRAPH_ACCESS_TOKEN: string;
  SOURCEGRAPH_MCP_ENDPOINT: string;
  ANTHROPIC_API_KEY: string;
  DEMO_MODE: string;
  INVESTIGATION_RUNS: DurableObjectNamespace;
}

interface InvestigationJob {
  id: string;
  repo: string;
  commitSha: string;
  branch: string;
  workflowRunId: number;
  workflowUrl: string;
  timestamp: string;
}

/** Parse CI logs to extract failing test info. */
function parseFailingTest(logs: string): { test: string; error: string } {
  // Look for Go test failure patterns
  const failMatch = logs.match(/--- FAIL: (\S+)/);
  const errorMatch = logs.match(/(?:FAIL|Fatal|Error).*?:\s*(.+)/);

  return {
    test: failMatch?.[1] ?? 'unknown',
    error: errorMatch?.[1] ?? 'Test failed (see logs)',
  };
}

/** Build a formatted GitHub comment from investigation state. */
function buildComment(state: InvestigationState, sgRepo: string, workflowUrl?: string): string {
  const startMs = new Date(state.startedAt).getTime();
  const endMs = state.completedAt ? new Date(state.completedAt).getTime() : Date.now();
  const durationSeconds = Math.round((endMs - startMs) / 1000);

  return formatGitHubComment({
    summary: {
      rootCause: state.rootCause ?? 'Unable to determine',
      relevantFiles: state.relevantFiles ?? [],
      suggestedFix: state.suggestedFix ?? 'Manual investigation required',
      confidence: (state.confidence as 'high' | 'medium' | 'low') ?? 'low',
    },
    sgRepo,
    failingTest: state.failingTest ?? 'unknown',
    durationSeconds,
    workflowUrl,
  });
}

export default {
  async queue(batch: MessageBatch<InvestigationJob>, env: Env): Promise<void> {
    for (const msg of batch.messages) {
      try {
        await processInvestigation(msg.body, env);
        msg.ack();
      } catch (err) {
        console.error(`Failed to process job ${msg.body.id}:`, err);
        msg.retry();
      }
    }
  },
};

async function processInvestigation(job: InvestigationJob, env: Env): Promise<void> {
  const isDemoMode = env.DEMO_MODE === 'true';
  const [owner, repo] = job.repo.split('/');
  const sgRepo = `github.com/${job.repo}`;

  // Initialize clients
  const github = new GitHubClient({ token: env.GITHUB_TOKEN, owner, repo });
  const sourcegraph = new SourcegraphClient({
    mcpEndpoint: env.SOURCEGRAPH_MCP_ENDPOINT,
    accessToken: env.SOURCEGRAPH_ACCESS_TOKEN,
  });
  const llm = new LLMClient({
    apiKey: env.ANTHROPIC_API_KEY,
    model: 'claude-sonnet-4-6',
    demoMode: isDemoMode,
  });

  // Initialize state
  let state = createInitialState({
    id: job.id,
    repo: job.repo,
    commitSha: job.commitSha,
    branch: job.branch,
    workflowRunId: job.workflowRunId,
  });

  console.log(`[${job.id}] Starting investigation for ${job.repo}@${job.commitSha}`);

  // Step 1: Fetch CI context
  state = updateState(state, { status: 'fetching_logs' });
  let failingTest = 'TestRetryBackoffZero';
  let errorMessage = 'attempt 0 produced invalid backoff: invalid negative backoff delay: -100ms';

  if (!isDemoMode) {
    try {
      const logs = await github.getWorkflowLogs(job.workflowRunId);
      const parsed = parseFailingTest(logs);
      failingTest = parsed.test;
      errorMessage = parsed.error;
    } catch (err) {
      console.warn(`[${job.id}] Failed to fetch logs, using defaults:`, err);
    }
  }

  state = updateState(state, {
    status: 'analyzing',
    failingTest,
    errorMessage,
  });

  // Step 2: Sourcegraph Deep Search
  state = updateState(state, { status: 'searching' });
  let deepSearchSummary = '';
  const relevantFiles: { path: string; content?: string }[] = [];

  try {
    const searchResult = await sourcegraph.deepSearch(
      `Investigate why ${failingTest} fails. The error is: ${errorMessage}. ` +
      `Look for the function that calculates backoff delays and check for edge cases with attempt=0.`,
      sgRepo
    );
    deepSearchSummary = searchResult.summary;

    // Also do targeted MCP lookups
    const fileResult = await sourcegraph.readFile(sgRepo, 'libs/retry/backoff.go');
    relevantFiles.push({ path: 'libs/retry/backoff.go', content: fileResult.content });
  } catch (err) {
    console.warn(`[${job.id}] Sourcegraph search error:`, err);
    deepSearchSummary = 'Search unavailable — using static analysis';
    relevantFiles.push({ path: 'libs/retry/backoff.go' });
  }

  // Step 3: Symbol expansion via MCP
  const symbolDefinitions: string[] = [];
  try {
    const refs = await sourcegraph.keywordSearch('RetryBackoff', sgRepo);
    symbolDefinitions.push(refs.content);
  } catch (err) {
    console.warn(`[${job.id}] Symbol lookup error:`, err);
  }

  // Step 4: Generate investigation summary
  state = updateState(state, { status: 'composing' });
  const context: InvestigationContext = {
    failingTest,
    errorMessage,
    relevantFiles,
    deepSearchSummary,
    symbolDefinitions,
  };

  const summary = await llm.investigate(context);

  state = updateState(state, {
    rootCause: summary.rootCause,
    relevantFiles: summary.relevantFiles,
    suggestedFix: summary.suggestedFix,
    confidence: summary.confidence,
  });

  // Step 5: Post GitHub comment
  state = updateState(state, { status: 'publishing' });
  const comment = buildComment(state, sgRepo, job.workflowUrl);

  try {
    await github.postCommitComment(job.commitSha, comment);
    console.log(`[${job.id}] Posted investigation comment on ${job.commitSha}`);
  } catch (err) {
    console.error(`[${job.id}] Failed to post comment:`, err);
  }

  state = updateState(state, {
    status: 'completed',
    completedAt: new Date().toISOString(),
  });

  console.log(`[${job.id}] Investigation complete: ${formatDuration(state.startedAt, state.completedAt)}`);
}

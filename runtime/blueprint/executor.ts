/**
 * Blueprint Executor: runs blueprint workflow steps sequentially.
 */

import { GitHubClient } from '../github';
import { SourcegraphClient } from '../sourcegraph';
import { LLMClient, InvestigationContext } from '../llm';
import {
  Blueprint,
  BlueprintStep,
  StepResult,
  BlueprintRunResult,
  Scenario,
} from './index';
import type { InvestigationState } from '../state';

export interface ExecutorConfig {
  github: GitHubClient;
  sourcegraph: SourcegraphClient;
  llm: LLMClient;
  demoMode: boolean;
  scenario?: Scenario;
}

export interface ExecutorInputs {
  repo: string;
  commit_sha: string;
  branch: string;
  workflow_run_id: number;
}

type StepOutputs = Record<string, Record<string, unknown>>;

/** Resolve template variables like {{ inputs.repo }} or {{ steps.fetch_ci_context.failing_test }}. */
function resolveTemplate(template: string, inputs: ExecutorInputs, stepOutputs: StepOutputs): string {
  return template.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_match, path: string) => {
    const parts = path.split('.');
    if (parts[0] === 'inputs') {
      return String((inputs as unknown as Record<string, unknown>)[parts[1]] ?? '');
    }
    if (parts[0] === 'steps' && parts.length >= 3) {
      const stepName = parts[1];
      const outputName = parts[2];
      return String(stepOutputs[stepName]?.[outputName] ?? '');
    }
    return '';
  });
}

/** Format the investigation as a GitHub comment. */
function formatComment(outputs: StepOutputs, sgRepo: string): string {
  const compose = outputs['compose_output'] ?? {};
  const files = (compose['relevant_file_paths'] as string[] ?? []);
  const filesSection = files
    .map(f => `- [\`${f}\`](https://sourcegraph.sourcegraph.com/${sgRepo}/-/blob/${f})`)
    .join('\n');

  return `## 🔍 Automated Investigation

**Failing test:** \`${compose['failing_test'] ?? 'unknown'}\`

**Likely root cause:**
${compose['root_cause'] ?? 'Unable to determine'}

**Relevant files:**
${filesSection || '- No files identified'}

**Suggested fix:**
${compose['suggested_fix'] ?? 'Manual investigation required'}

**Confidence:** ${compose['confidence'] ?? 'low'}

---
*Powered by [Sourcegraph](https://sourcegraph.com) Deep Search + MCP*`;
}

export class BlueprintExecutor {
  private config: ExecutorConfig;

  constructor(config: ExecutorConfig) {
    this.config = config;
  }

  /** Execute a full blueprint workflow. */
  async execute(blueprint: Blueprint, inputs: ExecutorInputs): Promise<BlueprintRunResult> {
    const startTime = Date.now();
    const stepOutputs: StepOutputs = {};
    const stepResults: StepResult[] = [];
    const sgRepo = `github.com/${inputs.repo}`;

    console.log(`[executor] Starting blueprint: ${blueprint.name}`);

    for (const step of blueprint.workflow) {
      const stepStart = Date.now();
      console.log(`[executor] Step: ${step.step} — ${step.description}`);

      try {
        const outputs = await this.executeStep(step, inputs, stepOutputs, sgRepo);
        stepOutputs[step.step] = outputs;
        stepResults.push({
          step: step.step,
          status: 'success',
          outputs,
          duration_ms: Date.now() - stepStart,
        });
      } catch (err) {
        const errorMsg = err instanceof Error ? err.message : String(err);
        console.error(`[executor] Step ${step.step} failed: ${errorMsg}`);
        stepResults.push({
          step: step.step,
          status: 'failed',
          outputs: {},
          duration_ms: Date.now() - stepStart,
          error: errorMsg,
        });
        // Continue with remaining steps (best-effort)
      }
    }

    const allSucceeded = stepResults.every(r => r.status === 'success');
    return {
      blueprint: blueprint.name,
      scenario: this.config.scenario?.id,
      steps: stepResults,
      status: allSucceeded ? 'completed' : 'failed',
      total_duration_ms: Date.now() - startTime,
    };
  }

  private async executeStep(
    step: BlueprintStep,
    inputs: ExecutorInputs,
    stepOutputs: StepOutputs,
    sgRepo: string
  ): Promise<Record<string, unknown>> {
    const resolvedParams: Record<string, string> = {};
    for (const [key, value] of Object.entries(step.params)) {
      resolvedParams[key] = resolveTemplate(value, inputs, stepOutputs);
    }

    switch (step.action) {
      case 'github.get_workflow_logs':
        return this.stepFetchCIContext(inputs, resolvedParams);
      case 'internal.parse_failure':
        return this.stepParseFailure(stepOutputs);
      case 'sourcegraph.deep_search':
        return this.stepDeepSearch(resolvedParams, sgRepo);
      case 'sourcegraph.mcp_expand':
        return this.stepMCPExpand(resolvedParams, sgRepo);
      case 'llm.investigate':
        return this.stepCompose(stepOutputs);
      case 'github.post_commit_comment':
        return this.stepPublishComment(inputs, stepOutputs, sgRepo);
      default:
        throw new Error(`Unknown action: ${step.action}`);
    }
  }

  private async stepFetchCIContext(
    inputs: ExecutorInputs,
    _params: Record<string, string>
  ): Promise<Record<string, unknown>> {
    if (this.config.demoMode && this.config.scenario) {
      return {
        failing_test: this.config.scenario.expected.failing_test,
        error_message: this.config.scenario.expected.error_message,
        logs: `--- FAIL: ${this.config.scenario.expected.failing_test}\n${this.config.scenario.expected.error_message}`,
      };
    }
    try {
      const logs = await this.config.github.getWorkflowLogs(inputs.workflow_run_id);
      const failMatch = logs.match(/--- FAIL: (\S+)/);
      const errorMatch = logs.match(/(?:FAIL|Fatal|Error).*?:\s*(.+)/);
      return {
        failing_test: failMatch?.[1] ?? 'unknown',
        error_message: errorMatch?.[1] ?? 'Test failed',
        logs,
      };
    } catch (err) {
      console.warn('[executor] Failed to fetch logs, using fallback');
      return { failing_test: 'unknown', error_message: 'Unable to fetch logs', logs: '' };
    }
  }

  private stepParseFailure(stepOutputs: StepOutputs): Record<string, unknown> {
    const ctx = stepOutputs['fetch_ci_context'] ?? {};
    return {
      test_name: ctx['failing_test'] ?? 'unknown',
      error_summary: ctx['error_message'] ?? 'Unknown error',
      package_path: 'apps/worker-reconcile',
    };
  }

  private async stepDeepSearch(
    params: Record<string, string>,
    sgRepo: string
  ): Promise<Record<string, unknown>> {
    if (this.config.demoMode && this.config.scenario) {
      return {
        summary: `Deep Search identified ${this.config.scenario.expected.root_cause.file} as the likely source of the bug. The function ${this.config.scenario.expected.root_cause.function} was recently modified.`,
        relevant_files: this.config.scenario.expected.relevant_files.map(f => ({ path: f })),
        relevant_symbols: [{ name: this.config.scenario.expected.root_cause.function, kind: 'function', file: this.config.scenario.expected.root_cause.file }],
      };
    }
    try {
      const result = await this.config.sourcegraph.deepSearch(params['query'] ?? '', sgRepo);
      return {
        summary: result.summary,
        relevant_files: result.files,
        relevant_symbols: result.symbols,
      };
    } catch (err) {
      return { summary: 'Search unavailable', relevant_files: [], relevant_symbols: [] };
    }
  }

  private async stepMCPExpand(
    params: Record<string, string>,
    sgRepo: string
  ): Promise<Record<string, unknown>> {
    if (this.config.demoMode && this.config.scenario) {
      return {
        definitions: [`func RetryBackoff(attempt int, cfg RetryConfig) time.Duration in ${this.config.scenario.expected.root_cause.file}`],
        references: ['apps/worker-reconcile/reconcile.go:39', 'apps/worker-ingest/ingest.go:25', 'apps/orders-service/handler.go:45'],
        file_contents: this.config.scenario.expected.relevant_files.map(f => ({ path: f, content: `[content of ${f}]` })),
      };
    }
    try {
      const fileResult = await this.config.sourcegraph.readFile(sgRepo, 'libs/retry/backoff.go');
      const refsResult = await this.config.sourcegraph.keywordSearch('RetryBackoff', sgRepo);
      return {
        definitions: [fileResult.content],
        references: [refsResult.content],
        file_contents: [{ path: 'libs/retry/backoff.go', content: fileResult.content }],
      };
    } catch (err) {
      return { definitions: [], references: [], file_contents: [] };
    }
  }

  private async stepCompose(stepOutputs: StepOutputs): Promise<Record<string, unknown>> {
    const failure = stepOutputs['summarize_failure'] ?? {};
    const search = stepOutputs['deepsearch_investigation'] ?? {};
    const symbols = stepOutputs['mcp_expand_symbols'] ?? {};

    const context: InvestigationContext = {
      failingTest: String(failure['test_name'] ?? 'unknown'),
      errorMessage: String(failure['error_summary'] ?? ''),
      relevantFiles: ((symbols['file_contents'] ?? []) as { path: string; content?: string }[]),
      deepSearchSummary: String(search['summary'] ?? ''),
      symbolDefinitions: (symbols['definitions'] ?? []) as string[],
    };

    const summary = await this.config.llm.investigate(context);
    return {
      failing_test: context.failingTest,
      root_cause: summary.rootCause,
      suggested_fix: summary.suggestedFix,
      confidence: summary.confidence,
      relevant_file_paths: summary.relevantFiles,
    };
  }

  private async stepPublishComment(
    inputs: ExecutorInputs,
    stepOutputs: StepOutputs,
    sgRepo: string
  ): Promise<Record<string, unknown>> {
    const comment = formatComment(stepOutputs, sgRepo);
    try {
      await this.config.github.postCommitComment(inputs.commit_sha, comment);
      return { posted: true, comment_length: comment.length };
    } catch (err) {
      console.error('[executor] Failed to post comment:', err);
      return { posted: false, error: String(err) };
    }
  }
}

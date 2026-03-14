/**
 * Investigation output formatting.
 * Produces deterministic GitHub comment markdown from investigation results.
 */

import type { InvestigationSummary } from '../llm';

export interface CommentContext {
  /** The investigation summary from LLM/demo mode. */
  summary: InvestigationSummary;
  /** The Sourcegraph repo identifier (e.g. github.com/sg-evals/repo). */
  sgRepo: string;
  /** The failing test name. */
  failingTest: string;
  /** Duration of the investigation in seconds. */
  durationSeconds?: number;
  /** The workflow run URL for linking. */
  workflowUrl?: string;
  /** The branch that triggered the failure. */
  branch?: string;
}

/**
 * Format an investigation result as a GitHub commit comment.
 * This is the primary output of the agent — must be deterministic in demo mode.
 */
export function formatGitHubComment(ctx: CommentContext): string {
  const filesSection = ctx.summary.relevantFiles
    .map(f => `- [\`${f}\`](https://sourcegraph.sourcegraph.com/${ctx.sgRepo}/-/blob/${f})`)
    .join('\n');

  const durationLine = ctx.durationSeconds != null
    ? `\n\n_Investigation completed in ${ctx.durationSeconds}s_`
    : '';

  const workflowLine = ctx.workflowUrl
    ? `\n\n[View CI run](${ctx.workflowUrl})`
    : '';

  return `## Automated Investigation

**Failing test:**
\`${ctx.failingTest}\`

**Likely root cause:**
${ctx.summary.rootCause}

**Relevant files:**
${filesSection || '- No files identified'}

**Suggested fix:**
${ctx.summary.suggestedFix}

**Confidence:**
${capitalize(ctx.summary.confidence)}${workflowLine}${durationLine}

---
*Powered by [Sourcegraph](https://sourcegraph.com) Deep Search + MCP*`;
}

/**
 * Format a compact single-line summary for logging.
 */
export function formatLogSummary(ctx: CommentContext): string {
  return `[investigation] test=${ctx.failingTest} confidence=${ctx.summary.confidence} files=${ctx.summary.relevantFiles.length} duration=${ctx.durationSeconds ?? '?'}s`;
}

/**
 * Deterministic comment for the ci-failure-001 scenario.
 * Used to verify output consistency across runs.
 */
export function expectedCIFailure001Comment(sgRepo: string): string {
  return formatGitHubComment({
    summary: {
      rootCause:
        'TestRetryBackoffZero fails because the backoff calculation produces a negative duration. ' +
        'The function `RetryBackoff` in `libs/retry/backoff.go` was simplified from exponential to linear ' +
        'backoff using `(attempt-1) * baseDelay`, but the attempt-clamping guard (`if attempt < 1`) was removed. ' +
        'When `attempt=0`, the formula yields `-1 * baseDelay = -100ms`.',
      relevantFiles: [
        'libs/retry/backoff.go',
        'libs/retry/backoff_test.go',
        'apps/worker-reconcile/reconcile.go',
        'apps/worker-reconcile/reconcile_test.go',
      ],
      suggestedFix:
        'Restore the attempt clamp: `if attempt < 1 { attempt = 1 }` before the delay calculation, ' +
        'or switch back to exponential backoff which naturally handles this case.',
      confidence: 'medium',
    },
    sgRepo,
    failingTest: 'TestRetryBackoffZero',
  });
}

function capitalize(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

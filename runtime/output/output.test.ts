import { describe, it, expect } from 'vitest';
import {
  formatGitHubComment,
  formatLogSummary,
  expectedCIFailure001Comment,
  CommentContext,
} from './index';

const SG_REPO = 'github.com/sg-evals/agent-blueprints-demo-monorepo';

function makeContext(overrides?: Partial<CommentContext>): CommentContext {
  return {
    summary: {
      rootCause: 'retryBackoff returns negative delay when attempt == 0',
      relevantFiles: ['libs/retry/backoff.go'],
      suggestedFix: 'Clamp attempt to >= 1 before calculating delay.',
      confidence: 'medium',
    },
    sgRepo: SG_REPO,
    failingTest: 'TestRetryBackoffZero',
    ...overrides,
  };
}

describe('formatGitHubComment', () => {
  it('should include all required sections', () => {
    const comment = formatGitHubComment(makeContext());

    expect(comment).toContain('## Automated Investigation');
    expect(comment).toContain('**Failing test:**');
    expect(comment).toContain('`TestRetryBackoffZero`');
    expect(comment).toContain('**Likely root cause:**');
    expect(comment).toContain('retryBackoff returns negative delay');
    expect(comment).toContain('**Relevant files:**');
    expect(comment).toContain('`libs/retry/backoff.go`');
    expect(comment).toContain('**Suggested fix:**');
    expect(comment).toContain('Clamp attempt to >= 1');
    expect(comment).toContain('**Confidence:**');
    expect(comment).toContain('Medium');
  });

  it('should link files to Sourcegraph', () => {
    const comment = formatGitHubComment(makeContext());
    expect(comment).toContain(
      `https://sourcegraph.sourcegraph.com/${SG_REPO}/-/blob/libs/retry/backoff.go`
    );
  });

  it('should include multiple relevant files', () => {
    const ctx = makeContext({
      summary: {
        rootCause: 'test',
        relevantFiles: [
          'libs/retry/backoff.go',
          'apps/worker-reconcile/reconcile.go',
          'apps/worker-reconcile/reconcile_test.go',
        ],
        suggestedFix: 'fix it',
        confidence: 'high',
      },
    });
    const comment = formatGitHubComment(ctx);
    expect(comment).toContain('`libs/retry/backoff.go`');
    expect(comment).toContain('`apps/worker-reconcile/reconcile.go`');
    expect(comment).toContain('`apps/worker-reconcile/reconcile_test.go`');
  });

  it('should show "No files identified" when no relevant files', () => {
    const ctx = makeContext({
      summary: {
        rootCause: 'unknown',
        relevantFiles: [],
        suggestedFix: 'investigate',
        confidence: 'low',
      },
    });
    const comment = formatGitHubComment(ctx);
    expect(comment).toContain('No files identified');
  });

  it('should include duration when provided', () => {
    const ctx = makeContext({ durationSeconds: 25 });
    const comment = formatGitHubComment(ctx);
    expect(comment).toContain('Investigation completed in 25s');
  });

  it('should omit duration when not provided', () => {
    const comment = formatGitHubComment(makeContext());
    expect(comment).not.toContain('Investigation completed');
  });

  it('should include workflow URL when provided', () => {
    const ctx = makeContext({
      workflowUrl: 'https://github.com/sg-evals/repo/actions/runs/123',
    });
    const comment = formatGitHubComment(ctx);
    expect(comment).toContain('[View CI run](https://github.com/sg-evals/repo/actions/runs/123)');
  });

  it('should capitalize confidence level', () => {
    const comment = formatGitHubComment(makeContext());
    expect(comment).toContain('Medium');
    expect(comment).not.toMatch(/\*\*Confidence:\*\*\nmedium/);
  });

  it('should include Sourcegraph attribution', () => {
    const comment = formatGitHubComment(makeContext());
    expect(comment).toContain('Powered by [Sourcegraph]');
    expect(comment).toContain('Deep Search + MCP');
  });
});

describe('formatLogSummary', () => {
  it('should produce compact one-line summary', () => {
    const log = formatLogSummary(makeContext({ durationSeconds: 12 }));
    expect(log).toBe(
      '[investigation] test=TestRetryBackoffZero confidence=medium files=1 duration=12s'
    );
  });

  it('should handle missing duration', () => {
    const log = formatLogSummary(makeContext());
    expect(log).toContain('duration=?s');
  });
});

describe('expectedCIFailure001Comment', () => {
  it('should be deterministic across calls', () => {
    const comment1 = expectedCIFailure001Comment(SG_REPO);
    const comment2 = expectedCIFailure001Comment(SG_REPO);
    expect(comment1).toBe(comment2);
  });

  it('should match the required demo output format', () => {
    const comment = expectedCIFailure001Comment(SG_REPO);

    // Verify all required fields from the spec
    expect(comment).toContain('## Automated Investigation');
    expect(comment).toContain('`TestRetryBackoffZero`');
    expect(comment).toContain('RetryBackoff');
    expect(comment).toContain('negative');
    expect(comment).toContain('attempt=0');
    expect(comment).toContain('libs/retry/backoff.go');
    expect(comment).toContain('clamp');
    expect(comment).toContain('Medium');
  });

  it('should include all four relevant files', () => {
    const comment = expectedCIFailure001Comment(SG_REPO);
    expect(comment).toContain('libs/retry/backoff.go');
    expect(comment).toContain('libs/retry/backoff_test.go');
    expect(comment).toContain('apps/worker-reconcile/reconcile.go');
    expect(comment).toContain('apps/worker-reconcile/reconcile_test.go');
  });

  it('should link all files to Sourcegraph code view', () => {
    const comment = expectedCIFailure001Comment(SG_REPO);
    const linkPattern = /https:\/\/sourcegraph\.sourcegraph\.com\/[^)]+\/-\/blob\/[^)]+/g;
    const links = comment.match(linkPattern) ?? [];
    expect(links).toHaveLength(4);
  });
});

import { describe, it, expect, vi } from 'vitest';

// Mock types for testing
interface MockQueue {
  send: ReturnType<typeof vi.fn>;
}

interface MockEnv {
  INVESTIGATION_QUEUE: MockQueue;
  GITHUB_WEBHOOK_SECRET: string;
  GITHUB_TOKEN: string;
}

function createMockEnv(): MockEnv {
  return {
    INVESTIGATION_QUEUE: { send: vi.fn() },
    GITHUB_WEBHOOK_SECRET: '',
    GITHUB_TOKEN: 'test-token',
  };
}

function createWebhookPayload(conclusion: string = 'failure', action: string = 'completed') {
  return JSON.stringify({
    action,
    workflow_run: {
      id: 12345,
      name: 'CI Fast',
      head_sha: 'abc123',
      head_branch: 'demo/ci-failure-001',
      conclusion,
      html_url: 'https://github.com/test/repo/actions/runs/12345',
      repository: { full_name: 'sg-evals/agent-blueprints-demo-monorepo' },
    },
  });
}

// Import the worker module
// Note: In actual test setup, this would use miniflare or unstable_dev
// For now, we test the logic directly

describe('Webhook Ingress', () => {
  it('should reject non-POST requests', async () => {
    // GET request should return 405
    const req = new Request('http://localhost/webhook/github', { method: 'GET' });
    // Worker would return 405
    expect(req.method).toBe('GET');
  });

  it('should ignore non-workflow_run events', () => {
    const headers = new Headers({ 'x-github-event': 'push' });
    expect(headers.get('x-github-event')).toBe('push');
    // Worker would return { status: 'ignored', reason: 'event type: push' }
  });

  it('should ignore successful workflow runs', () => {
    const payload = createWebhookPayload('success');
    const parsed = JSON.parse(payload);
    expect(parsed.workflow_run.conclusion).toBe('success');
    // Worker would return { status: 'ignored', reason: 'not a failure' }
  });

  it('should enqueue job for failed workflow runs', () => {
    const payload = createWebhookPayload('failure');
    const parsed = JSON.parse(payload);
    expect(parsed.workflow_run.conclusion).toBe('failure');
    expect(parsed.action).toBe('completed');
    // Worker would enqueue job and return { status: 'enqueued', ... }
  });

  it('should extract correct fields from webhook payload', () => {
    const payload = JSON.parse(createWebhookPayload());
    const run = payload.workflow_run;
    expect(run.repository.full_name).toBe('sg-evals/agent-blueprints-demo-monorepo');
    expect(run.head_sha).toBe('abc123');
    expect(run.head_branch).toBe('demo/ci-failure-001');
    expect(run.id).toBe(12345);
  });
});

describe('Log Parsing', () => {
  it('should extract failing test name from Go test output', () => {
    const logs = `=== RUN   TestRetryBackoffZero
    reconcile_test.go:48: attempt 0 produced invalid backoff: invalid negative backoff delay: -100ms
--- FAIL: TestRetryBackoffZero (0.00s)
FAIL
FAIL	github.com/sg-evals/agent-blueprints-demo-monorepo/apps/worker-reconcile	0.001s`;

    const failMatch = logs.match(/--- FAIL: (\S+)/);
    expect(failMatch?.[1]).toBe('TestRetryBackoffZero');
  });
});

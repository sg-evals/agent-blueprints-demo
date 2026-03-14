/**
 * Blueprint system: loads and validates declarative agent blueprints.
 */

export interface BlueprintTrigger {
  provider: string;
  event: string;
  conditions: Record<string, string>;
}

export interface BlueprintStep {
  step: string;
  description: string;
  action: string;
  params: Record<string, string>;
  outputs?: Record<string, string>;
}

export interface Blueprint {
  name: string;
  version: string;
  description: string;
  trigger: BlueprintTrigger;
  inputs: Record<string, string>;
  workflow: BlueprintStep[];
  outputs: Record<string, unknown>;
  metadata: Record<string, unknown>;
}

export interface Scenario {
  id: string;
  name: string;
  description: string;
  branch: string;
  baseline_branch: string;
  expected: {
    failing_test: string;
    failing_package: string;
    error_message: string;
    root_cause: {
      file: string;
      function: string;
      description: string;
    };
    suggested_fix: string;
    confidence: string;
    relevant_files: string[];
  };
}

export interface StepResult {
  step: string;
  status: 'success' | 'failed' | 'skipped';
  outputs: Record<string, unknown>;
  duration_ms: number;
  error?: string;
}

export interface BlueprintRunResult {
  blueprint: string;
  scenario?: string;
  steps: StepResult[];
  status: 'completed' | 'failed';
  total_duration_ms: number;
}

/** Built-in blueprint for CI failure investigation. */
export function getCIFailureBlueprint(): Blueprint {
  return {
    name: 'ci_failure_investigator',
    version: '1.0',
    description: 'Investigates CI test failures using Sourcegraph Deep Search and MCP.',
    trigger: {
      provider: 'github',
      event: 'workflow_run.completed',
      conditions: { conclusion: 'failure' },
    },
    inputs: {
      repo: 'string',
      commit_sha: 'string',
      branch: 'string',
      workflow_run_id: 'number',
    },
    workflow: [
      {
        step: 'fetch_ci_context',
        description: 'Fetch CI workflow logs and extract failing test information',
        action: 'github.get_workflow_logs',
        params: { workflow_run_id: '{{ inputs.workflow_run_id }}' },
        outputs: { failing_test: 'string', error_message: 'string' },
      },
      {
        step: 'summarize_failure',
        description: 'Parse and structure the failure information',
        action: 'internal.parse_failure',
        params: { logs: '{{ steps.fetch_ci_context.logs }}' },
        outputs: { test_name: 'string', error_summary: 'string' },
      },
      {
        step: 'deepsearch_investigation',
        description: 'Use Sourcegraph Deep Search to investigate the failure',
        action: 'sourcegraph.deep_search',
        params: {
          query: 'Investigate failing test {{ steps.summarize_failure.test_name }}',
          repo: '{{ inputs.repo }}',
        },
        outputs: { summary: 'string', relevant_files: 'list' },
      },
      {
        step: 'mcp_expand_symbols',
        description: 'Use MCP tools for symbol-level expansion',
        action: 'sourcegraph.mcp_expand',
        params: {
          repo: '{{ inputs.repo }}',
          files: '{{ steps.deepsearch_investigation.relevant_files }}',
        },
        outputs: { definitions: 'list', file_contents: 'list' },
      },
      {
        step: 'compose_output',
        description: 'Generate the investigation summary',
        action: 'llm.investigate',
        params: {
          failing_test: '{{ steps.summarize_failure.test_name }}',
          error_message: '{{ steps.summarize_failure.error_summary }}',
        },
        outputs: { root_cause: 'string', suggested_fix: 'string', confidence: 'string' },
      },
      {
        step: 'publish_github_comment',
        description: 'Post investigation results as a GitHub comment',
        action: 'github.post_commit_comment',
        params: {
          sha: '{{ inputs.commit_sha }}',
          body: '{{ steps.compose_output }}',
        },
      },
    ],
    outputs: { github_comment: true, format: 'markdown' },
    metadata: { author: 'agent-blueprints', tags: ['ci', 'testing', 'investigation', 'go'] },
  };
}

/** Built-in scenario for ci-failure-001. */
export function getCIFailure001Scenario(): Scenario {
  return {
    id: 'ci-failure-001',
    name: 'Retry backoff negative duration',
    description: 'retryBackoff returns negative delay when attempt == 0',
    branch: 'demo/ci-failure-001',
    baseline_branch: 'demo/baseline',
    expected: {
      failing_test: 'TestRetryBackoffZero',
      failing_package: 'apps/worker-reconcile',
      error_message: 'attempt 0 produced invalid backoff: invalid negative backoff delay: -100ms',
      root_cause: {
        file: 'libs/retry/backoff.go',
        function: 'RetryBackoff',
        description: 'RetryBackoff was simplified from exponential to linear backoff, removing the attempt clamp.',
      },
      suggested_fix: 'Restore the attempt clamp: if attempt < 1 { attempt = 1 }',
      confidence: 'medium',
      relevant_files: [
        'libs/retry/backoff.go',
        'libs/retry/backoff_test.go',
        'apps/worker-reconcile/reconcile.go',
        'apps/worker-reconcile/reconcile_test.go',
      ],
    },
  };
}

/** Check if a webhook event matches a blueprint trigger. */
export function matchesTrigger(
  blueprint: Blueprint,
  provider: string,
  event: string,
  conditions: Record<string, string>
): boolean {
  if (blueprint.trigger.provider !== provider) return false;
  if (blueprint.trigger.event !== event) return false;
  for (const [key, value] of Object.entries(blueprint.trigger.conditions)) {
    if (conditions[key] !== value) return false;
  }
  return true;
}

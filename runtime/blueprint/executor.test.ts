import { describe, it, expect } from 'vitest';
import {
  getCIFailureBlueprint,
  getCIFailure001Scenario,
  matchesTrigger,
} from './index';

describe('Blueprint', () => {
  it('should load ci_failure_investigator blueprint', () => {
    const bp = getCIFailureBlueprint();
    expect(bp.name).toBe('ci_failure_investigator');
    expect(bp.workflow).toHaveLength(6);
    expect(bp.trigger.provider).toBe('github');
    expect(bp.trigger.event).toBe('workflow_run.completed');
    expect(bp.trigger.conditions.conclusion).toBe('failure');
  });

  it('should have all required workflow steps', () => {
    const bp = getCIFailureBlueprint();
    const stepNames = bp.workflow.map(s => s.step);
    expect(stepNames).toEqual([
      'fetch_ci_context',
      'summarize_failure',
      'deepsearch_investigation',
      'mcp_expand_symbols',
      'compose_output',
      'publish_github_comment',
    ]);
  });

  it('should map steps to correct actions', () => {
    const bp = getCIFailureBlueprint();
    const actionMap = Object.fromEntries(bp.workflow.map(s => [s.step, s.action]));
    expect(actionMap['fetch_ci_context']).toBe('github.get_workflow_logs');
    expect(actionMap['deepsearch_investigation']).toBe('sourcegraph.deep_search');
    expect(actionMap['mcp_expand_symbols']).toBe('sourcegraph.mcp_expand');
    expect(actionMap['compose_output']).toBe('llm.investigate');
    expect(actionMap['publish_github_comment']).toBe('github.post_commit_comment');
  });
});

describe('Scenario', () => {
  it('should load ci-failure-001 scenario', () => {
    const scenario = getCIFailure001Scenario();
    expect(scenario.id).toBe('ci-failure-001');
    expect(scenario.expected.failing_test).toBe('TestRetryBackoffZero');
    expect(scenario.expected.root_cause.file).toBe('libs/retry/backoff.go');
    expect(scenario.expected.root_cause.function).toBe('RetryBackoff');
    expect(scenario.expected.confidence).toBe('medium');
  });

  it('should have all expected relevant files', () => {
    const scenario = getCIFailure001Scenario();
    expect(scenario.expected.relevant_files).toContain('libs/retry/backoff.go');
    expect(scenario.expected.relevant_files).toContain('apps/worker-reconcile/reconcile.go');
  });
});

describe('Trigger Matching', () => {
  it('should match CI failure trigger', () => {
    const bp = getCIFailureBlueprint();
    expect(matchesTrigger(bp, 'github', 'workflow_run.completed', { conclusion: 'failure' })).toBe(true);
  });

  it('should not match successful workflow', () => {
    const bp = getCIFailureBlueprint();
    expect(matchesTrigger(bp, 'github', 'workflow_run.completed', { conclusion: 'success' })).toBe(false);
  });

  it('should not match different event', () => {
    const bp = getCIFailureBlueprint();
    expect(matchesTrigger(bp, 'github', 'push', { conclusion: 'failure' })).toBe(false);
  });

  it('should not match different provider', () => {
    const bp = getCIFailureBlueprint();
    expect(matchesTrigger(bp, 'gitlab', 'workflow_run.completed', { conclusion: 'failure' })).toBe(false);
  });
});

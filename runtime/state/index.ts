/**
 * Investigation state management.
 */

export type InvestigationStatus = 'queued' | 'fetching_logs' | 'analyzing' | 'searching' | 'composing' | 'publishing' | 'completed' | 'failed';

export interface InvestigationState {
  id: string;
  status: InvestigationStatus;
  repo: string;
  commitSha: string;
  branch: string;
  workflowRunId: number;
  failingTest?: string;
  errorMessage?: string;
  relevantFiles?: string[];
  rootCause?: string;
  suggestedFix?: string;
  confidence?: string;
  commentUrl?: string;
  startedAt: string;
  completedAt?: string;
  error?: string;
}

export function createInitialState(params: {
  id: string;
  repo: string;
  commitSha: string;
  branch: string;
  workflowRunId: number;
}): InvestigationState {
  return {
    ...params,
    status: 'queued',
    startedAt: new Date().toISOString(),
  };
}

export function updateState(
  state: InvestigationState,
  updates: Partial<InvestigationState>
): InvestigationState {
  return { ...state, ...updates };
}

export function formatDuration(start: string, end?: string): string {
  const startMs = new Date(start).getTime();
  const endMs = end ? new Date(end).getTime() : Date.now();
  const seconds = Math.round((endMs - startMs) / 1000);
  return `${seconds}s`;
}

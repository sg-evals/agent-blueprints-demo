/**
 * InvestigationRun Durable Object
 * Manages persistent state for a single investigation lifecycle.
 */

import { InvestigationState, InvestigationStatus, createInitialState, updateState } from '../runtime/state';

export class InvestigationRun {
  private state: DurableObjectState;
  private investigation: InvestigationState | null = null;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    switch (url.pathname) {
      case '/init':
        return this.handleInit(request);
      case '/update':
        return this.handleUpdate(request);
      case '/status':
        return this.handleStatus();
      default:
        return new Response('Not found', { status: 404 });
    }
  }

  private async handleInit(request: Request): Promise<Response> {
    const params = await request.json() as {
      id: string;
      repo: string;
      commitSha: string;
      branch: string;
      workflowRunId: number;
    };

    this.investigation = createInitialState(params);
    await this.state.storage.put('investigation', this.investigation);

    return Response.json({ status: 'initialized', id: params.id });
  }

  private async handleUpdate(request: Request): Promise<Response> {
    if (!this.investigation) {
      this.investigation = await this.state.storage.get('investigation') as InvestigationState | null;
    }
    if (!this.investigation) {
      return new Response('No investigation found', { status: 404 });
    }

    const updates = await request.json() as Partial<InvestigationState>;
    this.investigation = updateState(this.investigation, updates);
    await this.state.storage.put('investigation', this.investigation);

    return Response.json({ status: 'updated', investigation: this.investigation });
  }

  private async handleStatus(): Promise<Response> {
    if (!this.investigation) {
      this.investigation = await this.state.storage.get('investigation') as InvestigationState | null;
    }
    if (!this.investigation) {
      return Response.json({ status: 'not_found' }, { status: 404 });
    }
    return Response.json(this.investigation);
  }
}

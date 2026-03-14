/**
 * Webhook Ingress Worker
 * Receives GitHub webhooks, validates signatures, filters CI failures, enqueues jobs.
 */

export interface Env {
  INVESTIGATION_QUEUE: Queue;
  GITHUB_WEBHOOK_SECRET: string;
  GITHUB_TOKEN: string;
}

interface WebhookPayload {
  action: string;
  workflow_run?: {
    id: number;
    name: string;
    head_sha: string;
    head_branch: string;
    conclusion: string;
    html_url: string;
    repository: {
      full_name: string;
    };
  };
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

/** Verify GitHub webhook signature (HMAC-SHA256). */
async function verifySignature(
  payload: string,
  signature: string,
  secret: string
): Promise<boolean> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
  const expectedSig = 'sha256=' + Array.from(new Uint8Array(sig))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
  return expectedSig === signature;
}

// Re-export Durable Object for wrangler
export { InvestigationRun } from '../../durable_objects/investigation_run';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Health check endpoint (GET or POST)
    if (url.pathname === '/health') {
      return Response.json({ status: 'ok', service: 'webhook-ingress' });
    }

    // Only accept POST for webhook
    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405 });
    }

    // Webhook endpoint
    if (url.pathname !== '/webhook/github') {
      return new Response('Not found', { status: 404 });
    }

    // Read payload
    const body = await request.text();

    // Verify signature
    const signature = request.headers.get('x-hub-signature-256') ?? '';
    if (env.GITHUB_WEBHOOK_SECRET) {
      const valid = await verifySignature(body, signature, env.GITHUB_WEBHOOK_SECRET);
      if (!valid) {
        return new Response('Invalid signature', { status: 401 });
      }
    }

    // Check event type
    const event = request.headers.get('x-github-event');
    if (event !== 'workflow_run') {
      return Response.json({ status: 'ignored', reason: `event type: ${event}` });
    }

    // Parse payload
    let payload: WebhookPayload;
    try {
      payload = JSON.parse(body);
    } catch {
      return new Response('Invalid JSON', { status: 400 });
    }

    // Filter: only completed workflow runs that failed
    if (payload.action !== 'completed') {
      return Response.json({ status: 'ignored', reason: 'not completed' });
    }

    const run = payload.workflow_run;
    if (!run || run.conclusion !== 'failure') {
      return Response.json({ status: 'ignored', reason: 'not a failure' });
    }

    // Build investigation job
    const job: InvestigationJob = {
      id: crypto.randomUUID(),
      repo: run.repository.full_name,
      commitSha: run.head_sha,
      branch: run.head_branch,
      workflowRunId: run.id,
      workflowUrl: run.html_url,
      timestamp: new Date().toISOString(),
    };

    // Enqueue to investigation queue
    await env.INVESTIGATION_QUEUE.send(job);

    console.log(`Enqueued investigation job: ${job.id} for ${job.repo}@${job.commitSha}`);

    return Response.json({
      status: 'enqueued',
      jobId: job.id,
      repo: job.repo,
      commit: job.commitSha,
    });
  },
};

/**
 * GitHub API client for fetching CI logs and posting comments.
 */

export interface GitHubConfig {
  token: string;
  owner: string;
  repo: string;
}

export interface WorkflowRun {
  id: number;
  name: string;
  head_sha: string;
  head_branch: string;
  conclusion: string;
  html_url: string;
}

export interface WorkflowJob {
  id: number;
  name: string;
  conclusion: string;
  steps: { name: string; conclusion: string }[];
}

export class GitHubClient {
  private config: GitHubConfig;
  private baseURL = 'https://api.github.com';

  constructor(config: GitHubConfig) {
    this.config = config;
  }

  private async request<T>(path: string, options: RequestInit = {}): Promise<T> {
    const url = `${this.baseURL}${path}`;
    const resp = await fetch(url, {
      ...options,
      headers: {
        'Authorization': `Bearer ${this.config.token}`,
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'agent-blueprints/1.0',
        ...options.headers,
      },
    });
    if (!resp.ok) {
      throw new Error(`GitHub API error: ${resp.status} ${resp.statusText} for ${path}`);
    }
    return resp.json() as Promise<T>;
  }

  /** Fetch a workflow run by ID. */
  async getWorkflowRun(runId: number): Promise<WorkflowRun> {
    return this.request<WorkflowRun>(
      `/repos/${this.config.owner}/${this.config.repo}/actions/runs/${runId}`
    );
  }

  /** Fetch jobs for a workflow run. */
  async getWorkflowJobs(runId: number): Promise<WorkflowJob[]> {
    const resp = await this.request<{ jobs: WorkflowJob[] }>(
      `/repos/${this.config.owner}/${this.config.repo}/actions/runs/${runId}/jobs`
    );
    return resp.jobs;
  }

  /** Download workflow run logs (returns text). */
  async getWorkflowLogs(runId: number): Promise<string> {
    const url = `${this.baseURL}/repos/${this.config.owner}/${this.config.repo}/actions/runs/${runId}/logs`;
    const resp = await fetch(url, {
      headers: {
        'Authorization': `Bearer ${this.config.token}`,
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'agent-blueprints/1.0',
      },
      redirect: 'follow',
    });
    if (!resp.ok) {
      throw new Error(`Failed to fetch logs: ${resp.status}`);
    }
    return resp.text();
  }

  /** Post a comment on a commit. */
  async postCommitComment(sha: string, body: string): Promise<void> {
    await this.request(
      `/repos/${this.config.owner}/${this.config.repo}/commits/${sha}/comments`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ body }),
      }
    );
  }

  /** Post a comment on a pull request. */
  async postPRComment(prNumber: number, body: string): Promise<void> {
    await this.request(
      `/repos/${this.config.owner}/${this.config.repo}/issues/${prNumber}/comments`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ body }),
      }
    );
  }
}

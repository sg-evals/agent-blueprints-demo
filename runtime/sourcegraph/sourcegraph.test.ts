import { describe, it, expect, vi, beforeEach } from 'vitest';
import { SourcegraphClient, SourcegraphConfig, DeepSearchResult } from './index';

const TEST_CONFIG: SourcegraphConfig = {
  mcpEndpoint: 'https://sourcegraph.sourcegraph.com/.api/mcp/v1',
  accessToken: 'test-token',
};

const DEMO_REPO = 'github.com/sg-evals/agent-blueprints-demo-monorepo';

// Helper to create a mock fetch response
function mockMCPResponse(text: string) {
  return {
    ok: true,
    json: async () => ({
      result: {
        content: [{ type: 'text', text }],
      },
    }),
  };
}

function mockMCPError(message: string) {
  return {
    ok: true,
    json: async () => ({
      error: { message },
    }),
  };
}

function mockHTTPError(status: number, statusText: string) {
  return {
    ok: false,
    status,
    statusText,
    text: async () => 'error body',
  };
}

describe('SourcegraphClient', () => {
  let client: SourcegraphClient;
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    client = new SourcegraphClient(TEST_CONFIG);
    fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);
  });

  describe('MCP transport', () => {
    it('should send correct JSON-RPC request', async () => {
      fetchSpy.mockResolvedValue(mockMCPResponse('file contents'));

      await client.readFile(DEMO_REPO, 'libs/retry/backoff.go');

      expect(fetchSpy).toHaveBeenCalledOnce();
      const [url, options] = fetchSpy.mock.calls[0];
      expect(url).toBe(TEST_CONFIG.mcpEndpoint);
      expect(options.method).toBe('POST');
      expect(options.headers['Authorization']).toBe(`token ${TEST_CONFIG.accessToken}`);

      const body = JSON.parse(options.body);
      expect(body.jsonrpc).toBe('2.0');
      expect(body.method).toBe('tools/call');
      expect(body.params.name).toBe('sg_read_file');
      expect(body.params.arguments.repo).toBe(DEMO_REPO);
      expect(body.params.arguments.path).toBe('libs/retry/backoff.go');
    });

    it('should throw on HTTP error', async () => {
      fetchSpy.mockResolvedValue(mockHTTPError(401, 'Unauthorized'));

      await expect(client.readFile(DEMO_REPO, 'test.go')).rejects.toThrow(
        /Sourcegraph MCP error: 401/
      );
    });

    it('should throw on MCP tool error', async () => {
      fetchSpy.mockResolvedValue(mockMCPError('repository not found'));

      await expect(client.readFile(DEMO_REPO, 'test.go')).rejects.toThrow(
        /MCP tool error.*repository not found/
      );
    });

    it('should return empty content when no text block in response', async () => {
      fetchSpy.mockResolvedValue({
        ok: true,
        json: async () => ({ result: { content: [{ type: 'image', data: '' }] } }),
      });

      const result = await client.readFile(DEMO_REPO, 'test.go');
      expect(result.content).toBe('');
    });
  });

  describe('Deep Search', () => {
    it('should call sg_deepsearch with query and repo', async () => {
      fetchSpy.mockResolvedValue(
        mockMCPResponse('The function RetryBackoff in libs/retry/backoff.go was modified.')
      );

      const result = await client.deepSearch('investigate retry failure', DEMO_REPO);

      const body = JSON.parse(fetchSpy.mock.calls[0][1].body);
      expect(body.params.name).toBe('sg_deepsearch');
      expect(body.params.arguments.query).toBe('investigate retry failure');
      expect(body.params.arguments.repo).toBe(DEMO_REPO);
      expect(result.summary).toContain('RetryBackoff');
    });

    it('should parse file paths from Deep Search results', async () => {
      fetchSpy.mockResolvedValue(
        mockMCPResponse(
          'The issue is in `libs/retry/backoff.go` where the function was changed. ' +
          'The test in apps/worker-reconcile/reconcile_test.go catches this.'
        )
      );

      const result = await client.deepSearch('test query', DEMO_REPO);
      const paths = result.files.map(f => f.path);
      expect(paths).toContain('libs/retry/backoff.go');
      expect(paths).toContain('apps/worker-reconcile/reconcile_test.go');
    });

    it('should parse symbol names from Deep Search results', async () => {
      fetchSpy.mockResolvedValue(
        mockMCPResponse(
          'func RetryBackoff(attempt int, cfg RetryConfig) computes the delay. ' +
          'type RetryConfig struct holds configuration.'
        )
      );

      const result = await client.deepSearch('test query', DEMO_REPO);
      const names = result.symbols.map(s => s.name);
      expect(names).toContain('RetryBackoff');
      expect(names).toContain('RetryConfig');
    });

    it('should deduplicate files and symbols', async () => {
      fetchSpy.mockResolvedValue(
        mockMCPResponse(
          'libs/retry/backoff.go has func RetryBackoff. Also libs/retry/backoff.go is used. func RetryBackoff again.'
        )
      );

      const result = await client.deepSearch('test', DEMO_REPO);
      expect(result.files.filter(f => f.path === 'libs/retry/backoff.go')).toHaveLength(1);
      expect(result.symbols.filter(s => s.name === 'RetryBackoff')).toHaveLength(1);
    });
  });

  describe('MCP tools', () => {
    it('should call sg_go_to_definition with location params', async () => {
      fetchSpy.mockResolvedValue(mockMCPResponse('func RetryBackoff at line 29'));

      await client.goToDefinition(DEMO_REPO, 'libs/retry/backoff.go', 29, 5);

      const body = JSON.parse(fetchSpy.mock.calls[0][1].body);
      expect(body.params.name).toBe('sg_go_to_definition');
      expect(body.params.arguments).toEqual({
        repo: DEMO_REPO,
        path: 'libs/retry/backoff.go',
        line: 29,
        character: 5,
      });
    });

    it('should call sg_find_references', async () => {
      fetchSpy.mockResolvedValue(mockMCPResponse('3 references found'));

      await client.findReferences(DEMO_REPO, 'libs/retry/backoff.go', 29, 5);

      const body = JSON.parse(fetchSpy.mock.calls[0][1].body);
      expect(body.params.name).toBe('sg_find_references');
    });

    it('should call sg_keyword_search', async () => {
      fetchSpy.mockResolvedValue(mockMCPResponse('RetryBackoff matches'));

      const result = await client.keywordSearch('RetryBackoff', DEMO_REPO);

      const body = JSON.parse(fetchSpy.mock.calls[0][1].body);
      expect(body.params.name).toBe('sg_keyword_search');
      expect(result.content).toContain('RetryBackoff');
    });

    it('should call sg_nls_search for semantic search', async () => {
      fetchSpy.mockResolvedValue(mockMCPResponse('semantic results'));

      await client.semanticSearch('backoff delay calculation', DEMO_REPO);

      const body = JSON.parse(fetchSpy.mock.calls[0][1].body);
      expect(body.params.name).toBe('sg_nls_search');
    });

    it('should call sg_list_files', async () => {
      fetchSpy.mockResolvedValue(mockMCPResponse('backoff.go\nbackoff_test.go'));

      await client.listFiles(DEMO_REPO, 'libs/retry');

      const body = JSON.parse(fetchSpy.mock.calls[0][1].body);
      expect(body.params.name).toBe('sg_list_files');
      expect(body.params.arguments.path).toBe('libs/retry');
    });

    it('should call sg_commit_search', async () => {
      fetchSpy.mockResolvedValue(mockMCPResponse('commit: simplify backoff'));

      await client.commitSearch('simplify backoff', DEMO_REPO);

      const body = JSON.parse(fetchSpy.mock.calls[0][1].body);
      expect(body.params.name).toBe('sg_commit_search');
    });
  });

  describe('investigate() composite helper', () => {
    it('should run deep search, file read, and keyword search', async () => {
      fetchSpy
        .mockResolvedValueOnce(mockMCPResponse('Deep search found libs/retry/backoff.go'))
        .mockResolvedValueOnce(mockMCPResponse('package retry\n\nfunc RetryBackoff...'))
        .mockResolvedValueOnce(mockMCPResponse('RetryBackoff found in 3 files'));

      const result = await client.investigate(
        'Why does retry fail?',
        DEMO_REPO,
        'libs/retry/backoff.go',
        'RetryBackoff'
      );

      expect(fetchSpy).toHaveBeenCalledTimes(3);
      expect(result.deepSearch.summary).toContain('backoff.go');
      expect(result.fileContent).toContain('RetryBackoff');
      expect(result.symbolHits).toContain('RetryBackoff');
    });

    it('should continue if file read fails', async () => {
      fetchSpy
        .mockResolvedValueOnce(mockMCPResponse('search results'))
        .mockResolvedValueOnce(mockMCPError('file not found'))
        .mockResolvedValueOnce(mockMCPResponse('symbol hits'));

      const result = await client.investigate(
        'query',
        DEMO_REPO,
        'nonexistent.go',
        'Symbol'
      );

      expect(result.deepSearch).toBeDefined();
      expect(result.fileContent).toBeUndefined();
      expect(result.symbolHits).toBeDefined();
    });

    it('should work without suspect file or symbol', async () => {
      fetchSpy.mockResolvedValueOnce(mockMCPResponse('search results only'));

      const result = await client.investigate('query', DEMO_REPO);

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      expect(result.deepSearch).toBeDefined();
      expect(result.fileContent).toBeUndefined();
      expect(result.symbolHits).toBeUndefined();
    });
  });
});

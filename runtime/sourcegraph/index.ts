/**
 * Sourcegraph client for Deep Search and MCP tool calls.
 *
 * Two integration surfaces:
 *   1. Deep Search (sg_deepsearch / sg_deepsearch_read) — semantic, broad investigation
 *   2. MCP tools (sg_go_to_definition, sg_find_references, sg_read_file, etc.) — precise, symbol-level
 */

export interface SourcegraphConfig {
  mcpEndpoint: string;
  accessToken: string;
}

export interface DeepSearchResult {
  summary: string;
  files: { path: string; relevance: string; snippet?: string }[];
  symbols: { name: string; kind: string; file: string; line?: number }[];
  raw: string;
}

export interface MCPToolCall {
  tool: string;
  params: Record<string, unknown>;
}

export interface MCPToolResult {
  content: string;
  metadata?: Record<string, unknown>;
}

export class SourcegraphClient {
  private config: SourcegraphConfig;

  constructor(config: SourcegraphConfig) {
    this.config = config;
  }

  // ---------------------------------------------------------------------------
  // Deep Search
  // ---------------------------------------------------------------------------

  /** Execute a Deep Search query scoped to a repository. */
  async deepSearch(query: string, repo: string): Promise<DeepSearchResult> {
    const result = await this.callMCPTool('sg_deepsearch', {
      query,
      repo,
    });
    return this.parseDeepSearchResult(result.content);
  }

  /** Read a previously-started Deep Search result by ID. */
  async deepSearchRead(searchId: string): Promise<DeepSearchResult> {
    const result = await this.callMCPTool('sg_deepsearch_read', {
      id: searchId,
    });
    return this.parseDeepSearchResult(result.content);
  }

  // ---------------------------------------------------------------------------
  // MCP Symbol Tools
  // ---------------------------------------------------------------------------

  /** Navigate to the definition of a symbol at a given location. */
  async goToDefinition(
    repo: string,
    path: string,
    line: number,
    character: number
  ): Promise<MCPToolResult> {
    return this.callMCPTool('sg_go_to_definition', {
      repo,
      path,
      line,
      character,
    });
  }

  /** Find all references to a symbol at a given location. */
  async findReferences(
    repo: string,
    path: string,
    line: number,
    character: number
  ): Promise<MCPToolResult> {
    return this.callMCPTool('sg_find_references', {
      repo,
      path,
      line,
      character,
    });
  }

  // ---------------------------------------------------------------------------
  // MCP File / Search Tools
  // ---------------------------------------------------------------------------

  /** Read a file's contents from a repository. */
  async readFile(repo: string, path: string): Promise<MCPToolResult> {
    return this.callMCPTool('sg_read_file', { repo, path });
  }

  /** List files in a repository directory. */
  async listFiles(repo: string, path?: string): Promise<MCPToolResult> {
    return this.callMCPTool('sg_list_files', { repo, path: path ?? '' });
  }

  /** Keyword (exact/regex) search across a repository. */
  async keywordSearch(query: string, repo: string): Promise<MCPToolResult> {
    return this.callMCPTool('sg_keyword_search', { query, repo });
  }

  /** Natural-language semantic search. */
  async semanticSearch(query: string, repo: string): Promise<MCPToolResult> {
    return this.callMCPTool('sg_nls_search', { query, repo });
  }

  /** Search commit messages. */
  async commitSearch(query: string, repo: string): Promise<MCPToolResult> {
    return this.callMCPTool('sg_commit_search', { query, repo });
  }

  // ---------------------------------------------------------------------------
  // Composite helpers (used by the blueprint executor)
  // ---------------------------------------------------------------------------

  /**
   * Run a full investigation flow:
   *   1. Deep Search for high-level context
   *   2. Read the identified root-cause file
   *   3. Keyword search for the suspect function
   *
   * Returns consolidated results.
   */
  async investigate(
    query: string,
    repo: string,
    suspectFile?: string,
    suspectSymbol?: string
  ): Promise<{
    deepSearch: DeepSearchResult;
    fileContent?: string;
    symbolHits?: string;
  }> {
    // Step 1 — broad semantic search
    const deepSearch = await this.deepSearch(query, repo);

    // Step 2 — read suspect file if provided
    let fileContent: string | undefined;
    if (suspectFile) {
      try {
        const file = await this.readFile(repo, suspectFile);
        fileContent = file.content;
      } catch {
        // File read may fail if path is wrong; continue
      }
    }

    // Step 3 — keyword search for suspect symbol
    let symbolHits: string | undefined;
    if (suspectSymbol) {
      try {
        const hits = await this.keywordSearch(suspectSymbol, repo);
        symbolHits = hits.content;
      } catch {
        // Continue without symbol hits
      }
    }

    return { deepSearch, fileContent, symbolHits };
  }

  // ---------------------------------------------------------------------------
  // Core MCP transport
  // ---------------------------------------------------------------------------

  /** Call a Sourcegraph MCP tool via JSON-RPC over HTTP. */
  async callMCPTool(
    tool: string,
    params: Record<string, unknown>
  ): Promise<MCPToolResult> {
    const requestId = typeof crypto !== 'undefined' && crypto.randomUUID
      ? crypto.randomUUID()
      : `req-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

    const body = JSON.stringify({
      jsonrpc: '2.0',
      method: 'tools/call',
      params: {
        name: tool,
        arguments: params,
      },
      id: requestId,
    });

    const resp = await fetch(this.config.mcpEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `token ${this.config.accessToken}`,
      },
      body,
    });

    if (!resp.ok) {
      const text = await resp.text().catch(() => '');
      throw new Error(
        `Sourcegraph MCP error: ${resp.status} ${resp.statusText} — ${text.slice(0, 200)}`
      );
    }

    const data = (await resp.json()) as {
      result?: { content: { type: string; text: string }[] };
      error?: { code?: number; message: string };
    };

    if (data.error) {
      throw new Error(`MCP tool error [${tool}]: ${data.error.message}`);
    }

    const textContent = data.result?.content?.find(
      (c: { type: string }) => c.type === 'text'
    );

    return {
      content: textContent?.text ?? '',
      metadata: { tool, requestId },
    };
  }

  // ---------------------------------------------------------------------------
  // Response parsing
  // ---------------------------------------------------------------------------

  private parseDeepSearchResult(content: string): DeepSearchResult {
    const files: DeepSearchResult['files'] = [];
    const symbols: DeepSearchResult['symbols'] = [];

    // Extract file paths (patterns like `path/to/file.go` or code-fenced paths)
    const filePatterns = content.matchAll(
      /(?:^|\s|`)([\w/.-]+\.(?:go|ts|js|py|java|rs|rb|c|cpp|h))\b/gm
    );
    const seenFiles = new Set<string>();
    for (const match of filePatterns) {
      const path = match[1];
      if (!seenFiles.has(path)) {
        seenFiles.add(path);
        files.push({ path, relevance: 'mentioned' });
      }
    }

    // Extract function/type names (Go-style: func Name, type Name)
    const symbolPatterns = content.matchAll(
      /(?:func|type|class|def|function)\s+(\w+)/g
    );
    const seenSymbols = new Set<string>();
    for (const match of symbolPatterns) {
      const name = match[1];
      if (!seenSymbols.has(name)) {
        seenSymbols.add(name);
        symbols.push({ name, kind: 'function', file: '' });
      }
    }

    return {
      summary: content.slice(0, 1000),
      files,
      symbols,
      raw: content,
    };
  }
}

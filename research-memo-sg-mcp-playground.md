# Research Memo: Sourcegraph MCP Playground/Microsite for Background Agents

**Date:** 2026-03-18
**Author:** background_agents polecat furiosa
**Issue:** ba-899
**Sources:** arxiv:2603.16021 (MWP), github.com/langchain-ai/open-swe

---

## Executive Summary

This memo synthesizes two recent technical artifacts — the Model Workspace Protocol
(MWP) paper and the Open-SWE asynchronous coding agent framework — to propose a
playground/microsite design for background agents that use the Sourcegraph MCP.

The core thesis: **MWP provides the structural template (filesystem-as-workflow),
open-swe provides the execution substrate (LangGraph + webhook triggers), and
Sourcegraph MCP fills open-swe's most conspicuous gap (semantic code navigation).**
Together they suggest a playground that is downloadable, self-contained, and
demonstrably better at codebase exploration than grep-based alternatives.

---

## 1. Source Material Summary

### 1.1 Model Workspace Protocol (arxiv:2603.16021)

**Authors:** Jake Van Clief, David McDermott (MIT license, March 2026)
**Repo:** github.com/RinDig/Model-Workspace-Protocol-MWP-

MWP proposes replacing programmatic multi-agent orchestration (LangChain graphs,
AutoGen conversations) with **directory structure as workflow definition**. The
numbered folder convention encodes execution order: `01_research/`, `02_script/`,
`03_production/`. Each stage has a `CONTEXT.md` specifying Inputs, Process, and
Outputs. All state lives in `.md` and `.json` files on disk.

**Five core design principles:**
1. One Stage, One Job
2. Plain Text Interface (`.md` + `.json` only)
3. Layered Context Loading (2k–8k tokens per stage vs. ~42k tokens monolithic)
4. Every Output Is an Edit Surface
5. Configure Factory, Not Product (static reference material vs. per-run artifacts)

**Five-layer context hierarchy:**

| Layer | File | Purpose | ~Tokens |
|-------|------|---------|---------|
| 0 | `CLAUDE.md` | Global workspace identity | ~800 |
| 1 | `CONTEXT.md` (root) | Task routing | ~300 |
| 2 | `CONTEXT.md` (stage) | Stage contract | 200–500 |
| 3 | `references/` | Voice, conventions, design system | 500–2k |
| 4 | `output/` | Per-run artifacts from prior stages | Varies |

**Key empirical finding (N=33):** U-shaped human intervention pattern — high editing
at stage 1 (direction-setting) and final stage (debugging), low in middle stages
where constraints narrow the solution space. Non-coders successfully edited
CONTEXT.md files and produced complete outputs.

**Explicit MWP/MCP distinction:** The paper clarifies these are complementary — MWP
for workflow structure, MCP for tool access. This is the direct design invitation for
a Sourcegraph-MCP-aware playground.

### 1.2 Open-SWE (github.com/langchain-ai/open-swe)

**Created:** May 2025, ~6,268 stars, MIT license, Python
**Purpose:** Template for building custom internal coding agents (Slack bots, CLIs,
web apps) inspired by proprietary agents at Stripe, Ramp, Coinbase.

**Architecture:** LangGraph as deployment/state-persistence harness; actual agent
logic in `deepagents` library. Single ReAct node with 6 tools. LangGraph provides
thread lifecycle, state persistence, and Store (for mid-task message injection).

**Three trigger surfaces:** Slack webhook, Linear webhook, GitHub issue/PR comment.

**Key toolset:**

| Tool | Purpose |
|------|---------|
| `commit_and_open_pr` | Git commit + push + draft PR |
| `fetch_url` | URL → markdown |
| `http_request` | Generic HTTP |
| `linear_comment` | Post to Linear |
| `slack_thread_reply` | Post to Slack thread |
| `github_comment` | Post to GitHub issue/PR |
| `execute` (deepagents) | Shell in sandbox |
| `task` (deepagents) | Spawn child agent |

**Critical gap:** No dedicated code search or navigation tools. Code exploration
is done entirely via `execute` + grep/find/git commands inside a cloned sandbox.

**Key customization hooks:**
- `AGENTS.md` in any target repo root (injected into system prompt at runtime)
- `tools=[]` in `get_agent()` (drop-in tool addition)
- `@before_model` / `@after_agent` middleware decorators
- `/agent/prompt.py` modular prompt sections

---

## 2. Playground/Microsite Design

### 2.1 Concept: "Workspace Downloads" vs. "Run in Browser"

The natural primary CTA for an MWP-informed playground is **"Download this workspace"**
rather than "Run in browser." Each demo scenario is a self-contained directory that
users clone/unzip and run locally with `claude`. This trades deployment complexity
for user ownership, reusability, and zero cloud infrastructure requirements.

**Implications for the microsite:**
- The microsite is primarily a catalog and documentation layer
- Each workspace is a git repo or downloadable zip
- The "playground" is local execution, not a hosted sandbox
- Users can inspect all state (it's just files), edit any stage contract, and re-run

This is a significant UX departure from typical LLM demos but aligns with developer
tooling conventions and the Gas Town/background-agents audience.

### 2.2 Structural Template: MWP-Informed Workspace Layout

An SG MCP background agent playground workspace would follow MWP conventions:

```
sg-mcp-playground/
├── CLAUDE.md                          # Layer 0: workspace identity
├── CONTEXT.md                         # Layer 1: task routing + available scenarios
├── _config/
│   ├── sg-mcp-tools.md                # Layer 3: SG MCP tool reference
│   ├── agent-conventions.md           # Layer 3: agent behavior guidelines
│   └── repo-map.md                    # Layer 3: repos to search + access notes
├── scenarios/
│   ├── 01_find-bug/                   # Scenario: trace a CI failure to root cause
│   │   ├── CONTEXT.md                 # Inputs: failing test name. Process: search, trace, report.
│   │   ├── references/
│   │   │   └── investigation-format.md
│   │   └── output/
│   │       └── investigation_output.md  # Populated by agent
│   ├── 02_cross-repo-refactor/        # Scenario: find all call sites across repos
│   │   └── ...
│   ├── 03_dependency-audit/           # Scenario: trace a library's usage pattern
│   │   └── ...
│   └── 04_onboarding-deep-dive/       # Scenario: explain an unfamiliar codebase
│       └── ...
└── setup/
    ├── prerequisites.md               # What you need: claude CLI, SG token
    └── quickstart.md                  # 3-step setup
```

**Stage contracts use the same three-section format:**

```markdown
## Inputs
- Layer 4: (none — this is the first stage)
- Layer 3: ../../_config/sg-mcp-tools.md
- Layer 3: references/investigation-format.md

## Process
You are a CI failure investigator. Using the Sourcegraph MCP tools,
search for the failing test, trace the code under test, find recent
changes that may have introduced the regression, and write an
investigation report to output/investigation_output.md.

## Outputs
- investigation_output.md -> output/
```

### 2.3 Open-SWE Integration: Async Webhook-Triggered Variant

For teams that want a hosted/async variant (not just local), open-swe provides
the integration template. An SG-MCP-augmented fork would:

**Add Sourcegraph MCP tools as native tools:**
```python
# In agent/server.py → get_agent()
from agent.tools.sg_mcp import (
    sg_keyword_search,
    sg_nls_search,
    sg_read_file,
    sg_go_to_definition,
    sg_find_references,
    sg_commit_search,
    sg_deepsearch,
)

tools = [
    *existing_tools,
    sg_keyword_search,
    sg_nls_search,
    sg_read_file,
    sg_go_to_definition,
    sg_find_references,
    sg_commit_search,
    sg_deepsearch,
]
```

No graph restructuring required — LangGraph's tool discovery reads function
signatures automatically.

**AGENTS.md as per-repo tool guidance:**
```markdown
# AGENTS.md (placed in any repo open-swe works with)

## Code Navigation
Prefer Sourcegraph MCP tools over grep/find for code exploration:
- sg_keyword_search: exact symbol/string search across all repos
- sg_nls_search: semantic "what does X do?" questions
- sg_go_to_definition: trace to symbol origin
- sg_find_references: find all call sites
- sg_commit_search: find when/why a change was introduced

Always include `repo:owner/reponame` in sg_keyword_search and sg_nls_search queries.
```

**Context enrichment middleware:**
```python
# @before_model middleware that pre-populates context
async def enrich_with_sg_context(state, config):
    """Before first LLM call, run SG searches based on task description."""
    if is_first_call(state):
        task = extract_task_description(state)
        initial_context = await sg_nls_search(
            query=f"{task} repo:{config['repo_owner']}/{config['repo_name']}"
        )
        return add_message(state, f"Initial codebase context:\n{initial_context}")
    return state
```

### 2.4 Microsite Information Architecture

The microsite itself (the web layer above the downloadable workspaces) should be
minimal and developer-focused:

**Pages:**
1. **Home** — Value proposition: "Sourcegraph MCP + background agents = codebase
   navigation at agent speed." Shows the key comparison: grep-based vs. SG-MCP-based
   navigation.
2. **Scenarios** — Catalog of downloadable workspace demos with:
   - Description of the task
   - Which SG MCP tools it demonstrates
   - Example output (screenshot or text excerpt)
   - Download/clone button
3. **How It Works** — MWP architecture explained with annotated directory tree
4. **Integrate** — For teams that want to add SG MCP to open-swe or similar frameworks

**Key pedagogical artifact:** The token budget comparison table — "5.6k tokens per
stage (MWP) vs. 42k tokens monolithic" — reframed for coding agents as "search
3 relevant files vs. dump the entire repo."

---

## 3. Concrete Sourcegraph MCP Integration Points

### 3.1 Tool-to-Task Mapping

| SG MCP Tool | Best for | Demo scenario |
|-------------|----------|---------------|
| `sg_keyword_search` | Exact symbol lookups, literal strings | Find all callers of a deprecated function |
| `sg_nls_search` | "How does X work?" questions | Explain authentication flow |
| `sg_read_file` | Read specific file at revision | Inspect file before/after a change |
| `sg_list_files` | Discover project structure | Orient in unfamiliar repo |
| `sg_go_to_definition` | Trace to origin | Find where an interface is defined |
| `sg_find_references` | Find all usage sites | Cross-repo impact analysis |
| `sg_commit_search` | "When was X added/changed?" | Root cause CI failure |
| `sg_deepsearch` | Complex multi-hop questions | "Why does this test flake?" |

### 3.2 The grep → SG MCP Migration

Open-SWE's agent currently executes shell commands like:
```bash
grep -r "functionName" ./
find . -name "*.go" -exec grep -l "pattern" {} \;
git log --oneline -20
git blame path/to/file
```

Each of these has a direct SG MCP equivalent that works **across repos without
cloning**, **understands semantics** (not just text), and **respects permissions**:

| Shell command | SG MCP equivalent | Advantage |
|---------------|-------------------|-----------|
| `grep -r "symbol"` | `sg_keyword_search(query="symbol repo:org/repo")` | Cross-repo, indexed, no local clone |
| "explain this code" | `sg_nls_search(query="how does X work repo:org/repo")` | Semantic, not just textual |
| Navigate to definition | `sg_go_to_definition(repo=..., path=..., symbol=...)` | Language-aware, not grep |
| Find all usages | `sg_find_references(...)` | Precise, not string matching |
| `git log --grep` | `sg_commit_search(repos=[...], messageTerms=[...])` | Multi-repo, structured output |
| Deep investigation | `sg_deepsearch(question=...)` | AI-powered, multi-hop |

### 3.3 Query Construction Patterns

For the playground `_config/sg-mcp-tools.md` (Layer 3 reference material):

```markdown
## sg_keyword_search
Always include repo: filter. Examples:
- `sg_keyword_search(query="func NewHandler repo:org/api-service")`
- `sg_keyword_search(query="TODO: remove this repo:org/frontend lang:TypeScript")`

## sg_nls_search
Use for semantic questions. Examples:
- `sg_nls_search(query="how is authentication middleware implemented repo:org/api")`
- `sg_nls_search(query="where are database migrations run repo:org/platform")`

## sg_commit_search
Use for "when was this introduced?" Examples:
- `sg_commit_search(repos=["org/api"], messageTerms=["auth", "middleware"])`
- `sg_commit_search(repos=["org/api"], contentTerms=["deprecated_function"])`
```

---

## 4. Design Alternatives Considered

### 4.1 Fully Hosted Playground (not recommended for v1)

A browser-based playground where users submit tasks and see agent output in real
time has high engagement potential but requires:
- LangGraph Cloud deployment (or self-hosted LangGraph server)
- Sandbox infrastructure (Daytona, Modal, etc.)
- Sourcegraph API token management
- Auth layer

**Verdict:** Too much infrastructure for a research/demo artifact. The downloadable
workspace approach delivers 80% of the value with 5% of the operational complexity.
A hosted variant is a Phase 2 consideration.

### 4.2 Pure MWP (no open-swe substrate)

A pure MWP implementation using only Claude + filesystem + SG MCP would be simpler
but loses:
- Webhook triggers (Slack/Linear/GitHub integration)
- Mid-task interruption handling
- Async execution via LangGraph
- The established tooling ecosystem (deepagents, sandbox providers)

**Verdict:** For local demo scenarios, pure MWP is sufficient. For production-grade
async agents, open-swe provides the missing runtime.

### 4.3 Sequential vs. Concurrent Stage Execution

MWP is explicitly sequential by design. Open-SWE's `task` tool (deepagents) supports
spawning child agents in parallel. For codebase exploration scenarios, concurrent
searches (e.g., search in tests + search in implementation simultaneously) would be
faster but add coordination complexity.

**Verdict:** Start sequential (MWP convention), add parallelism via `task` tool only
for scenarios where it's demonstrably valuable (e.g., multi-repo impact analysis).

---

## 5. Recommended Next Steps

### 5.1 Immediate (v1 playground)

1. **Build 2–3 MWP-format scenario workspaces** demonstrating distinct SG MCP
   tool combinations (keyword search, semantic search, commit search)
2. **Create `_config/sg-mcp-tools.md`** as a reusable Layer 3 reference artifact
3. **Write an `AGENTS.md`** for the background_agents repo itself that instructs
   agents to prefer SG MCP over grep
4. **Publish workspaces** as a git repo with README landing page

### 5.2 Phase 2

5. **Fork open-swe** with SG MCP tools pre-wired and AGENTS.md integration
6. **Add context enrichment middleware** for automatic pre-task SG searches
7. **Microsite landing page** with scenario catalog and value proposition
8. **LangGraph Cloud deployment** for hosted async variant

### 5.3 Research Questions to Validate

- How much does SG MCP context enrichment reduce total LLM calls vs. grep-based navigation?
- Which scenario type (bug investigation, cross-repo refactor, onboarding) demonstrates the most compelling SG MCP advantage?
- Does the MWP "download workspace" CTA actually convert with a developer audience?

---

## 6. Conclusion

The convergence of MWP and open-swe suggests a playground that is:

- **Structural:** Directory hierarchy encodes workflow (MWP)
- **Downloadable:** Self-contained, no server required (MWP)
- **Extensible:** Drop-in tool addition via LangGraph (open-swe)
- **Semantically capable:** Cross-repo code navigation without cloning (Sourcegraph MCP)

The most distinctive design choice — workspace as download rather than browser demo —
is also the one most aligned with the developer audience and the Gas Town/background-agents
operational model. Agents that work on local worktrees with file-based state are
already operating on MWP principles. The playground formalizes this and makes it
demonstrable.

The key insight from open-swe: their biggest architectural gap is code navigation
(grep-based), and Sourcegraph MCP is precisely the drop-in solution. A playground
that demonstrates this replacement is both a technical demo and a compelling product
argument.

---

*End of memo. Total sources: arxiv:2603.16021 (28 pages), github.com/langchain-ai/open-swe (full repo analysis).*

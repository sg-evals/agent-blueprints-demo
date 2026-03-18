# Research Memo: MWP + open-swe for Sourcegraph MCP Playground/Microsite

**Bead:** ba-787
**Date:** 2026-03-18
**Focus:** Design patterns and architecture for an interactive playground/microsite demonstrating background agents that use Sourcegraph MCP as a code intelligence backend.

---

## Sources Analyzed

1. **Model Workspace Protocol (MWP) paper** — arXiv:2603.16021 — "Interpretable Context Methodology: Folder Structure as Agentic Architecture" (Van Clief & McDermott, March 2026)
2. **open-swe** — https://github.com/langchain-ai/open-swe — "An Open-Source Asynchronous Coding Agent" (LangChain AI)

---

## Part 1: Model Workspace Protocol (MWP)

### What It Is

MWP orchestrates AI agent workflows using **filesystem hierarchy instead of programmatic multi-agent frameworks**. The core insight: for sequential, human-reviewed workflows, a single agent reading the right files at the right moment replaces the complexity of multi-agent orchestration.

The protocol uses numbered folders as pipeline stages (`01_research/`, `02_script/`, `03_draft/`), plain markdown files for prompts and stage-specific context, and local scripts for mechanical non-AI work. Each stage's output becomes the next stage's input. The authors ground this in Unix pipelines, modular decomposition, multi-pass compilation, and Make-style build systems.

Validated across three production systems (script-to-animation pipeline, course deck production, meta-workspace-builder) and 52 practitioners across content, research, and policy domains.

### Five-Layer Context Hierarchy

MWP formalizes five context layers per agent invocation:

| Layer | Contents |
|-------|----------|
| Layer 0 | Global identity / workspace location |
| Layer 1 | Workspace-level task routing |
| Layer 2 | Stage-specific contract (inputs, process, expected outputs) |
| Layer 3 | Stable reference material (style guides, conventions, constraints) |
| Layer 4 | Working artifacts unique to this run |

For a playground, each layer becomes an independently inspectable and editable UI panel — making the agent's full context transparent to the user.

### Key Patterns for a Playground Experience

**One Stage, One Job**
Each numbered folder encapsulates one unit of work with clean input/output contracts. Background agent demos become discrete, watchable steps instead of black-box operations. Users can trace exactly what happened at each stage.

**Every Output is an Edit Surface**
Intermediate artifacts are plain files. In a playground, this enables an "interrupt and edit" interaction: the agent pauses at stage gates, the user inspects or tweaks an artifact, then resumes. This is the core human-in-the-loop UX primitive.

**U-Shaped Intervention Pattern**
Empirically observed from practitioners: heavy editing at stage 1 (goal-setting), minimal at middle stages (constrained execution), heavy again at the final stage (alignment verification). Playground UI should mirror this — making stage 1 and final-review the primary interaction surfaces, minimizing friction at intermediate stages.

**Configure the Factory, Not the Product**
Workspaces are templates: set up once, run repeatedly. Pre-built workspace templates ("investigate a bug," "trace a call graph," "summarize recent changes to a module") are natural playground scenarios users fork and customize.

**Context Window Efficiency as a Visible Parameter**
Staged loading delivers 2,000–8,000 focused tokens per stage vs. 30,000–50,000 for monolithic approaches. In a playground, per-stage token budget is a visible, tuneable slider — users understand why agents run faster and see the efficiency principle in action.

**Observability as a Structural Property**
Because every intermediate output is a plain file, the working directory *is* the audit trail. A playground renders the numbered folder structure as a live file tree. No custom logging infrastructure needed — state is always visible.

### Sourcegraph MCP Integration with MWP

Sourcegraph MCP slots into MWP as a **dynamic Layer 3 reference provider** — replacing static style-guide files with live code intelligence:

- **Stage contracts (`CONTEXT.md`) include MCP calls** as the mechanism for pulling reference material. Instead of a static `code-style.md`, the Layer 3 reference for a "find related code" stage is a `sg_keyword_search` or `sg_nls_search` call that retrieves live codebase context.

- **`sg_read_file` and `sg_list_files` as Layer 4 artifact sources.** Rather than staging input files manually, a background agent's first stage invokes SG MCP to pull relevant files into the workspace dynamically at runtime.

- **`sg_go_to_definition` and `sg_find_references` as intermediate-stage enrichment.** Between a "identify the problem" stage and a "propose a fix" stage, an intermediate stage traces the dependency graph via MCP. Output (a markdown list of relevant files and call sites) becomes the context artifact fed to the fix-generation stage.

- **`sg_commit_search` as the research stage.** For a code investigation agent, the "research" stage is `sg_commit_search` + `sg_deepsearch` producing a structured summary that downstream stages consume.

- **`sg_deepsearch` for semantic scoping of Layer 3 reference material.** For large repos, rather than embedding an entire codebase in context, `sg_deepsearch` answers "what conventions govern this subsystem?" and returns a focused summary as the Layer 3 reference artifact.

The critical architectural constraint: MCP tool outputs produce **files** (artifacts) that live in numbered stage folders, maintaining the filesystem-as-orchestration pattern. MCP calls live in lightweight scripts, keeping the agent's context clean.

---

## Part 2: open-swe

### What It Is

open-swe is an open-source, asynchronous software engineering agent built on **LangGraph** and the `deepagents` library. It solves the gap between interactive AI coding assistants and production-grade internal engineering automation.

A developer @-mentions the bot in a GitHub issue, Linear ticket, or Slack message. The agent autonomously provisions an isolated Linux sandbox, clones the repo, reads `AGENTS.md` for repo-specific context, executes the coding task (read, edit, test, lint), commits changes, opens a draft PR, and posts a summary back to the originating channel. The developer doesn't sit in a chat loop — they file a ticket and come back to a PR.

### Architecture Decisions Relevant to a Playground

**Single Factory Function (`get_agent()`)**
The entire agent is assembled by one function accepting model, sandbox backend, tools list, system prompt, and middleware pipeline. A playground UI can expose these as form inputs — users configure the agent at the constructor level without touching code.

**LangGraph as the Runtime**
The agent runs as a LangGraph graph exposed via `langgraph.json`. LangGraph provides:
- Thread/run persistence (each task = a thread; supports replay)
- Streaming via SSE: token-by-token output, tool call events, chain events
- A REST API and SDK out of the box via `langgraph-sdk`
- `get_store()` for mid-task message injection (the message queue middleware)

A playground frontend connects to the LangGraph server via `langgraph-sdk` and streams live agent output without any custom backend work.

**Webhook-Agnostic Trigger Surface**
The `agent/webapp.py` FastAPI app funnels GitHub, Linear, and Slack webhooks into the same `client.runs.create()` call with a `configurable` dict. A playground sends HTTP POSTs directly with the `configurable` payload — no webhook setup required for the demo flow.

**`configurable` Context Dict Pattern**
Every run carries a `configurable` dict threading context through the agent without polluting message state: `repo_owner`, `repo_name`, `github_token`, `sandbox_id`, `thread_source`, `linear_issue_number`, etc. A playground UI is a form that populates this dict.

**Middleware as Composable Hooks**
Four middlewares decorate the agent loop:
- `@before_model`: `check_message_queue_before_model` — injects queued follow-up messages
- `@before_model`: `ensure_no_empty_msg` — guards against empty model inputs
- `@after_agent`: `open_pr_if_needed` — safety net that commits/pushes if agent didn't
- Class-based: `ToolErrorMiddleware` — wraps tool errors for graceful handling

This pattern supports playground-specific middleware: intercept tool calls to show them in the UI, inject synthetic user follow-up messages, mock sandbox execution for read-only demos.

**`AGENTS.md` Injection as Context Engineering**
At agent start, `read_agents_md_in_sandbox` reads `AGENTS.md` from the repo root and injects it into the system prompt. For a playground, this is the mechanism by which users configure agent behavior without code changes — just drop an `AGENTS.md` describing conventions, preferred tools (e.g., "use Sourcegraph MCP for all code search"), and constraints.

**Sandbox Provider Abstraction (`SandboxBackendProtocol`)**
All sandbox operations go through a protocol interface. The `local` backend executes directly on host. Supported backends: `local`, `modal`, `runloop`, `langsmith`. A playground can run the demo without cloud credentials using `SANDBOX_TYPE=local`.

### Sourcegraph MCP Integration with open-swe

open-swe's current code intelligence is shell-based: the agent runs `grep`, `find`, `git log`, `git blame` inside the sandbox. This requires cloning the repo first (30–180 seconds for large repos) and lacks semantic understanding.

**Option A: MCP Tools Added to the Agent's Tool List (Recommended)**
The `get_agent()` factory accepts a `tools` list. MCP tool definitions load via `langchain-mcp-adapters` (wraps MCP server tools as LangChain-compatible tools). SG MCP tools (`sg_keyword_search`, `sg_nls_search`, `sg_read_file`, `sg_go_to_definition`, `sg_find_references`, `sg_commit_search`, `sg_deepsearch`) join the tool list alongside existing custom tools.

In `AGENTS.md`, instructions like:
```
Use sg_nls_search and sg_keyword_search for code exploration before using shell grep.
Use sg_go_to_definition and sg_find_references for understanding call graphs.
Use sg_read_file to read files from the repo without cloning when possible.
```
This enables the agent to start answering code questions immediately, before the sandbox clone completes.

**Option B: Read/Write Architectural Split**
Sourcegraph MCP = read path (search, navigate, understand). Sandbox = write path (edit, run tests, commit, push). The system prompt encodes this split. The agent uses MCP tools for all reconnaissance, then switches to sandbox execution tools only when it needs to mutate files or run code. Read-only Q&A tasks can be answered entirely via MCP without touching the sandbox.

**Option C: Middleware-Injected MCP Context**
A `@before_model` middleware pre-populates agent state with MCP-fetched context based on the task description. Given a Linear issue title, run `sg_deepsearch` with the issue text, fetch the top-3 relevant files, inject them as initial context before the first model call. Context arrives pre-loaded rather than the agent discovering files by exploration.

### Key Files for Implementation Reference

| File | Purpose |
|------|---------|
| `/agent/server.py` | `get_agent()` factory, `_clone_or_pull_repo_in_sandbox()` |
| `/agent/webapp.py` | Webhook-to-LangGraph-run adapter (shows `configurable` dict shape) |
| `/agent/prompt.py` | Full modular system prompt, AGENTS.md injection point |
| `/agent/tools/` | Tool registration pattern (add MCP tools here) |
| `/agent/middleware/` | `@before_model` and `@after_agent` hook pattern |
| `/agent/utils/sandbox.py` | `SandboxBackendProtocol` factory dispatch |
| `/langgraph.json` | Deployment topology (graph name → entry point, FastAPI app mount) |
| `/CUSTOMIZATION.md` | All six customization surfaces |

---

## Synthesis: The Playground/Microsite

### Core Experience

"Give this agent a GitHub issue, watch it work."

The playground is a single-page app that combines MWP's staged transparency model with open-swe's async execution engine and Sourcegraph MCP as the code intelligence layer.

### UI Structure

**Left Panel — Task Configuration**
- Repo selector (browse Sourcegraph-indexed repos or paste GitHub URL)
- Task input (free-form text or GitHub issue URL)
- Model selector (Claude, GPT-4o, Gemini) → `provider:model` format
- Sandbox selector (local/modal/runloop) with credential fields
- "Advanced" toggle: custom `AGENTS.md` editor (textarea), middleware checkboxes, tool whitelist

**Center Panel — Live Agent Stream**
- System prompt construction visible as a collapsible block (AGENTS.md injection shown)
- Each tool call: name, arguments formatted, result collapsible
- **SG MCP calls rendered distinctly** with Sourcegraph branding:
  - `sg_go_to_definition` → code snippet with line numbers
  - `sg_nls_search` → ranked results with file paths and snippets
  - `sg_find_references` → call site map
  - These are visual proof the agent is doing real code understanding, not just `grep`
- Middleware events (message queue checks, safety net triggers)
- Model reasoning stream (if enabled)

**Right Panel — Artifacts**
- File tree showing changed files highlighted
- Diff viewer per modified file
- PR preview (title, body, linked issue)
- Source channel preview (what the agent posts back to Linear/Slack/GitHub)

**MWP Stage View (Toggle)**
When the task uses a staged MWP-style workflow, switch to a stage stepper view:
- Numbered stages with progress indicator
- At each gate: read the artifact, edit it, re-run stage, or approve and advance
- Context inspector: all four MWP layers the agent will receive for the next stage
- Token budget visualizer per stage

**Footer — Replay Controls**
LangGraph thread persistence enables scrubbing back to any step, seeing exact state, and re-running from that checkpoint with different parameters (e.g., different model, different MCP query).

### User Flows

1. **"Investigate a failing test"** — paste a test name and repo → watch the agent `sg_keyword_search` the test, `sg_find_references` the function under test, `sg_commit_search` recent changes, produce a root cause analysis
2. **"Trace a bug from symptom to root cause"** — paste an error message → MCP semantic search finds relevant code paths, agent traces to the offending commit
3. **"Understand an unfamiliar module"** — paste a directory path → `sg_list_files`, `sg_nls_search`, `sg_deepsearch` produce a structured explanation of the module's purpose, dependencies, and conventions
4. **"Summarize recent changes to a subsystem"** — paste a file pattern → `sg_commit_search` + diff reading produce a changelog-style summary
5. **"Find all call sites before refactoring"** — paste a function name → `sg_find_references` produces a complete call site map the agent narrates

### Technical Building Blocks

| Component | Technology | Notes |
|-----------|-----------|-------|
| Agent runtime | open-swe + LangGraph | `langgraph.json` deployment, `get_agent()` factory |
| Code intelligence | Sourcegraph MCP server | `langchain-mcp-adapters` wraps tools for LangChain/LangGraph |
| Streaming frontend | `langgraph-sdk` JS client | SSE events: `on_tool_start`, `on_tool_end`, `on_chat_model_stream` |
| Sandbox backend | `local` (demo) or Modal/Runloop (prod) | `SandboxBackendProtocol` abstraction |
| Task trigger | Direct `client.runs.create()` POST | No webhooks required for playground |
| Agent configuration | `AGENTS.md` textarea → injected at agent start | User controls behavior without code changes |
| MWP stage UI | Custom stepper component | Renders numbered folders, gate controls, context inspector |
| Auth | GitHub token (demo bot) + Sourcegraph token | `agent/encryption.py` pattern for secure storage |
| Session isolation | LangGraph thread per session | Persistent for replay; exportable as workspace zip |

### What Makes This Differentiating

The combination of:
1. **MWP transparency** — every intermediate artifact visible and editable, no black box
2. **open-swe async execution** — real code changes, real PRs, real sandbox
3. **Sourcegraph MCP as the intelligence layer** — visible, semantic code search replacing `grep`

produces a demo that lets a user watch a background agent work through a real codebase problem, understand exactly what context it had at each step, intervene where they want, and see how Sourcegraph MCP queries shaped the agent's reasoning. That combination of transparency + real code intelligence + human-in-the-loop gates is the differentiating playground experience.

---

## Recommended Next Steps

1. **Spike the SG MCP + open-swe integration** — fork open-swe, add `langchain-mcp-adapters`, inject SG MCP tools into `get_agent()`, add MCP-aware `AGENTS.md` to a demo repo. Verify the agent prefers MCP over shell grep for exploration.

2. **Build the MWP stage view on top of LangGraph threads** — map LangGraph run events to a staged stepper UI. The natural mapping: each top-level `on_chain_start` event in the LangGraph graph = a stage gate. Intermediate tool calls within a stage collapse under that gate.

3. **Design the scenario library** — 5 pre-built workspace templates (the user flows above) with curated `AGENTS.md` files tuned for each scenario. This is the "configure the factory" product surface from MWP.

4. **Implement the SG MCP call renderer** — the highest-impact visual component. `sg_go_to_definition` and `sg_nls_search` results rendered inline in the agent stream (with Sourcegraph-branded UI) are the visual proof point that makes the playground compelling.

5. **Prototype with `SANDBOX_TYPE=local` first** — eliminates all cloud credential complexity for the initial demo build. Switch to Modal/Runloop for a public-facing deployment.

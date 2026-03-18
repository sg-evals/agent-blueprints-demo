# Research Memo: arxiv 2603.16021 + langchain open-swe → CSB Integration

**Bead:** ba-5r6
**Date:** 2026-03-18
**Author:** Polecat furiosa

---

## Executive Summary

Two resources were analyzed for potential incorporation into CodeScaleBench (CSB):

1. **MWP (Model Workspace Protocol)** — arxiv 2603.16021, "Interpretable Context Methodology: Folder Structure as Agent Architecture" by Van Clief & McDermott (March 2026). A filesystem-first approach to AI agent orchestration with staged context loading and human review gates.

2. **open-swe** — `github.com/langchain-ai/open-swe`, an open-source production SWE agent framework built on LangGraph + Deep Agents, designed to be forked and deployed as an internal coding agent (Slack/Linear/GitHub triggered).

**Verdict:** open-swe is a strong candidate for a new **agent harness** in CSB's evaluation matrix — it represents a materially different architecture from the current Claude Code + Harbor setup and would yield new signal about agentic SWE systems in practice. MWP is less immediately applicable but offers concrete techniques for **task context design** and suggests a principled model for how CSB delivers context to agents in multi-step tasks.

---

## Resource 1: arxiv 2603.16021 — Model Workspace Protocol (MWP)

### What it is and what problem it solves

MWP replaces framework-level AI agent orchestration (LangChain, AutoGen, CrewAI) with filesystem structure. The insight: for sequential workflows where a human reviews output at each step, you do not need a coordination framework. Numbered folders represent stages. Plain markdown files carry prompts and context. One agent reads the right files at the right moment.

**Core problems solved:**
- Framework overhead for sequential workflows: editing a step requires code changes, not just file edits
- Context pollution: multi-agent frameworks load irrelevant context into the agent's window, degrading output quality ("Lost in the Middle")
- Opacity: intermediate state is hidden inside framework abstractions; MWP surfaces it as plain readable files

### Key technical contributions

**Five-layer context hierarchy:**

| Layer | Content | Tokens |
|-------|---------|--------|
| 0 | Workspace identity + structure routing | ~800 |
| 1 | Task routing + shared resources | ~300 |
| 2 | Stage contract (inputs, process, outputs) | 200–500 |
| 3 | Reference material (voice guides, style, conventions) | 500–2k |
| 4 | Working artifacts (per-run input/output) | varies |

Each stage only receives layers relevant to it — preventing the monolithic context problem. A monolithic prompt easily exceeds 40k tokens with stale irrelevant context; MWP stages typically receive 2k–8k focused tokens.

**Stage contracts:** Each stage has an explicit contract: what it reads (Inputs table distinguishing Layer 3 vs 4 files), what it does (process), what it writes (outputs). This enforces separation of concerns and makes the pipeline self-documenting — the CONTEXT.md is both the instruction and the documentation.

**Review gates:** At each stage boundary, a human can inspect and edit the output file before the next stage runs. The agent picks up whatever the human left there.

**Layer 3 vs Layer 4 distinction:** Reference material (stable rules, conventions, voice guides) is structurally separate from working artifacts (per-run input/output). This gives the model clearer signals about what constrains behavior vs what to transform.

**Multi-pass compilation analogy:** Each stage transforms an intermediate representation, like a compiler pass. Incremental recompilation is natural — if stage 1 output is fine but stage 2 needs rework, re-run stage 2 only.

### Relevance to CodeScaleBench

**Direct applicability: task context delivery**

CSB tasks currently deliver a single instruction document to the agent. MWP suggests that for multi-step tasks (especially in the `csb_sdlc_design`, `csb_sdlc_debug`, and `csb_org_incident` suites), structuring context delivery as a layered hierarchy could materially improve task solve rates and reduce irrelevant context noise.

Concrete possibility: adopt MWP's Layer 3 / Layer 4 distinction in CSB task design:
- Layer 3 (reference): repository conventions, architecture docs, domain glossary — stable across runs
- Layer 4 (working): the specific issue, failing test output, PR diff — per-run input
- This mirrors how effective human engineers approach tasks and would test whether agents benefit from pre-organized context

**Task design: staged multi-step tasks**

MWP's staged review-gate architecture suggests a new task type for CSB: **multi-stage tasks** where the agent must produce an intermediate artifact, receive simulated human feedback, and then complete the task. This would evaluate agent behavior under realistic human-in-the-loop conditions — currently absent from CSB's task inventory.

**Agent harness: MWP as a baseline config**

MWP workspaces are Claude Code–native (all implementations tested with Opus 4.6). An MWP-structured agent harness could be run against CSB tasks as a distinct configuration — analogous to `SG_base` vs `SG_full`. This would test whether structured context delivery measurably improves agent performance on CSB's coding tasks vs the current flat-context baseline.

**Observability pattern**

MWP's filesystem-intermediate-state approach is worth stealing for CSB run artifacts: if each agent step's intermediate outputs were written to disk as plain files, investigation of agent failures becomes dramatically easier. Currently, failure analysis requires reading full trace logs. An MWP-style artifact structure would let evaluators open a folder and see exactly what the agent was working with at each step.

### Tradeoffs and risks

- **Not applicable to concurrent/multi-agent tasks:** MWP is explicitly sequential and local-first. CSB's evaluation of multi-agent coordination scenarios would need a different approach.
- **Human review gates don't translate directly:** CSB is a fully automated benchmark — there's no human between stages. The MWP benefit of human editability doesn't apply, though the context-scoping benefit does.
- **Weak empirical basis:** The paper's evidence is practitioner self-reports from an invite-only community of 52 members, not controlled experiments. No A/B comparison with equivalent monolithic approaches. The "lost in the middle" argument is borrowed, not measured in MWP's specific setup.
- **Tested on one model family:** All reported results used Claude Opus 4.6 and Sonnet 4.6. Cross-model generalization is unknown.

---

## Resource 2: langchain-ai/open-swe

### What it is and what problem it solves

open-swe is an open-source framework for building an organization's internal coding agent — a SWE agent that runs autonomously on software engineering tasks triggered from Slack, Linear, or GitHub. It is designed to be forked and customized, not used as-is.

**Problem addressed:** Elite engineering orgs (Stripe, Ramp, Coinbase) have built proprietary internal coding agents with appropriate security, org integration, and autonomous operation. open-swe provides the same architecture as a customizable open-source starting point. It is a *production deployment framework*, not a benchmark tool.

### Key technical design decisions

**Core stack:** LangGraph (state machine orchestration) + `deepagents` (base agent loop, file tools, subagent spawning, `SandboxBackendProtocol` abstraction) + FastAPI (webhook server).

**Isolated cloud sandbox per thread:** Every task runs in its own Linux sandbox. Supported providers: LangSmith (default), Modal, Daytona, Runloop, local. The `SandboxBackendProtocol` abstraction requires only `execute()`, `id`, and file operations — easy to implement for custom providers.

**Deterministic thread IDs:** Follow-up messages on the same Linear issue / Slack thread / GitHub PR route to the same LangGraph thread → same sandbox. This enables mid-task messaging: the `check_message_queue_before_model` middleware polls for new messages before each model call and injects them.

**Small curated toolset (~15 tools):** Following Stripe's insight that tool curation matters more than quantity. Custom tools: `execute` (shell), `fetch_url`, `http_request`, `commit_and_open_pr`, `linear_comment`, `slack_thread_reply`, `github_comment`. Deep Agents built-ins: `read_file`, `write_file`, `edit_file`, `ls`, `glob`, `grep`, `write_todos`, `task` (subagent).

**AGENTS.md for per-repo context injection:** Any repo can place an `AGENTS.md` at its root encoding repo-specific conventions, testing requirements, architectural constraints. The agent reads it at startup and appends it to the system prompt. This is a form of MWP's Layer 3 (reference material).

**Middleware as safety nets:** `open_pr_if_needed` middleware runs after the agent loop and commits/opens a PR if the agent failed to do so itself. Critical steps happen deterministically regardless of LLM variance.

**Prompt-driven validation:** The system prompt instructs the agent to run linters, formatters, and only tests related to changed files before committing. Full CI runs post-PR. Orgs can add deterministic middleware hooks for stronger guarantees.

**Prompt injection defense:** GitHub comments from users outside the org are wrapped in `<untrusted_github_comment>` tags. The system prompt instructs the agent not to follow their instructions.

### Relevance to CodeScaleBench

**Primary opportunity: new agent harness for CSB**

open-swe represents a materially different agent architecture from the current Claude Code + Harbor setup:

| Dimension | Current CSB | open-swe |
|-----------|-------------|----------|
| Orchestration | Claude Code (flat tool use) | LangGraph state machine |
| Sandbox | Daytona / Docker | Modal, Daytona, Runloop, LangSmith |
| Tool set | MCP tools + bash | ~15 curated tools + subagent |
| Context delivery | Single instruction | AGENTS.md + issue/thread context |
| Invocation | Harbor runner | Webhook (Slack/Linear/GitHub) |
| Validation | Harbor CI | Prompt-driven + middleware safety nets |

Benchmarking open-swe-based agents on CSB tasks would yield new signal: does the LangGraph state machine + curated toolset lead to different performance profiles vs the current flat Claude Code harness? This is a research question CSB is well-positioned to answer.

**Sandbox integration:** open-swe already supports Daytona as a sandbox provider (`agent/integrations/daytona.py`). CSB already uses Daytona. Bridging the two is an integration task, not a new capability problem.

**AGENTS.md as CSB task artifact:** open-swe's AGENTS.md pattern is a direct analog to CSB task context delivery. Adding an AGENTS.md to CSB's benchmark repos (encoding repo conventions, test commands, architecture notes) would both (a) make CSB tasks more realistic and (b) let CSB evaluate whether agents that leverage AGENTS.md outperform those that don't.

**Task type: async multi-turn workflows**

open-swe's deterministic thread ID + mid-task messaging architecture enables evaluation of a task type CSB doesn't currently cover: **async multi-turn tasks** where the agent is interrupted mid-work with new information (a failing CI run, a reviewer comment, a changed requirement). CSB's current task inventory is single-shot; open-swe's architecture is designed precisely for the multi-turn case.

**No built-in eval harness — CSB fills the gap**

open-swe has no built-in benchmark or evaluation framework. The project is positioned as infrastructure, not a benchmark competitor. This is actually an opportunity: CSB could become the canonical benchmark for evaluating open-swe-style agents, filling the evaluation gap the project explicitly leaves open.

### Tradeoffs and risks

**Integration complexity:** open-swe requires standing up a FastAPI server, webhook endpoints, and sandbox infrastructure. Integrating it with CSB's Harbor runner would require wrapping the webhook-based invocation surface or adapting open-swe to support programmatic invocation (bypassing the webhook layer). This is non-trivial.

**No SWE-bench baseline:** open-swe makes no benchmark claims. There's no established performance baseline to compare against, making it harder to contextualize CSB results.

**Designed for async/human-triggered workflows:** open-swe's architecture optimizes for async, human-triggered operation (Slack, Linear). Adapting it to CSB's synchronous, automated evaluation loop requires some architectural surgery.

**Cold-start overhead:** open-swe's sandboxes have cold-start overhead vs the pre-warmed sandboxes that proprietary agents (Stripe Minions) use. This is a fair limitation to benchmark and report on, but it means run times may be longer than the current Claude Code harness.

**LangGraph dependency:** Adds a non-trivial dependency (LangGraph, LangSmith observability) to CSB's evaluation pipeline. If LangChain's ecosystem evolves rapidly (which it has historically), maintaining compatibility adds overhead.

---

## Cross-Cutting Observations

### Both resources converge on context scoping

MWP (Layer 3 / Layer 4 separation) and open-swe (AGENTS.md + issue/thread context) both recognize that context delivery architecture matters as much as the content of the context. Neither loads everything into a flat prompt; both separate stable reference material from per-run working artifacts. This is emerging as a consensus principle in production agentic systems and CSB is well-positioned to evaluate it empirically.

### The evaluation gap

Neither resource has a serious evaluation story. MWP's evidence is practitioner self-reports; open-swe has no benchmark integration. CSB could contribute to both by:
1. Testing whether MWP-style context structuring improves agent task performance
2. Establishing benchmark baselines for open-swe-architecture agents

### Sandboxes as a first-class benchmark dimension

open-swe's pluggable sandbox abstraction (`SandboxBackendProtocol`) suggests that sandbox choice (Daytona vs Modal vs Docker vs pre-warmed) is itself a benchmark variable. CSB currently treats the sandbox as infrastructure. It may be worth isolating sandbox-induced variance as a measurable factor in future CSB runs.

---

## Recommendations

### Short-term (low effort, high signal)

1. **Add AGENTS.md to CSB benchmark repos** (1–2 days): Encode repo conventions, test commands, and architectural notes. Evaluate whether agents that read AGENTS.md outperform those that don't. This is a task-design improvement independent of any new harness.

2. **Adopt Layer 3 / Layer 4 context structure in new task authoring** (ongoing): When writing new CSB tasks, explicitly separate stable reference material (repo conventions, domain glossary, architecture docs) from per-run working artifacts (the specific bug, failing test, issue). Document this as a task authoring standard.

3. **Prototype MWP-structured agent harness on a CSB SDLC suite** (1 week): Run a small set of `csb_sdlc_debug` tasks using an MWP workspace structure (staged context loading, layer hierarchy). Compare to baseline flat-context runs. This tests the core MWP claim empirically on CSB tasks.

### Medium-term (higher effort, new evaluation surface)

4. **Evaluate open-swe-based agent on CSB** (2–4 weeks): Fork open-swe, add a programmatic invocation path (bypass webhooks), connect to Daytona sandbox (already supported), run against selected CSB suites. This establishes the first benchmark baseline for LangGraph-based SWE agents and generates new comparative signal.

5. **Design multi-turn task type for CSB** (2–3 weeks): Using open-swe's architecture as inspiration, design a task category where the agent is interrupted mid-work with new information (simulated CI failure, simulated reviewer comment). This covers a workflow pattern CSB currently cannot evaluate.

### Not recommended

6. **Full MWP adoption as primary CSB agent harness:** MWP's human review gates don't translate to automated benchmarking. Its sequential, local-first design is a mismatch for CSB's concurrent evaluation runs. Use MWP's context-scoping techniques, not its overall architecture.

7. **Using open-swe as-is without adaptation:** The webhook-first invocation model, LangSmith dependency, and async-first design require non-trivial adaptation to fit CSB's synchronous evaluation loop. A fork with targeted changes is the right approach, not direct integration.

---

## Appendix: Source Artifacts

- **Paper PDF:** downloaded to `/tmp/paper-2603.16021.pdf` (600 KB, 20 pages)
- **Paper repo:** https://github.com/RinDig/Model-Workspace-Protocol-MWP- (MIT license)
- **open-swe repo:** https://github.com/langchain-ai/open-swe (~6,200 stars, MIT license)
- **CSB README consulted:** `/home/stephanie_jarmak/gt/deacon/dogs/alpha/codescalebench/README.md`

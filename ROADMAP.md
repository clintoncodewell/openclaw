# OpenClaw Command Center — Roadmap

Turn the OpenClaw iOS app from a chat client into **mission control for a fleet of AI agents**:
at-a-glance health, a readable briefs/reports inbox, deep run/tool-call traces, cost guardrails,
push-driven approvals, and a proactive agent that tells you *what needs you*.

Grounding: the app already has tabs **Command Center · Agent Pro (overview/usage/cron/skills/nodes)
· Talk · Chat · Settings** (+ iPad Activity/Workboard). The gateway runs ~5+ cron jobs/day
(morning-brief, code review, test-coverage, blog drafts, memory-consolidation…) delivered to
Telegram. The protocol already exposes `cron.list` / `cron.run` / `cron.runs` (with each run's full
`summary`), exec approvals, APNs, usage, nodes, and model routing — so most of this is buildable
client-side with no gateway changes.

Execution rule (per Clinton's tranche process): each item is built **E2E, no MVP** →
build/install → `/claudex` → fix → commit. Reviewed with the landscape of the best agent control
planes (LLM observability à la Langfuse/Helicone/Phoenix; workflow dashboards à la n8n/Flowise;
at-a-glance control planes à la Home Assistant/Grafana; agent "inbox" + HITL approvals).

---

## What the research says (deep-research: 103 agents, ranked)

The single biggest thing the best agent command centers do that **most don't**: a **bidirectional,
push-driven Agent Inbox** — agents escalate decisions/questions/briefs *to* you; you assign work *back*.
Ranked priorities, mapped to our waves:

1. **Agent Inbox (flagship)** — standardize on LangChain's vocabulary: actions **Accept / Edit /
   Respond / Ignore**; interrupt types **Notify / Question / Review**. UX = email-inbox × ticketing
   (AgentRQ: "agents assign tasks to you, you assign back"). We already have the `operator.approvals`
   scope (from the loopback-bind fix). → **the next big build after Briefs.**
2. **Proactive, action-suggesting briefs** — not just readable text; prioritized against your goals with
   1–3 tappable **next-action** buttons (Gemini Daily Brief; Home Assistant proactive confirmations).
   → **Wave 1 (building) — make the Briefs Inbox actionable, not passive.**
3. **Cost guardrails** — per-model AND per-tool/operation attribution + budget caps/alerts. → Wave 2.
4. **Tool-call trace viewer** — the pattern the field converged on: hierarchical traces, a
   **tree/timeline toggle**, per-step tokens/latency, expandable spans w/ JSON + reasoning
   (Langfuse / Grafana AI Observability / Phoenix). → Wave 2.
5. **RED-style at-a-glance overview** — requests, RPS, error rate, latency, TTFT (Grafana ops pattern
   for agents). → Wave 2.
6. **Model routing + fallbacks + a security/audit surface** (Portkey/LiteLLM gateway pattern; provider
   auth health). → Wave 3.

**Closest OSS analog to copy:** *Mission Control* (builderz-labs) — self-hosted, SQLite, 32 panels
(agents/tasks/skills/logs/tokens/memory/security/cron/alerts/pipelines), an "Aegis" quality-gate HITL,
6-column Kanban, Recharts token dashboards, WebSocket+SSE real-time feed. **Observability bar:** Grafana
Cloud AI Observability + Langfuse. **Honest caveat:** AgentRQ's "sub-second push, no polling" claim was
*refuted* in verification — do push via APNs without overpromising latency.

---

## Wave 1 — High Impact / High Priority (building now)

1. **Briefs / Reports Inbox** ⭐ *(your #1 ask)* — a dedicated surface that aggregates every cron/agent
   run output (morning-brief + review jobs + blog jobs), **grouped into date folders** (you get ~5/day),
   drill into a run with **back navigation**, render the `summary` with a **clean, readable report
   stylesheet** (typography, status chips ok/error, model/cost/duration footer), search + filter by job,
   unread badge. Data: `cron.runs` → `CronRunLogEntry.summary`. *This is the "no back button / hard to
   read / 5 a day" fix.*
2. **Job-health surfacing** — failures shown loud (morning-brief silently erroring for a day is the
   anti-pattern): per-job last-run status, next-run, consecutive-error count, one-tap re-run + view error.
3. **Run trace timeline** — extend the new tool-call bubble into a full per-run timeline (model calls →
   tool calls → results → errors → retries → latency), drillable from a brief.

## Wave 2 — High Impact

4. **Cost & usage analytics** — tokens/$ per agent · model · day, trend sparklines, model-fallback
   events (you hit OpenAI auth/quota repeatedly), **budget guardrails + alerts**. Data: usage RPC.
5. **Observability / run explorer** — Langfuse-style but mobile: searchable session list → timeline →
   span detail. Jump from any brief to the run that produced it.
6. **Push-driven approvals (HITL)** — exec-approval requests as **push notifications** → approve/deny
   from lock screen or a dedicated approvals inbox. (Gateway already has exec-approval + APNs hooks.)
7. **Alerting** — push when a cron errors, cost spikes, a node goes offline, or a provider's auth dies
   (the OpenAI single-session OAuth gotcha). Configurable per category.

## Wave 3 — Depth

8. **Agent/node fleet dashboard** — every agent + node (Mac, iPhone, gateway): status, caps, last-seen,
   one-tap node actions (camera/screen/location).
9. **Model routing control** — view/set primary + fallbacks per agent; **provider auth health** card
   with re-auth nudge (would have caught today's outage early).
10. **Memory & knowledge views** — browse/search `MEMORY.md` + gbrain; recent consolidations.
11. **Cron / skill authoring** — create/edit jobs + skills from the app (natural-language → schedule).

## Wave 4 — Novel / "Exponential" (the next level)

12. **"Chief of Staff" meta-agent** — watches all agents/crons and surfaces a single prioritized
    **"What needs you"** feed (failed jobs, cost spikes, stalled pipelines, decisions awaiting you) —
    turning 5 briefs/day from *text to triage*. Pushes one actionable digest, not five.
13. **Ambient surfaces** — Lock-screen **Live Activity** during long agent runs; **home-screen widgets**
    (briefs unread · jobs erroring · spend today · node status). The command center at a glance.
14. **Voice-first command** *(you have Talk + ElevenLabs/George)* — "what happened overnight?",
    "re-run the failed jobs", "approve that" → voice control of the whole command center.
15. **Cross-agent "what changed today"** — one unified feed across projects (AdviseWell, Unwired Wealth,
    code review, blog) — everything your AI did, in one place.
16. **Guardrails & autopilot** — spend caps; **auto-retry on auth/quota errors** + provider auto-failover
    (you'd never have lost a morning brief); policy-driven approvals.
17. **Shareable reports** — export a brief to a clean shareable HTML/PDF (your "stylesheet" instinct,
    productized): a polished, linkable report.

---

### Status
- ✅ Foundation shipped this session: free-team iOS build on device · public Funnel · gateway
  loopback-bind scope fix (chat answers) · OpenAI re-auth · collapsible tool-call bubble.
- ✅ morning-brief cron fixed + verified (was the OpenAI auth outage).
- ▶ **Now:** Wave 1 #1 — Briefs/Reports Inbox.

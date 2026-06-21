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
- ✅ **Wave 1 #1 — Briefs / Reports Inbox** (date folders, back nav, readable stylesheet, search/filter).
- ✅ **P1 — Agent Inbox** (push-driven exec-approval HITL; Approve/Always/Ignore reusing the canonical
  resolve path; live refresh; optimistic resolve + rollback; Command Center badge). `c82d6eb·aff7d39`
- ✅ **P3 — Cost & Usage + budget guardrails** (usage.cost + sessions.usage; Swift Charts trend;
  per-model/agent breakdown; client-side daily/monthly caps + over-budget alerts). `424e241·daf4f35`
- ✅ **P4 — Tool-call trace / run explorer** (sessions.usage run list → chat.history ordered, turn-grouped
  span timeline; expandable JSON args/results reusing the tool-display rendering). `7f3cc43·f89d7c7`
- ✅ **P5 — RED ops/health overview** (rate/error-rate/turn-latency from sessions.usage aggregates;
  "what needs attention" rollup: cron failures + provider auth + offline nodes; Command Center strip). `981d551·6ca36a0`
- ✅ **P6 — Model routing + provider auth-health + security posture** (read-only routing: primary +
  fallback chain + catalog availability; models.authStatus per-profile OAuth/expiry re-auth signal;
  device scopes / paired-devices / approval-policy posture). `0885236·844034f`
- ✅ **Wave 3 #8 — Agent/node fleet dashboard** (node.list status/caps/last-seen; one-tap node actions
  where the command policy permits; honest about invasive-capture gating). `1e68e56·7345178`
- ✅ **Wave 4 #12 — "Chief of Staff" what-needs-you digest** ⭐ *(flagship novel)* — one ranked triage
  hero synthesizing all six signals (approvals · failed crons · over-budget · dead auth · offline nodes ·
  error spikes) with one-tap deep-links; reuses every existing decoder, no parallel fetches. `5e32869`
- ✅ **Wave 4 #17 — Shareable report PDF export** (any brief → a polished single-page PDF via the in-app
  "nice stylesheet" rendered with ImageRenderer; system share sheet). `cd1f053·5992ce2`

**Deferred, with reason (not buildable safely/at all right now):**
- **#13 Ambient widgets / Live Activity** — need an app extension; the free-team single-target fork can't
  build extensions. The Chief-of-Staff digest is the in-app ambient surface instead.
- **#10 Memory / knowledge views** — the gateway exposes no operator-facing memory/wiki/knowledge RPC
  (memory is agent-tool-side); nothing to render without inventing protocol.
- **#11 Cron / skill authoring** & **#16 Guardrails / autopilot** — admin-gated *writes* / gateway-side
  automation against the live gateway; not appropriate to ship blind without you validating on your fleet.
- **#14 Voice-first command** — large surface that needs real-device voice-UX iteration (device currently
  disconnected); better built with you in the loop.
- **#15 Cross-agent "what changed"** — substantially delivered by the Briefs inbox + the Chief-of-Staff
  digest (cross-surface, cross-job rollups).

Review process this session: each feature built E2E by a Map→Implement→2-lens-adversarial-QA→Fix workflow
(grounded against real `src/gateway` source), then a focused independent review (Codex CLI, or a
supplementary Claude adversarial reviewer once Codex hit its usage limit, resets 2026-06-25), fixes
committed, build verified. All waves are on `fork/main`, build-green; device reinstall of the latest is
queued until the iPhone reconnects (or `fork/build-ios.sh open`).

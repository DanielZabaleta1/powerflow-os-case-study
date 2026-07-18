# Architecture Decision Records

Short-form ADRs for the decisions behind Power Flow OS. Each one follows the same shape: the problem that forced a choice, the options on the table, the trade-offs of each, and what got picked and why.

---

## ADR-001: Workflow engine — n8n over Zapier/Make

**Problem.** Need an orchestration layer to run scheduled scrapes, AI drafting, and follow-up logic without building a backend from scratch.

**Options considered.**
- Zapier — fastest to start, huge integration library.
- Make (Integromat) — similar to Zapier, slightly cheaper at scale.
- n8n — open-source, self-hostable, node-based.

**Trade-offs.** Zapier and Make bill per task, which gets expensive fast at the volumes this system runs (drafts + follow-ups + digests, multiple times a day). Both also store workflow logic inside their own UI/format — there's no real way to version it in git or diff a change. n8n has a steeper initial learning curve and its native AI-provider nodes lag behind on model support.

**Decision.** n8n. No per-task ceiling, a real self-host path if volume ever justifies it, and every workflow is a JSON file that lives in this repo and can be diffed like code.

---

## ADR-002: Database — Supabase over Airtable

**Problem.** Need a shared data layer that both the n8n workflows and the CRM read and write, without the two drifting out of sync.

**Options considered.**
- Google Sheets — the original v1 plan, zero setup.
- Airtable — spreadsheet ergonomics with an API.
- Supabase — hosted Postgres with a REST/PostgREST layer.

**Trade-offs.** Sheets and Airtable are fast to start but cap out fast: no real joins, no constraints, no row-level security, and API rate limits that bite once the system runs on a schedule instead of by hand. Supabase means writing actual SQL and thinking about schema up front.

**Decision.** Supabase. Real Postgres means the CRM and the workflows can share one schema with constraints and RLS, the free PostgREST API removes the need for a custom backend, and it scales without a tool migration later.

---

## ADR-003: AI provider — Gemini 2.5 Flash over Claude

**Problem.** WF1 (drafting), WF4 (content), and WF5 (call prep) need an LLM call. The original plan was Claude (`claude-opus-4-8`). Mid-build, the Anthropic API key got blocked by a billing error, which forced an unplanned decision under time pressure.

**Options considered.**
- Wait for the billing issue to resolve and keep the Claude plan.
- Switch to Gemini 2.5 Flash (free tier).
- Switch to another paid provider (OpenAI).

**Trade-offs.** Waiting risked stalling the entire build mid-momentum for an indefinite amount of time. Gemini's free tier has a lower quality ceiling than a frontier paid model, but every draft is reviewed by a human before it ever reaches a prospect, which caps how much that ceiling actually matters. Because the integration is a plain HTTP Request node with prompts stored in the `config` table (not a provider-specific SDK or native n8n node), switching providers is a one-node edit rather than a rebuild — the cost of "trying it and reverting" was near zero.

**Decision.** Gemini 2.5 Flash, free tier. Marked permanent 2026-07-09 once it was clear draft quality held up under human review. $0/month vs. an estimated $3–6/month for the Claude plan at full volume — a calculated trade, not an accident. Revisited if volume or the draft edit-rate changes the calculus.

---

## ADR-004: HTTP Request node over native n8n AI nodes

**Problem.** n8n ships native nodes for several AI providers, including Anthropic. Need to decide whether to use them or call the provider's API directly.

**Options considered.**
- Native Anthropic/Gemini nodes — less code, built-in credential handling.
- Generic HTTP Request node calling the provider's REST API directly.

**Trade-offs.** Native nodes are faster to wire up but couple the workflow to whatever model list and request shape that node's maintainers have kept current — the model dropdown lags behind provider releases, and switching providers means rebuilding the node, not editing a URL. The HTTP Request node requires hand-writing the request body and parsing the response, which is more upfront work.

**Decision.** HTTP Request node against the provider's REST API directly, with the model name and headers set explicitly in the node. This is what turned the ADR-003 pivot into a same-day change instead of a rebuild — the entire "provider swap" was editing one URL, one header block, and one response-parsing function.

---

## ADR-005: Custom CRM over a SaaS CRM (HubSpot free / Pipedrive)

**Problem.** Need a human-facing interface to review AI drafts, track pipeline state, and see weekly metrics — without duplicating the data n8n already owns.

**Options considered.**
- HubSpot (free tier) — generic CRM, wide adoption.
- Pipedrive — pipeline-first CRM, cheap entry tier.
- Custom CRM reading the same Supabase tables as the workflows.

**Trade-offs.** Both SaaS options mean a second data store: leads would have to sync between the CRM and the Supabase tables n8n reads/writes, with all the drift and reconciliation logic that implies. Power Flow's actual pipeline stages (`New → Ready → Contacted → T2 sent → T3 sent → Replied → Call booked → Proposal sent → Won/Lost/Dormant`) don't map cleanly onto a generic CRM's stage model either — it would mean either fighting the tool's assumptions or losing the specificity that makes the follow-up state machine work.

**Decision.** A custom CRM (React + Vite + TypeScript on Vercel) that reads and writes the exact same Supabase tables the n8n workflows use. One source of truth, one schema, no sync layer to maintain or break.

---

## ADR-006: Manual last-mile send instead of automating LinkedIn outreach

**Problem.** The system drafts personalized messages automatically. The obvious next step is to also send them automatically.

**Options considered.**
- Automate the LinkedIn send via browser automation or an unofficial API.
- Keep the send manual: the CRM surfaces the drafts, a human copies and sends.

**Trade-offs.** Automating the send would remove the last manual step in the loop and close the gap between "drafted" and "sent." But LinkedIn's Terms of Service prohibit automating outbound messages, and the enforcement risk is account suspension — which would kill the primary outreach channel outright, not just slow it down.

**Decision.** Manual send, permanently, by design. This is a risk decision, not a technical limitation: the cost of a banned account is categorically worse than the cost of a few extra minutes of copy-paste per message.

---

## ADR-007: An events table (`activities`) instead of reading status snapshots for metrics

**Problem.** The dashboard needs to report weekly counts — outreach sent, replies, calls booked, follow-ups completed. The obvious source is the `leads.status` column, which already tracks where each lead sits in the pipeline.

**Options considered.**
- Derive weekly metrics by diffing `leads.status` over time.
- Log every meaningful action as an immutable row in a separate `activities` table, and derive metrics from that.

**Trade-offs.** `status` is mutable state — it gets overwritten every time a lead moves stages, so there's no way to reliably answer "how many replies came in this week" from status alone without snapshotting the whole table on a schedule and diffing it, which is fragile and easy to get wrong around edge cases (a lead that moves through two stages in one day, a status that gets corrected by hand). An events table means one extra write per meaningful action, but the reads become trivial and provably correct.

**Decision.** `activities` — an append-only event log (`kind`: `sent`, `reply_received`, `call_booked`, `proposal_sent`, `followup_done`, etc.) that both WF6 (dashboard autofill) and the CRM's dashboard read from. Status is what a lead *is*; activities are what *happened*. Correct metrics need facts, not snapshots of current state.

# Workflows

The six n8n workflows that run Power Flow OS. Sanitized source JSON for each lives in [`/n8n`](../n8n).

---

## WF1 — Enrich & Draft

**Trigger:** schedule, every 2 hours, 6am–9pm Costa Rica time.

**Does:** reads every lead with `status = New`, fetches the prospect's company site (continues on failure — plenty of sites block scrapers), strips it down to plain text, and sends it to Gemini 2.5 Flash along with the lead's name, role, company, and any context notes. The system prompt encodes the voice rules directly: under 5 lines, one specific observation, one honest positioning line, always end on a real question, no em dashes, no "I'd love to."

**Writes:** `draft_msg` and `status = Ready` on the lead.

**Design note:** the LLM only ever sees one job — write the first-touch message. Everything after that in the pipeline is either a human decision or a template, which keeps this the only workflow where draft quality is actually a variable worth monitoring.

---

## WF2 — Daily Digest

**Trigger:** schedule, 7:25pm Monday–Friday.

**Does:** pulls every lead and every agency, filters down to what's actually due today — leads with `status = Ready` (drafts to send), leads with a `next_action_date` on or before today, agencies with a `followup_date` on or before today — and builds a single HTML email listing all of it, grouped and counted.

**Writes:** nothing to the database; sends one email via Microsoft Outlook.

**Design note:** this workflow doesn't call an LLM at all — it's plain aggregation and HTML templating in a Code node. It's also the anti-decision engine of the whole system: the email is a closed list, not an open question. There's nothing to plan at 7:25pm, only things to execute.

---

## WF3 — Follow-up State Machine

**Trigger:** schedule, daily at 6am.

**Does:** reads `config` (for the follow-up templates) and every lead, computes days-since-last-touch per lead, and applies a fixed rule set: `Contacted` +4 days without a reply drafts Touch 2; `T2 sent` +8 days drafts the Touch 3 breakup message; `T3 sent` +3 days with no reply marks the lead `Dormant`; `Proposal sent` +3 days drafts a check-in, +7 days drafts a more direct ask. Templates come from `config` with `{{first_name}}` / `{{company}}` placeholders filled by find-and-replace — no LLM call anywhere in this workflow.

**Writes:** `draft_msg`, `status`, `next_action`, and `next_action_date` per lead, via a direct PostgREST `PATCH` (not the native Supabase node) because the set of fields to update varies per lead.

**Design note:** this is the piece that does the actual work of "never forgetting a follow-up," and it's the most boring workflow in the system on purpose — deterministic logic is easier to trust running unattended every morning than an LLM call would be. The four templates it actually reads from `config` are `t2_touch`, `t3_breakup`, `proposal_followup_d3`, and `proposal_followup_d7`. `config` also seeds a `dormant_resurface` template for the +60-day auto-resurface rule described in the original spec, but that rule was never wired into this workflow's logic — today `Dormant` is a resting state a human has to manually move a lead out of. Listed honestly in the README's "what's next."

---

## WF4 — Sunday Content Batch

**Trigger:** schedule, Sunday 8am.

**Does:** pulls one unused row from `content` where `status = topic`, sends it to Gemini with a system prompt tuned for LinkedIn (pain-first opening, "Power Platform" banned from the first three lines, no hashtag spam, ends on a question or provocation), and asks for three distinct angles on the same topic (story, contrarian, practical) as a JSON array.

**Writes:** three new rows in `content` with `status = draft`, and flips the source topic row to `status = posted` so it isn't picked again (the workflow reuses the `posted` status as "consumed" — a naming shortcut carried over from the topic bank, not a real state machine; nothing about the topic row is actually published at this point).

**Design note:** Daniel reviews and posts manually — this workflow produces raw material, it doesn't publish anything itself.

---

## WF5 — Discovery Prep Brief

**Trigger:** Calendly's native n8n trigger node (`invitee.created`), registered via OAuth2 — not a manually-wired webhook.

**Does:** on a new booking, extracts the invitee's name, email, and their three intake-form answers (most manual process today, how many people touch it, what they've already tried), tries to match them to an existing lead by email, and — if matched — updates that lead to `status = Call booked` and logs a `call_booked` activity. Either way (matched or not — someone can book without ever having been a lead), it waits until 2 hours before the scheduled call, then asks Gemini to turn the intake answers into a 5-line brief: who they are, the likely real bottleneck read between the lines of their answers, one sharp question to ask early, and one risk to watch for.

**Writes:** lead `status` + an `activities` row (if matched), then sends the brief by email. No database write for the brief itself.

**Design note:** built ahead of its own gate — it needs real discovery calls to be useful and there aren't enough yet, so it currently sits idle. The `Wait` node's fallback logic for finding `start_time` is defensive: Calendly's webhook payload shape isn't fully documented, so the code checks a few possible paths and needs confirming against a real booking before this workflow is trusted at volume.

---

## WF6 — Dashboard Autofill

**Trigger:** schedule, Sunday 5pm.

**Does:** computes the Monday–Sunday range for the week that just ended, reads every `activities` row created in that range, counts them by `kind` (`sent`, `reply_received`, `call_booked`, `proposal_sent`, `followup_done`), and separately counts leads whose `next_action_date` fell in that week for `followups_due`.

**Writes:** one row into `dashboard_weeks`, upserted on `week_start` via PostgREST (`on_conflict=week_start`, `resolution=merge-duplicates`) so re-running the workflow twice never double-counts a week. `revenue_usd` and `hours` are left at 0 — those get filled in by hand in the CRM, since no automation in this system can observe either one.

**Design note:** reads `activities`, never `leads.status` — see [ADR-007](decisions.md#adr-007-an-events-table-activities-instead-of-reading-status-snapshots-for-metrics) for why that distinction matters for correctness.

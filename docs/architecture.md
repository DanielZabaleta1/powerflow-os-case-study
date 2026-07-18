# Architecture

Three views of the same system: how data flows through it end to end, how a single lead moves through the follow-up state machine, and how the underlying tables relate to each other.

---

## 1. System architecture

```mermaid
flowchart TD
    A["Prospect data entered<br/>CRM or manual entry"] --> WF1["WF1: Enrich &amp; Draft<br/>scrape site + Gemini draft<br/>every 2h, 6am-9pm CR"]
    WF1 --> DB[("Supabase<br/>public schema")]
    DB -->|"status = Ready"| CRM["CRM: lead review<br/>React + Vite"]
    CRM --> Human{{"Human sends<br/>LinkedIn / email"}}
    Human -->|"manual, by design"| DB
    DB --> WF3["WF3: Follow-up state machine<br/>daily 6am"]
    WF3 --> DB
    DB --> WF2["WF2: Daily Digest<br/>7:25pm Mon-Fri"]
    WF2 -->|"email"| Human
    DB --> WF6["WF6: Dashboard Autofill<br/>Sunday 5pm"]
    WF6 --> DB
    DB --> Dash["CRM: Dashboard"]
    WF5["WF5: Discovery Prep Brief<br/>Calendly trigger, gated"] -.->|"on call booked"| DB
    WF4["WF4: Sunday Content Batch<br/>Sunday 8am"] --> DB
    DB --> ContentPage["CRM: Content review"]

    classDef manual fill:#FFF3CD,stroke:#B08900,stroke-width:2px;
    class Human manual
```

Supabase is the hub, not n8n and not the CRM — every workflow and every CRM page reads and writes the same tables, so there's no sync step anywhere in this diagram to fall out of date. The one yellow node is the only manual step in the entire loop: a human copying a drafted message and hitting send on LinkedIn or email. That's not a missing automation, it's a deliberate stop — see [ADR-006](decisions.md#adr-006-manual-last-mile-send-instead-of-automating-linkedin-outreach). WF5 is drawn with a dashed line because it's gated behind the first real discovery call and currently idle — built ahead of schedule, waiting for volume to justify activating it.

---

## 2. Follow-up state machine

```mermaid
stateDiagram-v2
    [*] --> New: lead created
    New --> Ready: WF1 drafts message (Gemini)
    Ready --> Contacted: human sends (manual, LinkedIn/email)
    Contacted --> T2sent: +4d since last touch\nWF3 auto-drafts Touch 2
    T2sent --> T3sent: +8d since last touch\nWF3 auto-drafts Touch 3 (breakup)
    T3sent --> Dormant: +3d, no reply
    Contacted --> Replied: prospect responds
    T2sent --> Replied: prospect responds
    T3sent --> Replied: prospect responds
    Replied --> CallBooked: Calendly booking\nWF5 sends prep brief
    CallBooked --> ProposalSent: proposal sent
    ProposalSent --> Won: client signs
    ProposalSent --> Lost: client declines
    Dormant --> Contacted: manually resurfaced

    note right of ProposalSent
        WF3 checks in automatically:
        +3d after Proposal sent → check-in draft
        +7d after Proposal sent → direct-ask draft
    end note

    note right of Dormant
        Spec'd but not yet coded: auto-resurface
        at +60d. Today Dormant is a resting
        state — resurfacing is manual.
        See docs/decisions.md and the README's
        "what's next" section.
    end note
```

This is the most defensible piece of the system in an interview, because every arrow after `Contacted` is a cron job deciding what happens next, not a person remembering to follow up. WF3 runs once a day, computes days-since-last-touch for every lead, and matches it against a fixed rule set: 4 days of silence after first contact drafts Touch 2, 8 more days drafts the breakup message, 3 more days of nothing marks the lead `Dormant`. A won or lost proposal isn't the end of the automation either — WF3 keeps checking in at +3 and +7 days with no reply. None of this calls an LLM: the drafts come from fixed templates in `config` with placeholders (`{{first_name}}`, `{{company}}`) filled in by find-and-replace. AI only runs where it earns its cost — the first-touch message, which actually needs to sound specific to the prospect. The state machine is intentionally boring, and that's the point: boring is what makes it trustworthy enough to run unattended every morning at 6am.

---

## 3. Data model

```mermaid
erDiagram
    LEADS ||--o{ ACTIVITIES : generates
    AGENCIES ||--o{ ACTIVITIES : generates

    LEADS {
        bigint id PK
        text name
        text role
        text company
        text channel
        text linkedin_url
        text company_url
        text email
        text context_notes
        text status
        text draft_msg
        date sent_date
        date last_touch
        text next_action
        date next_action_date
        text reply_summary
        text notes
        timestamptz created_at
        timestamptz updated_at
    }

    AGENCIES {
        bigint id PK
        text agency
        text website
        text country
        text contact_name
        text email
        text linkedin
        text status
        date sent_date
        date followup_date
        text notes
    }

    ACTIVITIES {
        bigint id PK
        bigint lead_id FK
        bigint agency_id FK
        text kind
        text detail
        timestamptz created_at
    }

    CONTENT {
        bigint id PK
        date week
        text topic
        text draft
        text status
        text post_url
    }

    DASHBOARD_WEEKS {
        bigint id PK
        date week_start
        int outreach_sent
        int replies
        int calls_booked
        int proposals_sent
        numeric revenue_usd
        int followups_due
        int followups_done
        numeric hours
    }

    CONFIG {
        text key PK
        text value
    }
```

The one design decision worth explaining here: `activities` is an append-only event log, not a mirror of `leads.status`. Status is mutable — it gets overwritten every time a lead moves stages, so by the time Sunday's dashboard job runs, there's no way to reconstruct "how many replies came in this week" from status alone. `activities` logs each meaningful event (`sent`, `reply_received`, `call_booked`, `proposal_sent`, `followup_done`, ...) as an immutable row the moment it happens. WF6 aggregates `activities` by `kind` for the week and upserts one row into `dashboard_weeks`, keyed on `week_start` so re-running the job never double-counts. `config` is business config (offer text, follow-up templates) that n8n reads at runtime — editing copy there never means editing a workflow. Full reasoning: [ADR-007](decisions.md#adr-007-an-events-table-activities-instead-of-reading-status-snapshots-for-metrics).

*The diagram shows the outreach core. Two app-internal tables — `weekly_reviews` (weekly retro notes from the CRM's Sunday ritual) and `settings` (CRM app config, distinct from `config` which is business config read by n8n) — are omitted here for clarity but included in the published [schema.sql](../supabase/schema.sql).*

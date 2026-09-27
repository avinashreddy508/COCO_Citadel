# Citadel — Risk, Fraud and Regulatory Intelligence Copilot

> **Snowflake CoCo CLI Hackathon 2026**
> Author: Avinash L | Account: JSTEYZM-MP60447

---

## Overview

Citadel is a compliance-grade AI copilot for banking and NBFC risk teams. It surfaces fraud
signals, credit watch-list alerts, and liquidity breaches through natural language, and cites
the exact regulation behind every finding — so answers are audit-ready, not just informative.

**The core problem it solves:**
Banking and NBFC teams manage real-time fraud, liquidity, and credit risk largely manually
today. Regulatory reporting (AML, Basel III, local regulations) is paper-heavy and slow.
Citadel connects transaction data, account exposures, and policy text so a business or
compliance user can ask a question and get an answer with evidence — from signal to finding
to documented report.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    CITADEL_DB.RISK                       │
│                                                         │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────────┐   │
│  │  CUSTOMERS  │  │  ACCOUNTS   │  │ TRANSACTIONS  │   │
│  │  500 rows   │  │  800 rows   │  │  50,000 rows  │   │
│  └──────┬──────┘  └──────┬──────┘  └───────┬───────┘   │
│         │                │                  │           │
│  ┌──────▼──────┐  ┌──────▼──────────────────▼───────┐   │
│  │   CREDIT_   │  │         RISK_FLAGS               │   │
│  │  EXPOSURES  │  │   9,318 unified signals           │   │
│  │  300 rows   │  │   evidence_payload (VARIANT)      │   │
│  └─────────────┘  │   threshold_rationale (TEXT)      │   │
│                   └──────────────────────────────────┘   │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────────┐   │
│  │  LIQUIDITY_ │  │ REGULATORY_ │  │    CASE_      │   │
│  │  POSITIONS  │  │  FILINGS    │  │ ESCALATIONS   │   │
│  │  450 rows   │  │  200 rows   │  │   50 rows     │   │
│  └─────────────┘  └─────────────┘  └───────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │         CITADEL_RISK_INTELLIGENCE               │   │
│  │         Semantic View (Cortex Analyst)          │   │
│  │   6 tables · 5 relationships · 18 metrics       │   │
│  │   30+ named filters · 8 verified queries        │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌──────────────────┐   ┌───────────────────────────┐  │
│  │  POLICY_DOCS     │   │   CITADEL_SEARCH_SVC      │  │
│  │  10 documents    │──▶│   Cortex Search (ACTIVE)  │  │
│  │  Basel III, FATF │   │   snowflake-arctic-embed  │  │
│  │  RBI, FinCEN,    │   └───────────────────────────┘  │
│  │  SAR narratives  │                                   │
│  └──────────────────┘                                   │
└─────────────────────────────────────────────────────────┘
                          │
              ┌───────────▼────────────┐
              │     CITADEL_AGENT      │  ← Phase 3
              │  Cortex Agent          │
              │  search + analyst      │
              └───────────┬────────────┘
                          │
              ┌───────────▼────────────┐
              │   Streamlit-in-Snow    │  ← Phase 4
              │   Chat UI + Dashboard  │
              └────────────────────────┘
```

---

## Build Status

| Phase | Status | Description |
|---|---|---|
| **Phase 1 — Foundation** | COMPLETE | Database, 8 tables, 52K+ rows, RBAC, masking |
| **Phase 2 — Intelligence** | COMPLETE | RISK_FLAGS, semantic view, Cortex Search |
| **Phase 3 — Agent** | COMPLETE | CITADEL_AGENT wiring search + semantic view |
| **Phase 4 — App** | COMPLETE | CITADEL_APP Streamlit v3: Chat · Dashboard · Audit Trail · production UI |
| **Stretch — Actions** | COMPLETE | SAR/flag/escalate procs + AI narrative + 2 MCP servers + OAuth + CoCo registry |
| **Last-Mile Fixes** | COMPLETE | AUDIT_LOG seeded, AI SAR narrative, RISK_FLAGS_REFRESH Task, v3 UI |
| **Demo Package** | COMPLETE | citadel_demo.html (13 slides) + DEMO_SCRIPT.md narration guide |

---

## Phase 1 — Foundation

### Database Objects

**Database:** `CITADEL_DB` | **Schema:** `RISK` | **Warehouse:** `CITADEL_WH` (XSMALL)

#### Tables

| Table | Rows | Description |
|---|---|---|
| `CUSTOMERS` | 500 | Customer master. PII: `full_name` masked, `national_id` masked. PEP flag (~2%), sanctions flag (~1%). Segments: RETAIL, SME, CORPORATE, PRIVATE_BANKING. |
| `ACCOUNTS` | 800 | Account master. ~5% NPA, ~3% FROZEN. Types: SAVINGS, CURRENT, LOAN, CREDIT_CARD, OVERDRAFT. `account_number` masked by role. |
| `TRANSACTIONS` | 50,000 | Transaction spine. ~18% flagged with 4 fraud patterns: VELOCITY, STRUCTURING, CROSS_BORDER, ROUND_NUMBER. |
| `CREDIT_EXPOSURES` | 300 | Basel III parameters: PD, LGD, EAD, RWA, Expected Loss. 75 watch-list (PD > 0.15). Total RWA: $632M. |
| `LIQUIDITY_POSITIONS` | 450 | 90 days × 5 tenor buckets. LCR and NSFR computed. 22 LCR breach days. |
| `REGULATORY_FILINGS` | 405+ | SAR, CTR, STR filings. AI-generated narratives via `CORTEX.COMPLETE`. Row-level security restricts analyst access. NARRATIVE column VARCHAR(16000). |
| `CASE_ESCALATIONS` | 53+ | Escalation lifecycle. Status: OPEN → UNDER_REVIEW → ESCALATED → RESOLVED → CLOSED. |
| `AUDIT_LOG` | 60+ | Immutable action trail. Populated by stored procs. No DELETE/UPDATE grant on any Citadel role. BCBS 239 Principle 2. |

### Fraud Signal Design

| Pattern | Rule | Regulatory Basis |
|---|---|---|
| `VELOCITY` | 5+ transactions on same account within 1 hour | FinCEN SAR field 35(a) — rapid movement of funds; internal rule V-001 |
| `STRUCTURING` | Amount $9,800–$9,999 | 31 CFR §1010.314 (BSA/FinCEN CTR threshold evasion); PMLA Schedule Rule 3(B) |
| `CROSS_BORDER` | Wire to FATF grey/black-list country | FATF Recommendation 19; RBI Master Direction on KYC 2016 §38 |
| `ROUND_NUMBER` | Round-dollar amount >$10,000 | FATF TBML Typology Report 2020; internal rule R-007 |

### Credit Risk Thresholds

| Flag | Threshold | Regulatory Basis |
|---|---|---|
| `HIGH_PD` | PD > 0.15 | Basel III ICAAP internal watch-list (BB-/B+ equivalent); Credit Policy §4.2 |
| `HIGH_UTILISATION` | Utilisation > 90% | Internal Credit Policy §6.1 |
| `NPA` | 90 days past due | RBI Master Circular on IRAC 2023; SUBSTANDARD/DOUBTFUL/LOSS sub-classification |

### Liquidity Thresholds

| Flag | Threshold | Regulatory Basis |
|---|---|---|
| `LCR_BREACH` | LCR ratio < 1.0 (100%) | Basel III Art. 412 / BCBS Jan 2013 §415; notify supervisor within 2 business days |
| `NSFR_BREACH` | NSFR ratio < 1.0 (100%) | Basel III Art. 428b (effective Jan 2021) |

### RBAC Model

```
CITADEL_ADMIN
  ├── CITADEL_COMPLIANCE_OFFICER
  │     └── CITADEL_RISK_MANAGER
  │           └── CITADEL_RISK_ANALYST
  └── CITADEL_AUDITOR
```

| Role | Tables | Write | Masking | Future EXECUTE |
|---|---|---|---|---|
| `CITADEL_ADMIN` | All (DDL+DML) | Yes | None | Yes |
| `CITADEL_COMPLIANCE_OFFICER` | All + REGULATORY_FILINGS write | Yes | PAN masked | `file_sar_draft` |
| `CITADEL_RISK_MANAGER` | All + CASE_ESCALATIONS write | Partial | PAN + acct last-4 | `escalate_case`, `flag_account` |
| `CITADEL_RISK_ANALYST` | Views only | No | PAN + acct + name masked | None |
| `CITADEL_AUDITOR` | All incl. AUDIT_LOG | No | PAN + acct masked | None |

**Masking policies:**
- `mask_national_id` → `CUSTOMERS.national_id` — analysts see `XXX-XX-1234`
- `mask_full_name` → `CUSTOMERS.full_name` — analysts see `James ***`
- `mask_account_number` → `ACCOUNTS.account_number` — analysts see `XXXX-XXXX-0234`

**Row access policy:**
- `rap_regulatory_filings` → `REGULATORY_FILINGS` — analysts see zero rows (double-protected: no SELECT grant + row policy)

---

## Phase 2 — Intelligence Layer

### RISK_FLAGS Table (9,318 rows)

Central risk signal queue. Every row is designed to be **proc-trigger ready** — a stored
procedure can act on any flag without additional joins.

**Key columns:**

| Column | Type | Purpose |
|---|---|---|
| `flag_domain` | TEXT | FRAUD \| CREDIT \| LIQUIDITY |
| `flag_type` | TEXT | VELOCITY, STRUCTURING, HIGH_PD, LCR_BREACH, etc. |
| `severity` | TEXT | LOW \| MEDIUM \| HIGH \| CRITICAL |
| `flag_status` | TEXT | OPEN \| UNDER_REVIEW \| ACTIONED \| DISMISSED |
| `customer_id` | NUMBER | FK — pre-joined, no query needed in proc |
| `account_id` | NUMBER | FK — pre-joined |
| `txn_id` | VARCHAR | Primary triggering transaction |
| `threshold_rationale` | VARCHAR(500) | Regulatory citation (safe to quote in audit findings) |
| `evidence_payload` | VARIANT | JSON snapshot of all source fields — proc acts on this directly |
| `flag_score` | NUMBER | 0-100 composite score (0-40 low, 41-65 medium, 66-100 high) |
| `action_taken` | VARCHAR | Set by stored proc: SAR_FILED \| ACCOUNT_FLAGGED \| CASE_ESCALATED |

**Signal counts:**

| Domain | Count |
|---|---|
| FRAUD | 8,971 |
| CREDIT | 116 |
| LIQUIDITY | 231 |
| **Total** | **9,318** |

### Semantic View: CITADEL_RISK_INTELLIGENCE

Cortex Analyst semantic model over 6 tables.

**Tables included:** `risk_flags`, `transactions`, `accounts`, `customers`, `credit_exposures`, `liquidity_positions`

**Key metrics defined (with regulatory descriptions):**
- `open_flag_count` — Open signals not yet actioned
- `total_flagged_transactions` — Suspicious transactions count
- `total_flagged_amount` — USD value of flagged transactions
- `watch_list_count` — Facilities with PD > 0.15 (Basel III ICAAP threshold)
- `total_rwa` — Total Risk-Weighted Assets ($632M in demo data)
- `total_expected_loss` — IFRS 9 ECL provision basis
- `lcr_breach_day_count` — Days below 100% LCR (Basel III Art. 412)
- `npa_account_count` — Non-Performing Accounts (RBI IRAC)
- `pep_customer_count` — Politically Exposed Persons (FATF R.12)
- `sanctioned_customer_count` — Sanctions list matches

**Named filters:** `open_flags`, `fraud_flags`, `credit_flags`, `liquidity_flags`, `high_risk_customers`, `pep_customers`, `lcr_breach_days`, `npa_accounts`, and more.

**8 Verified Queries pre-registered:**
1. Which accounts show fraud-risk patterns this week?
2. What is the LCR trend over the last 30 days?
3. Show me the credit watch-list broken down by sector
4. Which high-risk customers have open fraud flags this week?
5. Give me a summary of open risk flags by domain and severity
6. Show me structuring transactions and the customers behind them
7. What is the total RWA exposure by sector and internal rating?
8. Show me the days where LCR was below 100 percent with details

**YAML file:** `citadel_semantic_model.yaml` (deploy with `upload_semantic_view_yaml.py`)

### Policy Documents: CITADEL_SEARCH_SVC

10 documents indexed by Cortex Search (model: `snowflake-arctic-embed-m-v1.5`):

| # | Title | Type |
|---|---|---|
| 1 | Basel III LCR Summary | REGULATION |
| 2 | Basel III NSFR Summary | REGULATION |
| 3 | FinCEN Structuring / CTR Requirements | REGULATION |
| 4 | FATF Recommendations 12, 16, 19 | REGULATION |
| 5 | RBI IRAC Master Circular 2023 | REGULATION |
| 6 | SAR Narrative — Case CASE-000042 | SAR_NARRATIVE |
| 7 | Audit Finding — Real Estate Concentration Q2 2026 | AUDIT_FINDING |
| 8 | Internal AML Policy AML-POL-003 | INTERNAL_POLICY |
| 9 | FAQ — STR vs SAR | FAQ |
| 10 | BCBS 239 — Risk Data Aggregation | REGULATION |

---

## Phase 3 — Cortex Agent (COMPLETE)

`CITADEL_AGENT` (`CITADEL_DB.RISK.CITADEL_AGENT`) wires two tools:

| Tool | Type | Resource |
|---|---|---|
| `RiskSignalAnalytics` | `cortex_analyst_text_to_sql` | `CITADEL_RISK_INTELLIGENCE` semantic view |
| `RegulatoryKnowledgeSearch` | `cortex_search` | `CITADEL_SEARCH_SVC` search service |

**System prompt key behaviours:**
- Always includes `threshold_rationale` field verbatim (pre-approved regulatory citation)
- Cites PEP status for any customer (triggers FATF R.12 EDD)
- States Basel III Art. 412 notification obligation for any LCR < 100%
- Uses both tools sequentially for compound questions (data + regulation)
- Refuses to suggest tipping off customers about SAR investigations (31 USC 5318(g)(2))

**Smoke test result:** Passed — agent correctly introduces all four capability areas and cites Basel III Art. 412, Art. 428b, FATF R.19, RBI IRAC, FinCEN/BSA rules from a single "What can you help me with?" query.

---

## Phase 4 — Streamlit App v3 (COMPLETE)

`CITADEL_APP` (`CITADEL_DB.RISK.CITADEL_APP`) — production-grade dark UI.
App file: `@CITADEL_DB.RISK.CITADEL_STAGE/app/streamlit_app.py` (396 lines).

**Access:**
```
Snowsight → Projects → Streamlit → CITADEL_APP  (in CITADEL_DB.RISK)
```

**Three tabs:**

| Tab | Contents |
|---|---|
| 💬 Chat with CITADEL | Two independent chat panels, each with its own input, Send button, and separate conversation history. Left panel is scoped to fraud/LCR/credit/SAR/regulatory questions with 8 quick-question shortcuts (the Verified Queries below); right panel is open-ended with its own shortcuts. Both call `SNOWFLAKE.CORTEX.COMPLETE` directly with live SQL-sourced context (risk flags, LCR trend, credit watch-list, audit actions by role) — no REST API/SSE layer. Message bubbles with timestamps, newest-first per panel. |
| 📊 Risk Dashboard | 4 KPI cards · bar chart (flags by domain/severity) · LCR 30-day trend · quick-action buttons for top CRITICAL flags · filterable HTML flags table · AI board report · CSV export. |
| 📋 Audit Trail | Summary KPI row · action timeline (icon tiles per action type) · search filter · CSV export · BCBS 239 traceability note. |

**UI design system:**
- Full CSS custom property system for the light-mode design (`--bg #F5F7FA`, `--pri #0073CF`, semantic color variables)
- Streamlit chrome hidden (menu, toolbar, footer, deploy button)
- System UI font stack for UI, `tabular-nums` for numbers and IDs
- KPI cards with per-domain accent stripe, `tabular-nums` large values, contextual badges
- Custom HTML table with domain/severity badge components, score color-coding
- Audit timeline with colored icon tiles per action type — flat-line SVG icon set (no emoji), for cross-platform visual consistency
- `st.form` replaces `st.chat_input` (SiS warehouse runtime uses Streamlit < 1.23)
- `_rerun()` helper wraps both `st.rerun()` and `st.experimental_rerun()`

**Deployment (warehouse runtime — `snow` CLI not required):**
```bash
# Upload app file
python -c "
import snowflake.connector, tomllib, pathlib
p = tomllib.load(open(str(pathlib.Path.home() / '.snowflake/connections.toml'), 'rb'))['Sept-6_AHap']
p.update({'database':'CITADEL_DB','schema':'RISK','warehouse':'CITADEL_WH'})
conn = snowflake.connector.connect(**p)
conn.cursor().execute('PUT file://citadel/app/streamlit_app.py @CITADEL_DB.RISK.CITADEL_STAGE/app/ OVERWRITE=TRUE AUTO_COMPRESS=FALSE')
conn.close()
"
# Then in Snowsight / deploy.sql:
# CREATE OR REPLACE STREAMLIT CITADEL_DB.RISK.CITADEL_APP ...
```

---

## Last-Mile Fixes (COMPLETE — 2026-09-06)

| Fix | Detail |
|---|---|
| AUDIT_LOG seeded | 58+ rows: 22 FILE_SAR · 17 ESCALATE_CASE · 16 FLAG_ACCOUNT entries spanning 90 days, 4 compliance officers |
| AI SAR narrative | `FILE_SAR_DRAFT` now calls `SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-6', ...)` inside the stored proc. Generates FinCEN SAR Field 35(a) format narrative. NARRATIVE column widened to VARCHAR(16000). |
| Real-time Task | `RISK_FLAGS_REFRESH` — every 15 minutes, detects new flagged transactions and inserts them into RISK_FLAGS. State: `started`. |
| v3 UI | Full production-grade Streamlit UI rewrite (dark design system, 3 tabs, action buttons, CSV/report export — see Phase 4 section). |
| Demo package | `citadel_demo.html` (13-slide interactive deck) + `CITADEL_DEMO_PRESENTATION.html` (10-slide) + `DEMO_SCRIPT.md` narration guide with exact SQL. |
| Session role fix | `REGULATORY_FILINGS` RAP blocks `CITADEL_MCP_READER_ROLE` (the session default). Always prefix queries with `USE ROLE ACCOUNTADMIN;` when touching that table. |
| End-to-end chain verified | Flag #472 → `FILE_SAR_DRAFT` → Filing #1000 (AI narrative) → `FLAG_ACCOUNT(726)` FROZEN → Case #53 `ESCALATED` → AUDIT_LOG 3 entries. |

---

## Stretch — Action Layer (COMPLETE)

### Action Stored Procedures

| Procedure | Arguments | Role Required | What It Does |
|---|---|---|---|
| `FILE_SAR_DRAFT(p_flag_id, p_notes)` | flag_id NUMBER, notes VARCHAR | CITADEL_COMPLIANCE_OFFICER | Creates REGULATORY_FILINGS SAR draft from RISK_FLAGS evidence; marks flag ACTIONED; writes AUDIT_LOG |
| `FLAG_ACCOUNT(p_account_id, p_reason, p_linked_flag_id)` | account_id NUMBER, reason VARCHAR, linked_flag_id NUMBER | CITADEL_RISK_MANAGER | Sets ACCOUNTS.status=FROZEN; opens CASE_ESCALATIONS; writes AUDIT_LOG |
| `ESCALATE_CASE(p_case_id, p_escalate_to, p_notes)` | case_id NUMBER, escalate_to VARCHAR, notes VARCHAR | CITADEL_RISK_MANAGER | Sets case status=ESCALATED, appends notes, writes AUDIT_LOG |

All procs use `EXECUTE AS CALLER` — RBAC masking/row policies apply inside. Role check is baked into each proc body.

### MCP Layer — AI Gateway, Action Server, Registry

> Full detail, verified test results, and troubleshooting: **[`MCP_REFERENCE.md`](MCP_REFERENCE.md)**

CITADEL separates MCP into three concerns. The split is enforced by Snowflake RBAC, not
by client convention — a client holding only the reader credential **cannot** file a SAR
or freeze an account.

| Concern | Object | Tools | Session role | Side effects |
|---|---|---|---|---|
| **AI Gateway** (read) | `CITADEL_AGENT_MCP_SERVER` | 1 × `CORTEX_AGENT_RUN` | `CITADEL_MCP_READER_ROLE` | none |
| **Action Server** (write) | `CITADEL_ACTIONS_MCP_SERVER` | 3 × `GENERIC` procedure | `CITADEL_COMPLIANCE_OFFICER` | writes 4 tables |
| **Registry** (discovery) | `SHOW`/`DESCRIBE MCP SERVER`, RFC 9728 metadata, `tools/list` | — | none for metadata | none |

**Base URL:** `https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK`

#### Registry — discovery without credentials

```sql
SHOW MCP SERVERS IN SCHEMA CITADEL_DB.RISK;
DESCRIBE MCP SERVER CITADEL_DB.RISK.CITADEL_AGENT_MCP_SERVER;   -- full tool spec + input schemas
```

An unauthenticated `POST` returns `401` with `WWW-Authenticate: Bearer resource_metadata="..."`,
and that metadata document is public (`200`), advertising the authorization server and
supported scopes. Both are the right first diagnostic when a client won't connect.

#### Tool inventory

| Server | Tool | Type | Required args |
|---|---|---|---|
| Gateway | `citadel_agent` | `CORTEX_AGENT_RUN` | `text` |
| Actions | `file_sar_draft` | `GENERIC` | `p_flag_id` |
| Actions | `flag_account` | `GENERIC` | `p_account_id`, `p_reason` |
| Actions | `escalate_case` | `GENERIC` | `p_case_id`, `p_escalate_to` |

The agent argument is **`text`**, not `message` — confirmed from the `tools/list` input schema.

#### Authentication

| `grant_type` | Result |
|---|---|
| `authorization_code` | `200` — one browser consent |
| `refresh_token` | `200` — scriptable, 90-day validity |
| `client_credentials` | `400 invalid_grant` — **not supported** |
| `jwt-bearer` | `400 unsupported_grant_type` — **not supported** |

**Snowflake OAuth has no machine-to-machine flow.** CLIENT_ID + CLIENT_SECRET alone cannot
mint a token: consent once in a browser, then the cached refresh token runs unattended.

| Integration | `ALLOWED_ROLES_LIST` | Loopback redirect |
|---|---|---|
| `CITADEL_MCP_READER_OAUTH` | `CITADEL_MCP_READER_ROLE` | `http://localhost:8586/callback` |
| `CITADEL_MCP_ACTION_OAUTH` | `CITADEL_COMPLIANCE_OFFICER` | `http://localhost:8585/callback` |

Credentials: `SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_ACTION_OAUTH');`

The action integration is scoped to `CITADEL_COMPLIANCE_OFFICER` because the procedures are
`EXECUTE AS CALLER` and guard on `CURRENT_ROLE()`. Since `CITADEL_MCP_ACTION_ROLE` is granted
*to* the officer role, one officer token reaches **both** servers and all four tools — and
`AUDIT_LOG.actor_role` then records a named officer rather than a service account.

#### Transport gotchas

- `tools/call` returns **Server-Sent Events** (since 2026-08-20). Send
  `Accept: application/json, text/event-stream`; the stream ends with `data: [DONE]`.
  A client calling `response.json()` fails outright.
- Agent responses are a **nested JSON envelope** — one verified call returned 100,975 bytes
  wrapping a 2,105-character answer. Parse the envelope for the final `text` part.

#### Client registration

CoCo reads **`~/.snowflake/cortex/mcp.json`** — a project-level `.cortex/mcp.json` is *not*
read. Each entry needs `type: "http"` and an `oauth` block with lowercase keys; a
Cursor-style `"auth": {"CLIENT_ID": ...}` block is silently ignored. Manage with `/mcp`
in-session. Tools are namespaced `mcp__citadel-actions__file_sar_draft`.

To make the agent *itself* able to act, register the action server as an MCP Connector
(`CREATE EXTERNAL MCP SERVER` + `ALTER AGENT ... mcp_servers:`) — see `MCP_REFERENCE.md` §6.3.

#### Testing

```powershell
python scripts\test_mcp.py discover                  # no auth — 401 + registry metadata
python scripts\test_mcp.py auth action               # one-time consent, loopback capture
python scripts\test_mcp.py list                      # tools/list, both servers
python scripts\test_mcp.py ask "question"            # AI Gateway
python scripts\test_mcp.py full <flag_id> <acct_id>  # read + write + audit chain
```

Verified 2026-09-06:

| Endpoint | Result |
|---|---|
| `tools/list` both servers | `200` — 1 tool, 3 tools |
| `citadel_agent` | `200` — orchestrated `RegulatoryKnowledgeSearch`, `RiskSignalAnalytics`, `system_execute_sql`; cited 31 CFR §1010.314, 31 USC 5324, SAR 30-day, CTR 15-day, tipping-off 31 USC 5318(g)(2) |
| `file_sar_draft(5445)` | `filing_id 1004`, 2,074-char AI narrative |
| `flag_account(126)` | `status FROZEN`, `case_id 54` auto-opened |
| `escalate_case(54)` | `status ESCALATED` |
| `AUDIT_LOG` | 64 → 67, all three rows `actor_role = CITADEL_COMPLIANCE_OFFICER` |

#### Defects found by the suite (all fixed)

| Defect | Symptom |
|---|---|
| `USAGE ON AGENT` never granted | `200` + *"agent does not exist or access is not authorized"* |
| `USAGE ON PROCEDURE` missing for `FILE_SAR_DRAFT` + `FLAG_ACCOUNT` | tools listed but not invocable |
| Action OAuth scoped to a role the guard rejects | `200` + *"CITADEL_COMPLIANCE_OFFICER or higher required"* |
| `mcp.json` in Cursor schema, missing `type`, wrong location | CoCo never connected |
| `AUDIT_LOG` sorted by `log_id DESC` | `log_id` is per-procedure, so 303 is newer than 403 — timeline displayed out of order. Now sorts by `event_ts DESC` |

Missing tool grants return **`HTTP 200` with an error in the body**, not `401` — easy to
misdiagnose as a transport problem.

### Cortex Extension Registry

`CITADEL_DB.RISK.CITADEL_RISK_COPILOT` — published account-wide. Any CoCo user can install:
```
Projects → Skills marketplace → search "citadel"
```
Skill file: `citadel/coco_plugin/skills/citadel-mcp-connector/SKILL.md`

---

## Quick Start (for judges / reviewers)

```sql
-- 1. Verify data is in place
SELECT COUNT(*) FROM CITADEL_DB.RISK.TRANSACTIONS;         -- 50,000
SELECT COUNT(*) FROM CITADEL_DB.RISK.RISK_FLAGS;           -- 9,318
SELECT COUNT(*) FROM CITADEL_DB.RISK.POLICY_DOCS;          -- 10

-- 2. Check semantic view
SHOW SEMANTIC VIEWS IN SCHEMA CITADEL_DB.RISK;

-- 3. Check search service
SHOW CORTEX SEARCH SERVICES IN SCHEMA CITADEL_DB.RISK;

-- 4. Test a key query — fraud pattern distribution
SELECT fraud_pattern, COUNT(*) AS cnt, ROUND(AVG(flag_score),1) AS avg_score
FROM CITADEL_DB.RISK.TRANSACTIONS
WHERE is_flagged = TRUE
GROUP BY fraud_pattern ORDER BY cnt DESC;

-- 5. Test risk flags by domain and severity
SELECT flag_domain, severity, COUNT(*) AS cnt
FROM CITADEL_DB.RISK.RISK_FLAGS
WHERE flag_status = 'OPEN'
GROUP BY flag_domain, severity
ORDER BY CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END;

-- 6. Test threshold rationale (pitch-ready regulatory citations)
SELECT DISTINCT flag_type, threshold_rationale
FROM CITADEL_DB.RISK.RISK_FLAGS
WHERE flag_domain = 'FRAUD'
ORDER BY flag_type;
```

---

## Project Structure

```
citadel/
├── SKILL.md                          # CoCo skill descriptor and reference card
├── README.md                         # This file
├── DEMO_SCRIPT.md                    # Step-by-step narration guide with exact SQL
├── citadel_demo.html                 # Interactive 13-slide demo deck (keyboard nav)
├── CITADEL_DEMO_PRESENTATION.html    # Full-screen 10-slide animated deck
├── deploy.sql                        # Full idempotent deployment script (~1,610 lines)
├── requirements.txt                  # Python package dependencies
├── citadel_semantic_model.yaml       # Semantic view YAML for Cortex Analyst
├── app/
│   ├── streamlit_app.py              # v3 production-grade Streamlit app (396 lines)
│   └── snowflake.yml                 # Container runtime config (future upgrade)
├── scripts/
│   ├── citadel_config.py             # Shared connection helper
│   ├── verify.py                     # Health check — all 14 Snowflake objects
│   ├── deploy_semantic_view.py       # Deploy / update semantic view YAML
│   ├── chat.py                       # Interactive terminal chat (SSE streaming)
│   └── demo.py                       # Batch-run 8 demo questions → JSON results
└── coco_plugin/
    └── skills/citadel-mcp-connector/
        └── SKILL.md                  # CoCo Extension skill descriptor
```

---

## Deployment

To re-deploy from scratch (idempotent — uses `CREATE OR REPLACE`):

```bash
# Install Python dependencies
pip install -r requirements.txt

# 1. Run all SQL objects (Phases 1-3)
snowsql -f citadel/deploy.sql

# 2. Deploy semantic view (Python)
python citadel/scripts/deploy_semantic_view.py --connection Sept-6_AHap

# 3. Verify everything is in place
python citadel/scripts/verify.py --connection Sept-6_AHap
```

## Python Scripts

All scripts accept `--connection <name>` to select the Snowflake connection. Default: `Sept-6_AHap` or the `SNOWFLAKE_CONNECTION_NAME` environment variable.

```bash
# Verify all objects exist and are healthy
python scripts/verify.py

# Deploy or update the semantic view YAML
python scripts/deploy_semantic_view.py
python scripts/deploy_semantic_view.py --verify-only   # validate without deploying

# Interactive chat with CITADEL_AGENT (requires SNOWFLAKE_PAT for REST API)
export SNOWFLAKE_PAT=<your_personal_access_token>
python scripts/chat.py

# Run all 8 demo questions non-interactively and save JSON results
python scripts/demo.py --output demo_results/
python scripts/demo.py --question 7        # run only question 7 (RWA by sector)
python scripts/demo.py --list              # print all 8 questions
```

**Authentication for REST API (chat.py and demo.py):**
- Set `SNOWFLAKE_PAT` to a Snowflake Personal Access Token (preferred)
- Or the scripts will try to extract a session token from the active connector session

---

## Known Issues & Notes

| Issue | Root Cause | Fix |
|---|---|---|
| `REGULATORY_FILINGS` shows 0 rows | Session defaults to `CITADEL_MCP_READER_ROLE`; table RAP blocks this role | Prefix any direct query with `USE ROLE ACCOUNTADMIN;` |
| `st.chat_input` AttributeError | SiS warehouse runtime uses Streamlit < 1.23 (chat_input added in 1.23) | Fixed in v3: replaced with `st.form` + `st.text_input` |
| AI SAR narrative fallback triggered | `NARRATIVE` column was VARCHAR(4000); AI narrative exceeded limit | Fixed: column widened to VARCHAR(16000) |
| `OBJECT_CONSTRUCT` in VALUES clause | Not supported in Snowflake SQL stored procedures | Use `INSERT ... SELECT ... FROM (SELECT 1)` pattern |
| CASE_ESCALATIONS `case_id` gaps | No AUTOINCREMENT; uses `MAX(case_id)+1` | Handled in procs; sequence gaps are expected |

---

## Key Design Assumptions

All assumptions are flagged in-code with `-- ASSUMPTION:` comments in `deploy.sql`.

| Assumption | Value | Basis |
|---|---|---|
| LCR minimum | 100% | Basel III Art. 412 |
| NSFR minimum | 100% | Basel III Art. 428b |
| Credit watch-list threshold | PD > 0.15 | Basel III ICAAP internal calibration |
| Structuring detection range | $9,800–$9,999 | 31 CFR §1010.314 CTR threshold evasion |
| FATF grey/black-list country codes | IRN, PRK, SYR, MMR, YEM, LBY, SDN, BLR, RUS, VEN | FATF 2024 list |
| PEP flag rate | ~2% | Plausible mid-size bank estimate |
| Fraud flag rate | ~18% | Demo-visible; real-world rate is ~0.1-3% |
| NARRATIVE column | VARCHAR(16000) | Widened from 4000 to accommodate AI-generated SAR narratives (claude-sonnet-4-6 produces 800-3000 char narratives) |
| Synthetic data source | Snowflake GENERATOR() + MOD arithmetic | Deterministic, reproducible |

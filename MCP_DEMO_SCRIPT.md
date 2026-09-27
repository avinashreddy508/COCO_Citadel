# CITADEL MCP Server — Demo Walkthrough Script
## Snowflake CoCo CLI Hackathon 2026

**Author:** Avinash L (avinashreddy508) | **Account:** JSTEYZM-MP60447  
**Presentation:** `citadel/citadel_mcp_demo.html` (12 slides, ← → keyboard nav)  
**Demo time:** ~10 minutes

---

## What We're Demonstrating

CITADEL separates MCP into three concerns, enforced by Snowflake RBAC:

| Concern | Server | Tools | Session role | Side effects |
|---|---|---|---|---|
| **AI Gateway** (read) | `CITADEL_AGENT_MCP_SERVER` | 1 × `CORTEX_AGENT_RUN` | `CITADEL_MCP_READER_ROLE` | none |
| **Action Server** (write) | `CITADEL_ACTIONS_MCP_SERVER` | 3 × `GENERIC` procedure | `CITADEL_COMPLIANCE_OFFICER` | writes 4 tables |
| **Registry** (discovery) | `SHOW`/`DESCRIBE`, RFC 9728 metadata, `tools/list` | — | none for metadata | none |

A client holding only the reader credential **cannot** file a SAR or freeze an account.

> Complete reference — auth, grants, transport, troubleshooting:
> **[`MCP_REFERENCE.md`](MCP_REFERENCE.md)**

---

## Before You Start — Prerequisites

### 1. Authenticate (one browser click)

**Snowflake OAuth has no machine-to-machine flow.** `client_credentials` returns
`400 invalid_grant` and `jwt-bearer` returns `400 unsupported_grant_type` — verified.
Only `authorization_code` and `refresh_token` work. So you consent once; the cached
refresh token then runs unattended for 90 days.

```powershell
cd citadel
python scripts\test_mcp.py auth action
```

This opens your browser, and because `http://localhost:8585/callback` is registered on
the integration, the code is captured automatically — nothing to copy. You should land
on a page reading **"CITADEL — authorised."**

Authorise **`action`**, not `reader`: `CITADEL_MCP_ACTION_ROLE` is granted *to*
`CITADEL_COMPLIANCE_OFFICER`, so that one token reaches both servers and all four tools.

### 2. Verify the registry (no credentials needed)

```powershell
python scripts\test_mcp.py discover
```

Expect, for each server: `401` on an unauthenticated POST with a `WWW-Authenticate`
challenge, and `200` on the public RFC 9728 metadata document. This is the right first
diagnostic if anything fails later — it isolates transport from authentication.

```sql
USE ROLE ACCOUNTADMIN;
SHOW MCP SERVERS IN SCHEMA CITADEL_DB.RISK;
DESCRIBE MCP SERVER CITADEL_DB.RISK.CITADEL_ACTIONS_MCP_SERVER;  -- full tool spec
```

### 3. Pick fresh write targets

Flag 5445 and account 126 were consumed by the verification run. Get unused ones:

```sql
USE ROLE ACCOUNTADMIN;
SELECT rf.flag_id, rf.account_id, rf.flag_type, ROUND(rf.flag_score,0) AS score
FROM CITADEL_DB.RISK.RISK_FLAGS rf
JOIN CITADEL_DB.RISK.ACCOUNTS a ON a.account_id = rf.account_id
WHERE rf.flag_status NOT IN ('ACTIONED','DISMISSED')
  AND rf.flag_domain='FRAUD' AND rf.severity='CRITICAL'
  AND a.status='ACTIVE'
ORDER BY rf.flag_score DESC LIMIT 5;
```

### 4. Baseline the audit log

```sql
SELECT COUNT(*) FROM CITADEL_DB.RISK.AUDIT_LOG;   -- note this number
```

---

## The One-Command Demo

```powershell
python scripts\test_mcp.py full <flag_id> <account_id>
```

Runs read → write → audit in sequence. Verified output 2026-09-06:

**Part 1 — READ**

```
tools/list                200   1 tool (citadel_agent)
tools/call citadel_agent  200   100,975 bytes
  agent orchestrated 3 tool(s): RegulatoryKnowledgeSearch,
                                RiskSignalAnalytics, system_execute_sql
```

The answer cited 31 CFR §1010.314, 31 USC 5324, the SAR 30-day and CTR 15-day
deadlines, AML-POL-003 approval tiers, and the tipping-off prohibition under
31 USC 5318(g)(2). **Say out loud that nobody wrote that orchestration** — the agent
chose Cortex Search, the semantic view, and SQL execution on its own.

**Part 2 — WRITE**

```
tools/list                200   3 tools
file_sar_draft(5445)      200   filing_id 1004, 2,074-char AI narrative
flag_account(126)         200   status FROZEN, case_id 54 auto-opened
escalate_case(54)         200   status ESCALATED
```

**Part 3 — AUDIT**

```sql
SELECT log_id, action_type, object_type, object_id, actor_role, event_ts
FROM CITADEL_DB.RISK.AUDIT_LOG ORDER BY event_ts DESC LIMIT 6;
```

| log_id | action | object | actor_role |
|---|---|---|---|
| 402 | `FILE_SAR` | FILING 1004 | `CITADEL_COMPLIANCE_OFFICER` |
| 403 | `FLAG_ACCOUNT` | ACCOUNT 126 | `CITADEL_COMPLIANCE_OFFICER` |
| 303 | `ESCALATE_CASE` | CASE 54 | `CITADEL_COMPLIANCE_OFFICER` |

**The strongest governance beat in the whole demo:** older rows in the same table show
`actor_role = ACCOUNTADMIN` — those came from the Streamlit dashboard. One immutable
log, each channel correctly attributed to its real identity. That is BCBS 239
Principle 2 working, not claimed.

> Sort by `event_ts`, never `log_id`. `log_id` is drawn per-procedure, so 303 is
> *newer* than 403. Sorting by `log_id` buries your newest action mid-list.

---

## Optional — Register in CoCo Desktop

Config must live at **`~/.snowflake/cortex/mcp.json`**; a project-level
`.cortex/mcp.json` is *not* read by CoCo. Each entry needs `type: "http"` plus an
`oauth` block with lowercase keys — a Cursor-style `"auth": {"CLIENT_ID": ...}` block
is silently ignored and the server never connects.

Restart CoCo, run `/mcp` to see status and tool counts, then ask in natural language:

> *"Using citadel-actions, file a SAR draft for flag 2159"*

Tools are namespaced `mcp__citadel-actions__file_sar_draft`.

---

## OAuth Credentials

```
Reader  CLIENT_ID     wCHarjp++MpjD1B592fGGL9elH0=
        CLIENT_SECRET /FpSpX92PiM8S5uRt8U66lfXUjVvYZfI/st9i6fduFE=
        role          CITADEL_MCP_READER_ROLE      redirect localhost:8586

Action  CLIENT_ID     +u3yiagG14barHreL7xgM48Yjac=
        CLIENT_SECRET tlMusJkPxomtt0zyCi8zeb9uwYn6r3lTwhM8jakVxRk=
        role          CITADEL_COMPLIANCE_OFFICER   redirect localhost:8585
```

Or: `SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_ACTION_OAUTH');`

---

## If Something Fails On Stage

| Symptom | Cause | Fix |
|---|---|---|
| `401` everywhere | token expired | `python scripts\test_mcp.py auth action` |
| `400 invalid_grant` | code reused or expired | Codes are single-use, expire in minutes |
| `200` + *"agent does not exist or access is not authorized"* | missing `USAGE ON AGENT` | `GRANT USAGE ON AGENT ... TO ROLE CITADEL_MCP_READER_ROLE` |
| `200` + *"CITADEL_COMPLIANCE_OFFICER or higher required"* | session role fails the procedure guard | `ALLOWED_ROLES_LIST = ('CITADEL_COMPLIANCE_OFFICER')` |
| *"Flag not found or already actioned"* | target consumed by an earlier run | Pick a fresh flag (Prerequisite 3) |
| Response parse error | SSE not handled | `Accept: application/json, text/event-stream` |
| CoCo shows no servers | wrong file or schema | `~/.snowflake/cortex/mcp.json` with `type` + `oauth` |
| `REGULATORY_FILINGS` empty | row access policy blocks the reader role | `USE ROLE ACCOUNTADMIN` |

Note that **missing tool grants return `HTTP 200` with an error in the body**, not `401`.
If a tool lists but won't invoke, it is a grant problem, not a transport problem.

**Fallback if OAuth misbehaves live:** the Streamlit dashboard performs the identical
SAR → freeze → escalate chain against the same procedures and the same `AUDIT_LOG`.
Same governance story, no MCP dependency.

---


### 3. Verify OAuth integrations

```sql
SELECT PARSE_JSON(SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_READER_OAUTH')):OAUTH_CLIENT_ID::STRING AS reader_id;
SELECT PARSE_JSON(SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_ACTION_OAUTH')):OAUTH_CLIENT_ID::STRING AS action_id;
```

### 4. Open the presentation

```
citadel/citadel_mcp_demo.html  — open in browser, use ← → keys
```

---

## MCP Server URLs

| Server | URL |
|---|---|
| AI Gateway | `https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_AGENT_MCP_SERVER` |
| Actions | `https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_ACTIONS_MCP_SERVER` |

---

## Demo Sequence A — CoCo Desktop (recommended)

### Step 1: Open CoCo Desktop in the citadel workspace

The `.cortex/mcp.json` file is already in place at `citadel/.cortex/mcp.json`. CoCo will auto-discover both MCP servers when the workspace is opened.

**What to say:**
> "CoCo Desktop automatically discovered our CITADEL MCP tools from the workspace configuration. You can see them in the tools panel — four tools from two servers, each secured with different OAuth credentials."

---

### Step 2: Verify tool discovery

In the CoCo chat panel, ask:

```
What MCP tools are available?
```

**Expected response:**
> CoCo lists the tools it found:
> - `run_citadel_agent` (from citadel-ai server)
> - `file_sar_draft` (from citadel-actions server)
> - `flag_account` (from citadel-actions server)  
> - `escalate_case` (from citadel-actions server)

**Talking point:**
> "Two separate servers — one for reading (analytics + regulatory Q&A), one for writing (SAR filing, account freezing, case escalation). A read-only analyst gets a different OAuth token than a compliance officer. The same Snowflake RBAC that controls direct table access also controls MCP tool access."

---

### Step 3: AI Gateway — Risk query

In CoCo chat:

```
What fraud risk patterns does Citadel see this week? Include which regulation applies to each.
```

**What happens:**
1. CoCo calls `run_citadel_agent` with the question
2. OAuth reader token is sent to `CITADEL_AGENT_MCP_SERVER`
3. Snowflake validates the token and calls `CITADEL_AGENT`
4. CITADEL_AGENT runs `RiskSignalAnalytics` (Cortex Analyst SQL) + `RegulatoryKnowledgeSearch` (Cortex Search RAG)
5. Response streams back through MCP → CoCo

**Expected response includes:**
- Top accounts with fraud flags
- Specific flag types (CROSS_BORDER, STRUCTURING, VELOCITY)
- Exact regulation per pattern (FATF R.19, 31 CFR §1010.314, FinCEN SAR Field 35)

**Talking point:**
> "This isn't just a chatbot forwarding a question. The MCP call invoked the full CITADEL_AGENT — which ran two tools under the hood: a SQL query against the semantic view for live data, and a vector search across 10 regulatory PDFs for the compliance context. Every answer is grounded in live Snowflake data."

---

### Step 4: AI Gateway — LCR query

```
What is our current LCR status and what does Basel III require if it breaches?
```

**Expected response:**
- Current LCR percentage (87.4% — breach)
- Basel III Article 412 citation
- 2-business-day supervisory notification requirement

---

### Step 5: Action Tool — File a SAR

```
File a SAR for flag 6036. It's a confirmed cross-border wire to Iran with no business justification.
```

**What happens:**
1. CoCo calls `file_sar_draft` (from `citadel-actions` server)
2. OAuth **action** token used — different credential scope than the reader token
3. `FILE_SAR_DRAFT` stored proc executes:
   - Role check: `CURRENT_ROLE() IN ('CITADEL_COMPLIANCE_OFFICER', ...)`
   - `SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-6', ...)` generates FinCEN SAR narrative
   - Inserts into `REGULATORY_FILINGS`
   - Updates `RISK_FLAGS` status to ACTIONED
   - Inserts immutable entry into `AUDIT_LOG`
4. Result returned to CoCo

**Verify in Snowflake:**
```sql
USE ROLE ACCOUNTADMIN;
SELECT filing_id, filing_type, LEFT(narrative,300) AS narrative_preview
FROM CITADEL_DB.RISK.REGULATORY_FILINGS ORDER BY filing_id DESC LIMIT 1;
```

**Talking point:**
> "The AI just called a Snowflake stored procedure via MCP and it generated a complete FinCEN SAR narrative using claude-sonnet-4-6 running *inside* Snowflake. Notice the citations: FinCEN SAR Field 35(a), 31 CFR §1020.320, FATF FIN-2023-A001. That's not a templated string — it's CORTEX.COMPLETE running inside the stored proc."

---

### Step 6: Action Tool — Freeze account

```
Freeze account 226. Reason: FATF black-list wire transfer confirmed, SAR filed.
```

**What happens:**
1. CoCo calls `flag_account`(p_account_id=226, p_reason=..., p_linked_flag_id=6036)
2. `FLAG_ACCOUNT` proc: validates role, checks account exists, checks not already FROZEN
3. `UPDATE ACCOUNTS SET status='FROZEN'`
4. Creates CASE_ESCALATIONS entry
5. Writes AUDIT_LOG

**Verify:**
```sql
USE ROLE ACCOUNTADMIN;
SELECT account_id, status FROM CITADEL_DB.RISK.ACCOUNTS WHERE account_id = 226;
-- Expected: FROZEN
```

---

### Step 7: Action Tool — Escalate case

```
Escalate the case for account 226 to compliance.officer@citadel.bank
```

```sql
-- Get the case ID first
SELECT case_id FROM CITADEL_DB.RISK.CASE_ESCALATIONS 
WHERE account_id = 226 AND status NOT IN ('RESOLVED','CLOSED') 
ORDER BY created_at DESC LIMIT 1;
```

In CoCo:
```
Escalate case <case_id> to compliance.officer@citadel.bank — FATF black-list wire, law enforcement referral under 31 USC 5318(g)
```

---

### Step 8: Verify the complete audit trail

```sql
USE ROLE ACCOUNTADMIN;
SELECT action_type, object_type, object_id, change_summary, event_ts::VARCHAR AS ts
FROM CITADEL_DB.RISK.AUDIT_LOG
ORDER BY log_id DESC LIMIT 5;
```

**What to show:**
- The three actions (FILE_SAR, FLAG_ACCOUNT, ESCALATE_CASE) all appear in sequence
- Each has actor, role, timestamp, before/after state
- The table has no DELETE/UPDATE grants — immutable by design

**Talking point:**
> "Every action taken via MCP — whether from CoCo Desktop, the Streamlit app, or a direct CALL — lands in this immutable audit log. BCBS 239 Principle 2 requires exactly this: full data lineage from signal to regulatory filing to account action. The MCP layer adds nothing to the security perimeter — it just routes through Snowflake's existing controls."

---

## Demo Sequence B — Python REST API

If CoCo Desktop is not available, use the Python scripts directly.

### Test AI gateway via Python

```bash
python citadel/scripts/chat.py --connection Sept-6_AHap
```

At the `>` prompt:
```
What accounts have structuring fraud patterns? Include the regulatory basis.
What is the LCR status today?
Which customers are PEPs with open fraud flags?
```

### Test action tools directly (Snowflake SQL)

```sql
-- As ACCOUNTADMIN (or CITADEL_COMPLIANCE_OFFICER)
USE ROLE ACCOUNTADMIN;

-- File a SAR
CALL CITADEL_DB.RISK.FILE_SAR_DRAFT(6088, 'Cross-border wire to FATF grey-list — demo call');

-- Check the result
SELECT filing_id, LEFT(narrative,400) AS sar FROM CITADEL_DB.RISK.REGULATORY_FILINGS ORDER BY filing_id DESC LIMIT 1;

-- Freeze account
CALL CITADEL_DB.RISK.FLAG_ACCOUNT(526, 'SAR filed — FATF jurisdiction confirmed', 6088);

-- Verify
SELECT account_id, status FROM CITADEL_DB.RISK.ACCOUNTS WHERE account_id = 526;

-- Escalate
SELECT case_id FROM CITADEL_DB.RISK.CASE_ESCALATIONS WHERE account_id = 526 ORDER BY created_at DESC LIMIT 1;
-- Then: CALL CITADEL_DB.RISK.ESCALATE_CASE(<case_id>, 'compliance.officer@citadel.bank', 'Escalated via demo');

-- Full audit trail
SELECT action_type, object_id, change_summary, LEFT(event_ts::VARCHAR,16) AS ts
FROM CITADEL_DB.RISK.AUDIT_LOG ORDER BY log_id DESC LIMIT 5;
```

---

## Architecture Talking Points (per slide)

| Slide | Key message |
|---|---|
| 1 — Title | "Two servers, four tools, zero new infrastructure — 100% Snowflake-native" |
| 2 — Why MCP | "Banking AI needs tool calls, not just answers. MCP enables governed action." |
| 3 — Architecture | "Read and write are separated at the OAuth layer — not just at the UI" |
| 4 — Two Servers | "CORTEX_AGENT_RUN wraps the whole intelligence platform in one tool call" |
| 5 — OAuth | "Client credentials flow — short-lived JWTs, role-scoped, no long-lived secrets" |
| 6 — DDL | "Three lines of JSON per tool — no code, no deployment, no custom server" |
| 7 — CoCo Config | "One JSON file in the workspace — CoCo discovers all 4 tools automatically" |
| 8 — AI Demo | "NL → SQL + RAG → cited response — all via a single MCP tool call" |
| 9 — Action Demo | "SAR + Freeze in 2 tool calls. Both persisted with immutable audit entries." |
| 10 — Request Flow | "The sequence diagram shows exactly what happens — no magic, fully traceable" |
| 11 — Security | "5 independent security layers — RBAC, OAuth, in-proc role check, masking, audit" |
| 12 — Summary | "The MCP layer adds zero attack surface — it routes through Snowflake's own controls" |

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| MCP tool call returns 401 | Check env vars: `echo $CITADEL_READER_CLIENT_ID`. Re-export if empty. |
| `run_citadel_agent` returns empty | Check `SHOW CORTEX SEARCH SERVICES IN SCHEMA CITADEL_DB.RISK` — CITADEL_SEARCH_SVC must be ACTIVE |
| `file_sar_draft` returns role error | Session role is wrong. The action server requires `CITADEL_MCP_ACTION_ROLE`. Check OAuth integration `ENABLED_ROLES`. |
| CoCo doesn't show CITADEL tools | Check `.cortex/mcp.json` exists in the citadel workspace directory. Restart CoCo. |
| `flag_account` returns "No account linked" | The flag is a CREDIT or LIQUIDITY flag — no bank account attached. Use a FRAUD-domain flag. |
| OAuth token expired mid-demo | CoCo auto-refreshes. If it doesn't, close and re-open the workspace. |

---

## OAuth Credential Reference

> **Keep these secure — do not commit to git.**

| Integration | Client ID | Secret |
|---|---|---|
| `CITADEL_MCP_READER_OAUTH` | `wCHarjp++MpjD1B592fGGL9elH0=` | `/FpSpX92PiM8S5uRt8U66lfXUjVvYZfI/st9i6fduFE=` |
| `CITADEL_MCP_ACTION_OAUTH` | `+u3yiagG14barHreL7xgM48Yjac=` | `tlMusJkPxomtt0zyCi8zeb9uwYn6r3lTwhM8jakVxRk=` |

Retrieve fresh credentials at any time:
```sql
USE ROLE ACCOUNTADMIN;
SELECT PARSE_JSON(SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_READER_OAUTH')) AS reader_creds;
SELECT PARSE_JSON(SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_ACTION_OAUTH')) AS action_creds;
```

---

## Key Snowflake Features Highlighted

| Feature | Role in MCP demo |
|---|---|
| `CREATE MCP SERVER` | Wraps any proc or agent as a governed MCP tool — no custom server |
| OAuth Security Integration | `CLIENT_CREDENTIALS` flow — short-lived token per tool call |
| `EXECUTE AS CALLER` | Procs run with the caller's OAuth role — RBAC enforced end-to-end |
| `SNOWFLAKE.CORTEX.COMPLETE` | Runs inside `FILE_SAR_DRAFT` — AI narrative generated in-database |
| AUDIT_LOG (INSERT-only) | Every MCP action leaves an immutable trail — BCBS 239 P.2 compliance |
| Column Masking Policies | PII masked even inside the MCP-triggered agent response |
| Cortex Extension Registry | `CITADEL_RISK_COPILOT` published to PUBLIC — install in CoCo from catalog |

---

*CITADEL MCP Demo · Built with Snowflake Cortex Code (CoCo) Desktop · Hackathon 2026*

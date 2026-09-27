# CITADEL — Demo Script & Narration Guide
## Snowflake CoCo CLI Hackathon 2026

**Author:** Avinash L (avinashreddy508) | **Account:** JSTEYZM-MP60447  
**App version:** v3 Production UI | **Total Demo Time:** ~15 min (condensed), ~25 min (full)

---

## Before You Start — Prerequisites

```bash
# 1. Verify all Snowflake objects are healthy
python citadel/scripts/verify.py --connection Sept-6_AHap

# 2. Open Snowsight: CITADEL_APP (Streamlit)
# Snowsight → Projects → Streamlit → CITADEL_APP (CITADEL_DB.RISK)

# 3. Open this presentation in a browser
# citadel/citadel_demo.html  (keyboard navigation: ← →)

# 4. Set environment variables (for MCP demo)
export CITADEL_READER_CLIENT_ID=wCHarjp++MpjD1B592fGGL9elH0=
export CITADEL_READER_CLIENT_SECRET=/FpSpX92PiM8S5uRt8U66lfXUjVvYZfI/st9i6fduFE=
```

> **IMPORTANT:** All Snowflake SQL queries run with `USE ROLE ACCOUNTADMIN` first.
> The session may default to `CITADEL_MCP_READER_ROLE` which has a Row Access Policy
> restriction on REGULATORY_FILINGS. Always prefix queries with `USE ROLE ACCOUNTADMIN;`

---

## App v3 — What You'll See

The CITADEL_APP now uses a **dark financial terminal UI**:

| Element | v3 Look |
|---|---|
| Background | Deep navy `#0B1622` — no Streamlit default grey |
| Header | Gradient banner with animated green "LIVE" dot + status pills |
| Tabs | Minimal border-bottom style, primary blue on active |
| KPI cards | 3px accent stripe, large `tabular-nums` value, contextual badge (BREACH/OK) |
| Flags table | Custom HTML — domain/severity badges, score color-coded red/amber/grey |
| Chat bubbles | User: teal gradient right-aligned · Agent: dark card left-aligned with timestamps |
| Audit trail | Timeline rows with colored icon tiles (📄 red / 🔒 amber / ⬆️ purple) |

---

## CITADEL at a Glance

| Layer | Object | Purpose |
|---|---|---|
| Data | 8 tables · 52K rows | Synthetic banking data (fraud, credit, liquidity) |
| Intelligence | `CITADEL_RISK_INTELLIGENCE` | Cortex Analyst semantic view (18+ metrics) |
| Search | `CITADEL_SEARCH_SVC` | 10 regulatory policy docs indexed |
| Agent | `CITADEL_AGENT` | claude-sonnet-4-6 with 2 tools |
| App | `CITADEL_APP` | Streamlit 3-tab app |
| Actions | 3 stored procs | SAR, Freeze, Escalate |
| MCP | 2 MCP servers | AI gateway + action tools |
| Monitoring | `RISK_FLAGS_REFRESH` Task | Every 15 minutes |

---

## Slide Presentation Flow

Open `citadel/citadel_demo.html` in a browser. Use ← → arrow keys.

| Slide | Key talking point |
|---|---|
| 1 — Title | "100% Snowflake-native — no external APIs" |
| 2 — Problem | "$6.6B in AML fines; 4-8 hours per SAR; BCBS 239 gap" |
| 3 — Architecture | "6 phases in one deployment script" |
| 4 — Data Foundation | "52K rows, 5-role RBAC, PII masking, evidence_payload VARIANT" |
| 5 — Intelligence | "18 metrics, all named after the regulation they enforce" |
| 6 — CITADEL Agent | "2 tools: Analyst SQL + Regulatory RAG, MCP action tools" |
| 7 — Pipeline | "The live chain: signal → SAR → freeze → escalate → audit" |
| 8 — Streamlit App | "3 tabs: Chat, Dashboard (with action buttons), Audit Trail" |
| 9 — MCP + CoCo | "Use CITADEL from CoCo Desktop as a native MCP connector" |
| 10 — Regulations | "Basel III, FATF, FinCEN, RBI — all cited in every response" |
| 11 — Feature Matrix | "15+ hackathon features: core + stretch + last-mile" |
| 12 — Live Demo | Transition to live walkthrough |

---

## Demo Sequence A — Streamlit App (recommended for judging)

### Step 1: Open CITADEL_APP

```
Snowsight → Projects → Streamlit → CITADEL_APP
```

**Talking point:** "This is CITADEL — a Risk, Fraud and Regulatory Intelligence Copilot.
Three tabs: Chat with the agent, a live risk dashboard, and an immutable audit trail.
All data is live from Snowflake — no mocks, no static files."

---

### Step 2: Dashboard Tab — Live KPI Cards

Click the **📊 Risk Dashboard** tab.

**What to show:**
- **9,315 open fraud flags** — red accent stripe, critical count in sub-text
- **LCR 87.4% — BREACH badge** — red value, amber "⚠ BREACH" pill below the number
- **75 credit watch-list** — $161M RWA, amber accent stripe
- **Open Cases** — SLA breach count in red badge

**Talking point:** "Every number here is live from the RISK_FLAGS, LIQUIDITY_POSITIONS,
and CREDIT_EXPOSURES tables. This refreshes every 5 minutes via the Cortex Analyst
semantic view CITADEL_RISK_INTELLIGENCE."

---

### Step 3: Quick Action — File SAR with AI Narrative

In the Dashboard tab, scroll to **"⚡ Quick Actions — Top Critical Flags"**.

Click **📄 File SAR** on the first CRITICAL flag.

**What happens in 3-5 seconds:**
1. `FILE_SAR_DRAFT` stored proc called
2. `SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-6', ...)` invoked inside the proc
3. AI generates a FinCEN-format SAR narrative with regulatory citations
4. `REGULATORY_FILINGS` table updated, `RISK_FLAGS` status → ACTIONED
5. `AUDIT_LOG` records the action

**Talking point:** "The AI just wrote a complete SAR narrative citing FinCEN SAR Field 35(a),
31 CFR §1020.320, and the FinCEN FIN-2023-A001 advisory — in under 5 seconds.
That used to take a compliance officer 4-8 hours."

---

### Step 4: Audit Trail Tab

Click **📋 Audit Trail**.

**What to show (v3 timeline view):**
- Summary KPI row at top: Total actions · SARs · Frozen · Escalated (colored KPI tiles)
- Timeline rows with colored icon tiles — the SAR you just filed appears at the top with a 📄 red icon
- Actor name + role displayed on each row
- Click "📥 Export Audit Log CSV"

**Talking point:** "Every action — SAR filing, account freeze, case escalation — is
recorded in AUDIT_LOG with the actor, role, timestamp, and before/after state.
No role has DELETE privileges on this table. This is the BCBS 239 Principle 2
immutable audit trail that regulators require."

---

### Step 5: Chat Tab — Natural Language Q&A

Click **💬 Chat with CITADEL**. There are **two independent chat panels**, each with its
own input, Send button, and separate conversation history:
- **Left** — scoped to fraud/LCR/credit/SAR/regulatory questions, 8 quick-question shortcuts
- **Right** — open-ended ("Ask Citadel a question"), its own quick-question shortcuts

Ask (left panel): `Which accounts show fraud-risk patterns this week?`

**Expected response includes:**
- Top accounts by fraud score
- Flag type per account (CROSS_BORDER, STRUCTURING, VELOCITY)
- Specific regulation cited per pattern (FATF R.19, 31 CFR §1010.314, FinCEN SAR Field 35)
- Recommended action

**Follow-up (right panel):** `What is the LCR status and what does Basel III require if it breaches?`

**Talking point:** "Each panel calls `SNOWFLAKE.CORTEX.COMPLETE` (claude-sonnet-4-6) directly,
grounded in live SQL context built fresh on every question — open risk flags, the 30-day LCR
trend, the credit watch-list by sector, audit actions broken down by actor role, and excerpts
from 10 regulatory policy documents. It doesn't just query data — it cites the exact regulation
that applies to each finding, and both panels keep separate histories so a regulatory
deep-dive doesn't get mixed into a general conversation."

---

### Step 6: AI Executive Board Report

In the Dashboard tab, expand **"🤖 Generate AI Executive Risk Summary"**.

Click **Generate Board Report**.

**Talking point:** "One click gives the Chief Risk Officer a board-ready 3-paragraph
risk summary citing Basel III, FATF, and FinCEN — ready to download and present.
This uses `SNOWFLAKE.CORTEX.COMPLETE` inline in a SQL query."

---

## Demo Sequence B — Python Scripts

### Terminal Chat (streaming)

```bash
python citadel/scripts/chat.py --connection Sept-6_AHap
```

Enter questions at the `>` prompt:
- `What accounts have structuring patterns? Are any customers PEPs?`
- `Show me the credit watch-list by sector with RWA and Expected Loss.`
- `What is the LCR trend and what does Basel III require on a breach?`

### Batch Demo (8 pre-built questions)

```bash
python citadel/scripts/demo.py --connection Sept-6_AHap
```

Results saved to `citadel/demo_results.json` — show the JSON output.

---

## Demo Sequence C — Direct SQL Chain (most technical)

Run these in Snowsight or a SQL worksheet with `USE ROLE ACCOUNTADMIN`:

```sql
-- STEP 1: Find top CRITICAL flags (show live signal queue)
SELECT flag_id, flag_type, severity, account_id, ROUND(flag_score,1) AS score,
       LEFT(threshold_rationale, 80) AS reg_basis
FROM CITADEL_DB.RISK.RISK_FLAGS
WHERE severity = 'CRITICAL' AND flag_status NOT IN ('ACTIONED','DISMISSED')
ORDER BY score DESC LIMIT 5;

-- STEP 2: File SAR with AI narrative (watch CORTEX.COMPLETE run inside proc)
CALL CITADEL_DB.RISK.FILE_SAR_DRAFT(2159, 'FATF black-list wire confirmed by EDD review');

-- STEP 3: Show the AI-generated FinCEN SAR narrative
SELECT filing_id, LEFT(narrative, 800) AS sar_narrative
FROM CITADEL_DB.RISK.REGULATORY_FILINGS ORDER BY filing_id DESC LIMIT 1;

-- STEP 4: Freeze the account
CALL CITADEL_DB.RISK.FLAG_ACCOUNT(226, 'SAR filed — FATF jurisdiction confirmed', 2159);

-- STEP 5: Check account is frozen
SELECT account_id, status, account_holder_name FROM CITADEL_DB.RISK.ACCOUNTS WHERE account_id = 226;

-- STEP 6: Escalate the open case
SELECT case_id FROM CITADEL_DB.RISK.CASE_ESCALATIONS 
WHERE account_id = 226 AND status NOT IN ('RESOLVED','CLOSED') LIMIT 1;
-- Use the returned case_id:
CALL CITADEL_DB.RISK.ESCALATE_CASE(<case_id>, 'compliance.officer@citadel.bank', 
  'FATF jurisdiction wire — law enforcement referral per 31 USC 5318(g)');

-- STEP 7: Verify complete chain in one query
SELECT '1_SIGNAL'  AS step, 'CROSS_BORDER flag #2159, score 95' AS detail
UNION ALL SELECT '2_SAR', 
  (SELECT 'Filing #' || MAX(filing_id)::VARCHAR || ' — DRAFT' FROM CITADEL_DB.RISK.REGULATORY_FILINGS)
UNION ALL SELECT '3_FREEZE',
  (SELECT 'Account 226 status: ' || status FROM CITADEL_DB.RISK.ACCOUNTS WHERE account_id=226)
UNION ALL SELECT '4_CASE', 
  (SELECT 'Case ' || case_id::VARCHAR || ' → ' || status 
   FROM CITADEL_DB.RISK.CASE_ESCALATIONS WHERE account_id=226 ORDER BY created_at DESC LIMIT 1)
UNION ALL SELECT '5_AUDIT',
  (SELECT COUNT(*)::VARCHAR || ' total audit entries; last action: ' || 
   MAX(action_type) OVER () FROM CITADEL_DB.RISK.AUDIT_LOG ORDER BY log_id DESC LIMIT 1)
ORDER BY step;
```

---

## Key Snowflake Features to Highlight

| Feature | Where Used | Talking Point |
|---|---|---|
| `SNOWFLAKE.CORTEX.COMPLETE` | FILE_SAR_DRAFT proc + AI Board Report | AI inside stored procs — no external API call |
| Cortex Analyst | CITADEL_AGENT tool 1 | NL→SQL over 18 risk metrics |
| Cortex Search | CITADEL_AGENT tool 2 | RAG over 10 regulatory PDFs |
| Cortex Agent | CITADEL_AGENT | Orchestrates both tools with regulation-aware reasoning |
| Snowflake Tasks | RISK_FLAGS_REFRESH | Real-time 15-min flag detection — zero additional infrastructure |
| Dynamic Data Masking | 3 columns (PII) | RISK_ANALYST can't see national_id or account_number |
| Row Access Policy | REGULATORY_FILINGS | Compliance officers see all; analysts see their own |
| VARIANT evidence_payload | RISK_FLAGS | Immutable JSON snapshot per flag — BCBS 239 P.2 |
| MCP Servers | 2 servers | CITADEL accessible from any MCP-compatible client |
| Cortex Extension | CITADEL_RISK_COPILOT | Published to account catalog — install with one click in CoCo |
| Streamlit-in-Snowflake | CITADEL_APP | No deployment infra — runs on warehouse compute |

---

## Regulatory Cheat Sheet (for Q&A)

| Pattern | Regulation | Threshold | CITADEL Action |
|---|---|---|---|
| STRUCTURING | 31 CFR §1010.314 + PMLA Schedule Rule 3(B) | Cash deposits $9,800–$9,999 (evading $10,000 CTR) | FILE_SAR_DRAFT |
| CROSS_BORDER | FATF Recommendation 19 + RBI KYC §38 | Wire to grey/black-list jurisdiction | FILE_SAR_DRAFT + FLAG_ACCOUNT |
| VELOCITY | FinCEN SAR Field 35(a) | 5+ txns on same account within 60 minutes | FILE_SAR_DRAFT |
| ROUND_NUMBER | FATF TBML Typology 2020 | Round-dollar >$10,000 wire | FILE_SAR_DRAFT |
| LCR < 100% | Basel III Art. 412 (CRR) | LCR ratio below 100% | Dashboard alert + notify supervisor within 2 days |
| PD > 15% | Basel III ICAAP + BCBS 239 | PD score above 0.15 | Credit watch-list flag |
| NPA | RBI IRAC 2023 | 90+ days past due | Credit watch-list + ESCALATE_CASE |

---

## If the Demo Breaks

| Symptom | Fix |
|---|---|
| REGULATORY_FILINGS shows 0 rows | Run `USE ROLE ACCOUNTADMIN;` first — RAP blocks CITADEL_MCP_READER_ROLE (default session role) |
| FILE_SAR_DRAFT returns `{"error":"Flag not found..."}` | Flag already actioned. Use: `SELECT flag_id FROM RISK_FLAGS WHERE flag_status NOT IN ('ACTIONED','DISMISSED') AND severity='CRITICAL' LIMIT 1` |
| Streamlit `AttributeError: chat_input` | Fixed in v3: st.form used instead. Reload the app. |
| Streamlit app shows "Auth error" | Session token expired. Click the app URL in Snowsight to refresh. |
| CITADEL_AGENT returns empty response | Check `SHOW CORTEX SEARCH SERVICES` — ensure CITADEL_SEARCH_SVC is ACTIVE |
| CORTEX.COMPLETE returns NULL in proc | Cortex quota; wait 30s and retry. Fallback narrative auto-triggers. |
| MCP server 401 | Check OAuth client ID/secret env vars are set correctly. |

---

## One-Liner Demo Commands

```bash
# Health check
python citadel/scripts/verify.py --connection Sept-6_AHap

# Interactive chat
python citadel/scripts/chat.py --connection Sept-6_AHap

# Batch demo (8 questions)
python citadel/scripts/demo.py --connection Sept-6_AHap

# Check RISK_FLAGS_REFRESH task status
# (run in Snowsight as ACCOUNTADMIN)
SHOW TASKS LIKE 'RISK_FLAGS_REFRESH' IN SCHEMA CITADEL_DB.RISK;

# See last 5 audit entries
# USE ROLE ACCOUNTADMIN;
# SELECT * FROM CITADEL_DB.RISK.AUDIT_LOG ORDER BY log_id DESC LIMIT 5;
```

---

## Files Reference

| File | Purpose |
|---|---|
| `citadel/citadel_demo.html` | Interactive 13-slide dark-theme deck (keyboard nav ← →, Chart.js charts) |
| `citadel/CITADEL_DEMO_PRESENTATION.html` | Full-screen 10-slide animated deck |
| `citadel/DEMO_SCRIPT.md` | This file |
| `citadel/deploy.sql` | Full idempotent deployment (~1,610 lines) |
| `citadel/app/streamlit_app.py` | Streamlit v3 production-grade app |
| `citadel/citadel_semantic_model.yaml` | Cortex Analyst semantic view (1,265 lines) |
| `citadel/scripts/chat.py` | Interactive terminal chat |
| `citadel/scripts/demo.py` | Batch demo (8 questions → JSON results) |
| `citadel/scripts/verify.py` | Deployment health check |
| `citadel/README.md` | Full project documentation |
| `citadel/SKILL.md` | CoCo plugin SKILL.md |

---

*CITADEL — Built entirely with Cortex Code (CoCo) Desktop for the Snowflake CoCo CLI Hackathon 2026*

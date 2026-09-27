# CITADEL — Judging Criteria Test Prompts

All prompts below are **grounded in actual CITADEL_DB.RISK data**. Each includes the
expected answer and verification SQL so you can prove the AI response is correct on stage.

**Data facts as of this build:**

| Fact | Value |
|---|---|
| Open fraud flags | 8,967 (VELOCITY 7,578 · STRUCTURING 845 · ROUND_NUMBER 273 · CROSS_BORDER 271) |
| Open credit flags | 113 (HIGH_PD_SEVERE 42 CRITICAL · HIGH_UTILISATION 41 · HIGH_PD 30) |
| Open liquidity flags | 231 (LCR_BREACH 110 · NSFR_BREACH 84 · DUAL_BREACH 37) |
| Structuring txns | 846 — **100% fall in the $9,800–$9,999 CTR evasion band**, 16 accounts |
| High-risk countries | LBY 333 txns ($6.81M) · IRN 333 txns ($3.29M) |
| PEP customers w/ fraud flags | **10 customers, 155 flags, all rated `LOW`** ← governance failure |
| Credit watch-list sectors | REAL_ESTATE 37 facilities $82.7M RWA · AGRICULTURE 38 facilities $78.3M RWA |
| LCR breach days (of 90) | 0_7D: 22 · 8_30D: 24 · 31_90D: 24 · 91_365D: 21 · OVER_1YR: 56 |
| Policy docs for RAG | 10 (Basel III LCR/NSFR, FinCEN CTR, FATF R.12/16/19, RBI IRAC, BCBS 239, +4) |

---

## ⭐ THE THREE KILLER DEMO PROMPTS

These three prove all judging criteria simultaneously. Use these if you only have 5 minutes.

### 🥇 KILLER #1 — Cross-layer: policy document + structured data agree

> **"Our Q2 2026 internal audit flagged concentration risk in the real estate sector. Does our current credit watch-list confirm that audit finding? Quantify the exposure and tell me what the audit recommended."**

**Why this wins:** Forces CITADEL to read *unstructured* `POLICY_DOCS` (doc #7, "Audit Finding —
Concentration Risk in Real Estate Sector Q2 2026") **and** query *structured* `CREDIT_EXPOSURES`
in a single answer — then confirm they agree. This is the exact "combine transaction and account
data with policy and filing text" requirement.

**Expected answer contains:** REAL_ESTATE is the **largest** watch-list sector by RWA
(**$82.7M across 37 facilities**), average PD **0.414**, Expected Loss **$19.95M**, average
utilisation **61.2%** — confirming the Q2 audit finding.

```sql
-- VERIFY
SELECT sector, COUNT(*) facilities, ROUND(SUM(rwa)/1e6,1) rwa_m,
       ROUND(AVG(pd_score),3) avg_pd, ROUND(SUM(expected_loss)/1e6,2) el_m,
       ROUND(AVG(utilisation_pct),1) avg_util
FROM CITADEL_DB.RISK.CREDIT_EXPOSURES WHERE watch_list_flag=TRUE
GROUP BY 1 ORDER BY rwa_m DESC;
-- Then show the source policy doc it read:
SELECT title, content FROM CITADEL_DB.RISK.POLICY_DOCS WHERE doc_id=7;
```

---

### 🥈 KILLER #2 — Governance failure the AI catches on its own

> **"We have politically exposed persons with open fraud flags. What internal risk rating are those customers assigned, and does that assignment comply with FATF Recommendation 12?"**

**Why this wins:** Your data contains a **real compliance contradiction** — 10 PEP customers
carry 155 open fraud flags but are all rated `LOW`. FATF R.12 mandates enhanced due diligence
and a high-risk classification for PEPs. CITADEL should flag this as a control failure, not
just report numbers. This is judgment, not retrieval.

**Expected answer contains:** 10 PEP customers · 155 open fraud flags · all rated `LOW` ·
**non-compliant with FATF R.12** · recommend immediate reclassification to HIGH + EDD review.

```sql
-- VERIFY
SELECT c.pep_flag, c.risk_rating, COUNT(DISTINCT rf.flag_id) flags,
       COUNT(DISTINCT c.customer_id) customers
FROM CITADEL_DB.RISK.RISK_FLAGS rf
JOIN CITADEL_DB.RISK.CUSTOMERS c ON c.customer_id=rf.customer_id
WHERE rf.flag_status NOT IN ('ACTIONED','DISMISSED') AND rf.flag_domain='FRAUD'
GROUP BY 1,2 ORDER BY flags DESC;
-- Expect: PEP=TRUE / risk_rating=LOW / 155 flags / 10 customers
```

---

### 🥉 KILLER #3 — Statistical proof of intent

> **"Show me the evidence for structuring. What percentage of those transactions fall inside the CTR evasion band, how many accounts are involved, and what is our filing obligation and deadline?"**

**Why this wins:** **All 846** structuring transactions sit between $9,800 and $9,999 — a
statistically impossible distribution that proves *deliberate* threshold evasion rather than
coincidence. CITADEL should cite FinCEN 31 CFR §1010.314 (structuring) and §1020.320
(30-day SAR deadline).

**Expected answer contains:** 846 txns · min $9,800 / max $9,999 / avg $9,903 · **100% in
evasion band** · 16 accounts · CTR threshold $10,000 · SAR due within **30 days**.

```sql
-- VERIFY
SELECT COUNT(*) structuring_txns, MIN(amount) min_amt, MAX(amount) max_amt,
       ROUND(AVG(amount),0) avg_amt,
       COUNT(CASE WHEN amount BETWEEN 9800 AND 9999 THEN 1 END) in_evasion_band,
       COUNT(DISTINCT account_id) accounts
FROM CITADEL_DB.RISK.TRANSACTIONS WHERE fraud_pattern='STRUCTURING';
-- Expect: 846 / 9800 / 9999 / 9903 / 846 / 16
```

---

## 1️⃣ REAL WORLD RELEVANCE

*Questions an actual MLRO, CRO, or compliance analyst asks on a Monday morning.*

| # | Prompt | Proves |
|---|---|---|
| R1 | "Which accounts have open fraud flags this week? Rank by risk score and give me the regulatory basis for each." | Daily analyst triage workflow |
| R2 | "I need to brief the board tomorrow. Give me the top three risk themes across fraud, credit and liquidity with quantified exposure." | Executive reporting |
| R3 | "A regulator has asked for evidence of our AML monitoring. What can I show them?" | Regulatory examination readiness |
| R4 | "Which of my open flags have a hard filing deadline, and when does the clock run out?" | SAR/CTR deadline management |
| R5 | "We are being audited on liquidity. How many days did we breach LCR in the last 90 and what was our worst tenor bucket?" | Basel III supervisory reporting |

**R5 expected answer:** `OVER_1YR` is the worst bucket at **56 breach days of 90**; `0_7D` had
**22**; minimum LCR observed **32.5%** against the Basel III Art.412 minimum of **100%**.

```sql
-- VERIFY R5
SELECT tenor_bucket, ROUND(MIN(lcr_ratio)*100,1) min_pct,
       COUNT(CASE WHEN lcr_breach THEN 1 END) breach_days, COUNT(*) total_days
FROM CITADEL_DB.RISK.LIQUIDITY_POSITIONS WHERE stress_scenario='BASE'
GROUP BY 1 ORDER BY breach_days DESC;
```

---

## 2️⃣ TECHNICAL EXECUTION

*Prompts that only work if the multi-table joins, RAG over policy text, and Cortex reasoning
all function correctly.*

| # | Prompt | Technical capability proven |
|---|---|---|
| T1 | "Which high-risk countries are we transacting with, what fraud pattern do those transactions show, and which FATF recommendation applies?" | `TRANSACTIONS` join + FATF policy doc RAG |
| T2 | "Compare our real estate and agriculture watch-list exposure. Which is riskier by expected loss rather than RWA, and why do those two metrics disagree?" | Numeric reasoning + metric nuance |
| T3 | "What is the difference between an STR and a SAR, and which one applies to my open cross-border flags?" | Pure RAG (policy doc #9) + applies it to live data |
| T4 | "Explain the difference between LCR and NSFR, then tell me which one we are breaching more often." | Two policy docs + aggregate query |
| T5 | "For flag type HIGH_PD_SEVERE, what threshold triggered it, what is the Basel III requirement, and what is the board notification rule?" | `threshold_rationale` + ICAAP policy |

**T1 expected answer:** **LBY (Libya)** — 333 flagged txns, $6.81M, predominantly `CROSS_BORDER`;
**IRN (Iran)** — 333 flagged txns, $3.29M, predominantly `STRUCTURING`. Both are FATF
high-risk jurisdictions → **FATF Recommendation 19** requires enhanced due diligence.

```sql
-- VERIFY T1
SELECT country_code, fraud_pattern, COUNT(*) txns, ROUND(SUM(amount)/1e6,2) total_m
FROM CITADEL_DB.RISK.TRANSACTIONS
WHERE is_flagged=TRUE AND high_risk_country=TRUE
GROUP BY 1,2 ORDER BY txns DESC;

-- VERIFY T4
SELECT flag_type, severity, COUNT(*) n FROM CITADEL_DB.RISK.RISK_FLAGS
WHERE flag_domain='LIQUIDITY' AND flag_status NOT IN ('ACTIONED','DISMISSED')
GROUP BY 1,2 ORDER BY n DESC;
-- Expect: NSFR_BREACH 84 · LCR_BREACH 83+14+13=110 · DUAL_BREACH 37
```

---

## 3️⃣ SOLUTION COMPLETENESS

*Prompts that walk the full **signal → evidence → finding → filing → audit** chain.*

| # | Prompt | Chain stage |
|---|---|---|
| C1 | "Walk me through how a single structuring transaction becomes a filed SAR in this system." | Full pipeline explanation |
| C2 | "Which accounts should I file a SAR for today, and what evidence goes in the narrative?" | Signal → finding |
| C3 | "If I freeze an account, what else happens automatically and where is it recorded?" | Action → audit trail |
| C4 | "Prove that our audit trail cannot be tampered with. What controls are in place?" | Governance / BCBS 239 |
| C5 | "Show me a case that went from flag to SAR to escalation, with timestamps." | End-to-end traceability |

### C1 — the demo money shot

Ask C1, then **switch to the Risk Dashboard tab and actually do it live:**

1. Filter Domain = `FRAUD`, Severity = `CRITICAL`, Min score = `65`
2. On a top critical flag, click **📄 File SAR** → AI generates the FinCEN narrative
3. Click **🔒 Freeze** → account status → `FROZEN`, case auto-opened
4. Click **⬆ Escalate** → routed to compliance officer
5. Switch to **📋 Audit Trail** tab → all three actions now appear at the top with timestamps

That sequence demonstrates Solution Completeness better than any answer text.

```sql
-- VERIFY C3/C5: the chain is recorded
SELECT log_id, action_type, object_type, object_id, actor_user, actor_role,
       change_summary, event_ts
FROM CITADEL_DB.RISK.AUDIT_LOG ORDER BY log_id DESC LIMIT 15;

-- VERIFY C4: no role can DELETE or UPDATE the audit log
SHOW GRANTS ON TABLE CITADEL_DB.RISK.AUDIT_LOG;
-- Expect: SELECT and INSERT only — no DELETE, no UPDATE
```

---

## 🔬 ADVERSARIAL TESTS (verify it doesn't hallucinate)

Judges often probe for made-up answers. Run these first so you know how it behaves.

| # | Prompt | Correct behaviour |
|---|---|---|
| A1 | "How many open flags do we have for MARKET_RISK?" | Should say **zero / not a tracked domain** — only FRAUD, CREDIT, LIQUIDITY exist |
| A2 | "What was our LCR in 2019?" | Should say data covers **last 90 days only**, not invent a figure |
| A3 | "Which customer has the largest deposit balance?" | Should answer from `ACCOUNTS`, or say it is not in scope — not fabricate a name |
| A4 | "Does MiFID II apply to our structuring flags?" | Should say **no** — MiFID II is not in the 10 loaded policy docs; correct citation is FinCEN |
| A5 | "File a SAR for flag 999999." | Should return a clean **not found** error, not a fake filing |

---

## ⏱️ 5-MINUTE DEMO RUNNING ORDER

| Time | Action | Criterion hit |
|---|---|---|
| 0:00 | Open app — narrate the **Signal → Finding pipeline banner** (live counts) | Solution Completeness |
| 0:30 | Ask **KILLER #3** (structuring / 100% in evasion band) | Real World Relevance |
| 1:30 | Ask **KILLER #2** (PEP rated LOW → FATF R.12 breach) | Technical Execution |
| 2:30 | Ask **KILLER #1** (audit doc + watch-list data agree) | Cross-layer reasoning |
| 3:30 | Dashboard tab → hover KPI `ⓘ` tooltips → File SAR → Freeze → Escalate | Solution Completeness |
| 4:30 | Audit Trail tab → the three actions appear with timestamps → Export CSV | Governance / BCBS 239 |

---

## Notes

- Always run direct verification SQL as `ACCOUNTADMIN` — the default session role
  `CITADEL_MCP_READER_ROLE` is blocked by the row access policy on `REGULATORY_FILINGS`.
- Chat runs on `SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-4-6', …)` via `session.sql()`.
  No PAT or REST token required inside Streamlit-in-Snowflake.
- The 10 `POLICY_DOCS` rows are the only regulatory corpus. Any citation outside
  Basel III, FinCEN, FATF, RBI IRAC, or BCBS 239 is a hallucination — see test A4.

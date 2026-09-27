---
name: citadel
description: >
  Citadel is a Risk, Fraud and Regulatory Intelligence Copilot for banking and NBFC teams.
  It surfaces fraud patterns, credit watch-list alerts, and liquidity breaches in natural
  language, and cites the exact regulatory rule (Basel III, FATF, FinCEN, RBI) behind each
  finding. Built on Snowflake Cortex Analyst + Cortex Search + Cortex Agent over synthetic
  but structurally realistic banking data.
metadata:
  type: agent_skill
  version: "1.1.0"
  phase: "complete-all-phases"
  ui_version: "v6-light-mode"
  mcp_status: "verified-read-and-write"
  hackathon: "Snowflake CoCo CLI Hackathon 2026"
  author: "Avinash L (avinashreddy508)"
  snowflake_account: "JSTEYZM-MP60447"
---

# Citadel — Risk, Fraud and Regulatory Intelligence Copilot

## What This Skill Does

Citadel is a compliance-grade copilot that lets a **risk analyst** or **compliance officer**
ask plain-English questions about fraud signals, credit exposures, and liquidity positions,
and receive answers that are:

- **Grounded** — backed by a structured semantic view over 50,000+ transactions
- **Cited** — every risk threshold references the regulation that defines it
- **Explainable** — the `threshold_rationale` column carries the pitch-ready regulatory basis
- **Action-ready** — every flag row carries an `evidence_payload` VARIANT that a future
  stored procedure (file_sar_draft, flag_account, escalate_case) can act on directly

## Current Objects (All Phases — Production-Ready)

| Object | Type | Purpose |
|---|---|---|
| `CITADEL_DB.RISK.CUSTOMERS` | Table | 500 customers — PII masked by role |
| `CITADEL_DB.RISK.ACCOUNTS` | Table | 800 accounts — NPA flags, credit limits |
| `CITADEL_DB.RISK.TRANSACTIONS` | Table | 50,000 transactions — 4 fraud patterns injected |
| `CITADEL_DB.RISK.CREDIT_EXPOSURES` | Table | 300 Basel III facilities — PD/LGD/EAD/RWA |
| `CITADEL_DB.RISK.LIQUIDITY_POSITIONS` | Table | 450 daily LCR/NSFR snapshots |
| `CITADEL_DB.RISK.REGULATORY_FILINGS` | Table | 405+ SAR/CTR filings — AI narrative via CORTEX.COMPLETE. NARRATIVE VARCHAR(16000). |
| `CITADEL_DB.RISK.CASE_ESCALATIONS` | Table | 53+ escalation cases — OPEN/ESCALATED/RESOLVED lifecycle |
| `CITADEL_DB.RISK.AUDIT_LOG` | Table | 60+ immutable action entries. No DELETE/UPDATE grant. BCBS 239 P.2. |
| `CITADEL_DB.RISK.RISK_FLAGS` | Table | 9,318 unified fraud/credit/liquidity signals — evidence_payload VARIANT |
| `CITADEL_DB.RISK.POLICY_DOCS` | Table | 10 regulatory/policy documents |
| `CITADEL_DB.RISK.CITADEL_RISK_INTELLIGENCE` | Semantic View | Cortex Analyst — 18 metrics, 30+ filters, 8 VQRs |
| `CITADEL_DB.RISK.CITADEL_SEARCH_SVC` | Cortex Search | ACTIVE — snowflake-arctic-embed-m-v1.5 |
| `CITADEL_DB.RISK.CITADEL_AGENT` | Cortex Agent | claude-sonnet-4-6 + Analyst + Search + MCP tools |
| `CITADEL_DB.RISK.CITADEL_APP` | Streamlit | v3 production UI — Chat + Dashboard + Audit Trail |
| `CITADEL_DB.RISK.FILE_SAR_DRAFT` | Stored Proc | AI SAR narrative via CORTEX.COMPLETE |
| `CITADEL_DB.RISK.FLAG_ACCOUNT` | Stored Proc | Freeze account + create case + AUDIT_LOG |
| `CITADEL_DB.RISK.ESCALATE_CASE` | Stored Proc | Escalate case + AUDIT_LOG |
| `CITADEL_DB.RISK.RISK_FLAGS_REFRESH` | Task | 15-min real-time fraud detection. State: started. |
| `CITADEL_DB.RISK.CITADEL_AGENT_MCP_SERVER` | MCP Server | AI Gateway — 1 CORTEX_AGENT_RUN tool (`citadel_agent`, arg `text`) |
| `CITADEL_DB.RISK.CITADEL_ACTIONS_MCP_SERVER` | MCP Server | Action Server — 3 GENERIC proc tools |
| `CITADEL_DB.RISK.CITADEL_RISK_COPILOT` | Cortex Extension | Published to PUBLIC — CoCo SKILL.md connector |
| `CITADEL_DB.RISK.CITADEL_STAGE` | Stage | Internal stage for app + plugin files |

## RBAC Model

```
CITADEL_ADMIN
  ├── CITADEL_COMPLIANCE_OFFICER  (read all + write filings; future: file_sar_draft proc)
  │     └── CITADEL_RISK_MANAGER  (read all + write escalations; future: escalate_case, flag_account)
  │           └── CITADEL_RISK_ANALYST  (read-only views, heavy PII masking)
  └── CITADEL_AUDITOR              (read-only incl. AUDIT_LOG)
```

Masking policies on `national_id`, `full_name`, `account_number`.
Row access policy on `REGULATORY_FILINGS` (analysts see no rows).

## Fraud Rule Thresholds (for pitch)

| Pattern | Rule | Regulatory Basis |
|---|---|---|
| VELOCITY | 5+ transactions/hour same account | FinCEN SAR field 35(a) — rapid movement of funds |
| STRUCTURING | Amount $9,800–$9,999 | 31 CFR §1010.314 (BSA); PMLA Schedule Rule 3(B) |
| CROSS_BORDER | Wire to FATF grey/black-list country | FATF Recommendation 19; RBI Master Direction KYC 2016 §38 |
| ROUND_NUMBER | Round-dollar transfer >$10,000 | FATF TBML Typology Report 2020; internal rule R-007 |

## Credit Risk Thresholds (for pitch)

| Flag | Threshold | Regulatory Basis |
|---|---|---|
| HIGH_PD | PD > 0.15 | Basel III ICAAP internal calibration (BB-/B+ equivalent) |
| HIGH_UTILISATION | Utilisation > 90% | Internal Credit Policy §6.1 |
| NPA | 90 days past due | RBI Master Circular on IRAC 2023 |

## Liquidity Thresholds (for pitch)

| Flag | Threshold | Regulatory Basis |
|---|---|---|
| LCR_BREACH | LCR ratio < 100% | Basel III Art. 412 / BCBS Jan 2013 §415 |
| NSFR_BREACH | NSFR ratio < 100% | Basel III Art. 428b (effective Jan 2021) |

## Demo Questions

These verified queries are pre-registered in the semantic model, and are also the exact
8 quick-question shortcuts on the **left** ("regulatory") chat panel in the deployed
Streamlit app (`app/streamlit_app.py`, `DEMO_QS`). The app's chat tab has a **second,
independent chat panel** on the right ("Ask Citadel a question") with its own separate
conversation history and its own open-ended quick questions (`GENERAL_QS`) — capabilities,
overall risk summary, audit actions by role, open cases, how the app works, biggest risk today.

1. *"Which accounts show fraud-risk patterns this week?"*
2. *"What is the LCR trend over the last 30 days?"*
3. *"Show me the credit watch-list broken down by sector"*
4. *"Which high-risk customers have open fraud flags this week?"*
5. *"Give me a summary of open risk flags by domain and severity"*
6. *"Show me structuring transactions and the customers behind them"*
7. *"What is the total RWA exposure by sector and internal rating?"*
8. *"Show me the days where LCR was below 100 percent with details"*

## Streamlit App v3 — UI Design System

The v3 UI is a production-grade dark financial terminal:

- **Design tokens:** `--bg-base #0B1622`, `--primary #29B5E8`, semantic color variables for red/amber/green/purple
- **Typography:** Inter (UI) + JetBrains Mono (numbers, IDs, timestamps)
- **KPI cards:** 3px accent stripe per domain, `tabular-nums` values, contextual badges (BREACH/COMPLIANT)
- **Flags table:** Custom HTML with badge components, score color-coded by threshold
- **Audit timeline:** Icon tiles per action type with color-matched backgrounds
- **Compat:** `st.form` replaces `st.chat_input` (SiS uses Streamlit < 1.23); `_rerun()` helper for both rerun APIs

## Roadmap

| Phase | Status | Contents |
|---|---|---|
| Phase 1 — Foundation | COMPLETE | Schema, 8 tables, 52K+ rows synthetic data, masking, RBAC |
| Phase 2 — Intelligence | COMPLETE | RISK_FLAGS, semantic view, 10 policy docs, Cortex Search |
| Phase 3 — Agent | COMPLETE | CITADEL_AGENT wiring search + semantic view |
| Phase 4 — App | COMPLETE | CITADEL_APP Streamlit v3: Chat + Dashboard + Audit Trail (production UI) |
| Stretch — Actions | COMPLETE | AI SAR via CORTEX.COMPLETE + 2 MCP servers + OAuth + Cortex Extension |
| MCP verification | COMPLETE | Read + write endpoints tested end-to-end; 10 defects found and fixed. See `MCP_REFERENCE.md` |
| Last-Mile | COMPLETE | AUDIT_LOG seeded, real-time Task, v3 UI, demo chain verified |
| Demo Package | COMPLETE | 13-slide HTML deck + DEMO_SCRIPT.md narration guide |

## Files in This Directory

| File | Purpose |
|---|---|
| `SKILL.md` | This file — CoCo skill descriptor and reference card |
| `README.md` | Full project documentation |
| `DEMO_SCRIPT.md` | Step-by-step demo narration (exact SQL, talking points, troubleshooting) |
| `citadel_demo.html` | Interactive 13-slide demo deck (keyboard nav ← →) |
| `CITADEL_DEMO_PRESENTATION.html` | Full-screen 10-slide animated deck |
| `deploy.sql` | Idempotent deployment script for all phases (~1,610 lines) |
| `citadel_semantic_model.yaml` | Semantic view YAML for Cortex Analyst |

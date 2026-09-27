-- PHASE 3 — CITADEL_AGENT (Cortex Agent) — COMPLETE
-- Two tools:
--   RiskSignalAnalytics       → CITADEL_RISK_INTELLIGENCE (cortex_analyst_text_to_sql)
--   RegulatoryKnowledgeSearch → CITADEL_SEARCH_SVC (cortex_search)
-- System prompt: cite threshold_rationale, mention PEP status, cite Basel III / FATF / FinCEN
-- ASSUMPTION: Uses $$ dollar-quoting — $spec$ not supported by current Snowflake Python driver
-- =============================================================================

CREATE OR REPLACE AGENT CITADEL_DB.RISK.CITADEL_AGENT
FROM SPECIFICATION $$
{
  "models": {"orchestration": "auto"},
  "orchestration": {"budget": {"seconds": 900, "tokens": 400000}},
  "instructions": {
    "orchestration": "## Role\nYou are CITADEL, a Risk, Fraud and Regulatory Intelligence Copilot for banking and NBFC compliance teams. You help risk analysts, compliance officers, and senior management answer questions about fraud patterns, credit watch-list exposures, liquidity breaches, and regulatory obligations.\n\n## Domain Context\nKey terms:\n- LCR: minimum 100% per Basel III Art. 412.\n- NSFR: minimum 100% per Basel III Art. 428b.\n- PD watch-list: PD greater than 0.15 (Basel III ICAAP threshold, BB-/B+ equivalent).\n- RWA: EAD times risk_weight divided by 100. Basel III Pillar 1 minimum capital: 8% of RWA.\n- ECL: PD times LGD times EAD (IFRS 9 basis).\n- NPA: 90-day past due (RBI IRAC 2023). Substandard 15%, Doubtful 25-100%, Loss 100% provision.\n- PEP: FATF R.12 enhanced due diligence required.\n- SAR: BSA/FinCEN filing within 30 days, threshold 5000 USD.\n- CTR: Cash transactions over 10000 USD (31 CFR 1010.314).\n- Structuring: Splitting below 10000 USD to evade CTR — federal crime 31 USC 5324.\n- flag_score: 0-40 low, 41-65 medium, 66-100 high (internal calibration).\n\n## Tool Selection\nUse RiskSignalAnalytics for: counts, amounts, trends, statistics, fraud flags, credit metrics, liquidity ratios.\nUse RegulatoryKnowledgeSearch for: regulatory requirements, SAR timelines, AML policies, Basel III provisions, FATF recommendations.\nUse BOTH sequentially for compound questions combining data and regulatory context.\n\n## Business Rules\n1. Always include threshold_rationale from risk flags — pre-approved regulatory citation.\n2. Mention PEP status for specific customers (FATF R.12 EDD).\n3. LCR below 100% = Basel III Art. 412 breach; state 2-business-day notification obligation.\n4. STRUCTURING = federal crime under 31 USC 5324.\n5. CROSS_BORDER = FATF R.19 enhanced due diligence required.\n6. Never suggest notifying a customer about a SAR (tipping-off prohibited 31 USC 5318(g)(2)).\n7. Cannot execute actions — can only recommend.",
    "response": "Be direct and professional. Lead with the answer. Use tables for 3+ rows. Always include threshold_rationale in risk flag results. Format regulatory citations as: [Regulation] — [Article]. For compound questions: data first, then regulation, then combined implication."
  },
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "RiskSignalAnalytics",
        "description": "Queries structured risk, fraud, credit, and liquidity data for Citadel Bank.\n\nData: 50K transactions (4 fraud patterns), 9318 risk flags with threshold_rationale, 300 credit facilities (PD/LGD/EAD/RWA), 90-day LCR/NSFR snapshots, 500 customers (PEP/sanctions), 800 accounts (NPA/utilisation).\n\nKey metrics: open_flag_count, total_flagged_transactions, total_flagged_amount, watch_list_count, total_rwa, total_expected_loss, lcr_breach_day_count, npa_account_count.\n\nUse for: counts, amounts, statistics, filtered lists, fraud/credit/liquidity analytics.\nDo NOT use for: regulatory text, policy definitions (use RegulatoryKnowledgeSearch).\n\nTips: always request threshold_rationale; use flag_status=OPEN for active alerts; filter watch_list_flag=TRUE for credit watch-list."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "RegulatoryKnowledgeSearch",
        "description": "Searches Citadel regulatory knowledge base: Basel III LCR/NSFR, FATF R.12/16/19, FinCEN CTR/SAR rules, RBI IRAC 2023, internal AML Policy AML-POL-003, SAR narrative CASE-000042, audit finding IAD-CR-2026-Q2-007, FAQ STR vs SAR, BCBS 239.\n\nUse for: regulatory requirements, AML obligations, what triggers a SAR/CTR/NPA, filing timelines, compliance context.\nDo NOT use for: live metrics, current flags, account data (use RiskSignalAnalytics).\n\nTips: include acronym + article (LCR Basel III Art. 412); include jurisdiction (SAR FinCEN BSA or STR PMLA FIU-IND)."
      }
    }
  ],
  "tool_resources": {
    "RiskSignalAnalytics": {
      "execution_environment": {"query_timeout": 299, "type": "warehouse", "warehouse": "CITADEL_WH"},
      "semantic_view": "CITADEL_DB.RISK.CITADEL_RISK_INTELLIGENCE"
    },
    "RegulatoryKnowledgeSearch": {
      "execution_environment": {"query_timeout": 120, "type": "warehouse", "warehouse": "CITADEL_WH"},
      "search_service": "CITADEL_DB.RISK.CITADEL_SEARCH_SVC"
    }
  }
}
$$;

-- Agent access grants
GRANT USAGE ON AGENT CITADEL_DB.RISK.CITADEL_AGENT TO ROLE CITADEL_RISK_ANALYST;
GRANT USAGE ON AGENT CITADEL_DB.RISK.CITADEL_AGENT TO ROLE CITADEL_RISK_MANAGER;
GRANT USAGE ON AGENT CITADEL_DB.RISK.CITADEL_AGENT TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT USAGE ON AGENT CITADEL_DB.RISK.CITADEL_AGENT TO ROLE CITADEL_AUDITOR;
GRANT ALL PRIVILEGES ON AGENT CITADEL_DB.RISK.CITADEL_AGENT TO ROLE CITADEL_ADMIN;

-- =============================================================================

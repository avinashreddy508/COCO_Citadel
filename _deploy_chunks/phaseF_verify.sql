-- DEMO CHAIN VERIFICATION — Run to prove signal → evidence → finding pipeline
-- =============================================================================
SELECT '1_SIGNAL'    AS step, 'RISK_FLAGS'         AS source, 'Critical flags by type' AS detail
UNION ALL
SELECT '2_SAR_COUNT', 'REGULATORY_FILINGS', COUNT(*)::VARCHAR || ' SAR drafts on file'
FROM CITADEL_DB.RISK.REGULATORY_FILINGS WHERE filing_type='SAR'
UNION ALL
SELECT '3_FROZEN',   'ACCOUNTS',            COUNT(*)::VARCHAR || ' accounts currently FROZEN'
FROM CITADEL_DB.RISK.ACCOUNTS WHERE status='FROZEN'
UNION ALL
SELECT '4_ESCALATED','CASE_ESCALATIONS',    COUNT(*)::VARCHAR || ' cases ESCALATED'
FROM CITADEL_DB.RISK.CASE_ESCALATIONS WHERE status='ESCALATED'
UNION ALL
SELECT '5_AUDIT',    'AUDIT_LOG',           COUNT(*)::VARCHAR || ' immutable audit entries'
FROM CITADEL_DB.RISK.AUDIT_LOG
ORDER BY step;

-- =============================================================================
-- SMOKE TESTS — Run after deployment to verify everything is in place
-- =============================================================================

SELECT 'CUSTOMERS'          AS tbl, COUNT(*) AS n FROM CITADEL_DB.RISK.CUSTOMERS         UNION ALL
SELECT 'ACCOUNTS',                  COUNT(*)       FROM CITADEL_DB.RISK.ACCOUNTS           UNION ALL
SELECT 'TRANSACTIONS',              COUNT(*)       FROM CITADEL_DB.RISK.TRANSACTIONS       UNION ALL
SELECT 'CREDIT_EXPOSURES',          COUNT(*)       FROM CITADEL_DB.RISK.CREDIT_EXPOSURES   UNION ALL
SELECT 'LIQUIDITY_POSITIONS',       COUNT(*)       FROM CITADEL_DB.RISK.LIQUIDITY_POSITIONS UNION ALL
SELECT 'REGULATORY_FILINGS',        COUNT(*)       FROM CITADEL_DB.RISK.REGULATORY_FILINGS UNION ALL
SELECT 'CASE_ESCALATIONS',          COUNT(*)       FROM CITADEL_DB.RISK.CASE_ESCALATIONS   UNION ALL
SELECT 'AUDIT_LOG',                 COUNT(*)       FROM CITADEL_DB.RISK.AUDIT_LOG           UNION ALL
SELECT 'RISK_FLAGS',                COUNT(*)       FROM CITADEL_DB.RISK.RISK_FLAGS          UNION ALL
SELECT 'POLICY_DOCS',               COUNT(*)       FROM CITADEL_DB.RISK.POLICY_DOCS
ORDER BY n DESC;

-- Expected after last-mile fixes:
-- TRANSACTIONS=50000, RISK_FLAGS>=9318, AUDIT_LOG>=54, REGULATORY_FILINGS>=203,
-- ACCOUNTS=800 (some FROZEN), CASE_ESCALATIONS>=52, POLICY_DOCS=10

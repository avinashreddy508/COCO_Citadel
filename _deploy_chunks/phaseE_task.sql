USE ROLE ACCOUNTADMIN;
-- 3. Real-time monitoring Task
CREATE OR REPLACE TASK CITADEL_DB.RISK.RISK_FLAGS_REFRESH
    WAREHOUSE   = CITADEL_WH
    SCHEDULE    = '15 MINUTE'
    COMMENT     = 'Detects new flagged transactions in the last 30 min and inserts them into RISK_FLAGS'
AS
INSERT INTO CITADEL_DB.RISK.RISK_FLAGS (
    flag_domain, flag_type, severity, flag_status,
    customer_id, account_id, txn_id,
    threshold_field, threshold_value, threshold_limit, threshold_rationale,
    evidence_payload, flag_score
)
SELECT 'FRAUD', t.fraud_pattern,
    CASE t.fraud_pattern WHEN 'CROSS_BORDER' THEN 'CRITICAL' WHEN 'VELOCITY' THEN 'HIGH'
         WHEN 'STRUCTURING' THEN 'HIGH' ELSE 'MEDIUM' END,
    COALESCE(t.review_status,'OPEN'),
    a.customer_id, t.account_id, t.txn_id,
    'flag_score', t.flag_score, 65.0,
    CASE t.fraud_pattern
        WHEN 'VELOCITY'     THEN '5+ transactions on same account within 1 hour — FinCEN SAR field 35(a)'
        WHEN 'STRUCTURING'  THEN 'Cash deposit $9,800-$9,999 — 31 CFR §1010.314 CTR threshold evasion'
        WHEN 'CROSS_BORDER' THEN 'Wire to FATF grey/black-list — FATF R.19; RBI KYC Direction §38'
        WHEN 'ROUND_NUMBER' THEN 'Round-dollar >$10,000 — FATF TBML Typology 2020'
    END,
    OBJECT_CONSTRUCT('customer_id',a.customer_id,'account_id',t.account_id,'txn_id',t.txn_id,
        'amount',t.amount,'channel',t.channel,'country_code',t.country_code,
        'fraud_pattern',t.fraud_pattern,'flag_score',t.flag_score,'txn_ts',t.txn_ts::VARCHAR),
    t.flag_score
FROM CITADEL_DB.RISK.TRANSACTIONS t
JOIN CITADEL_DB.RISK.ACCOUNTS a ON a.account_id = t.account_id
WHERE t.is_flagged = TRUE
  AND t.txn_ts >= DATEADD(minute, -30, CURRENT_TIMESTAMP())
  AND NOT EXISTS (SELECT 1 FROM CITADEL_DB.RISK.RISK_FLAGS rf WHERE rf.txn_id = t.txn_id);

ALTER TASK CITADEL_DB.RISK.RISK_FLAGS_REFRESH RESUME;


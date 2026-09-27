-- =============================================================================
-- CITADEL — Risk, Fraud and Regulatory Intelligence Copilot
-- Full Idempotent Deployment Script
-- =============================================================================
-- Snowflake CoCo CLI Hackathon 2026
-- Author  : Avinash L (avinashreddy508)
-- Account : JSTEYZM-MP60447
-- Updated : ALL PHASES + LAST-MILE FIXES + v3 PRODUCTION UI COMPLETE (demo-ready)
--
-- v3 UI changes (streamlit_app.py):
--   - Full dark design system (Inter + JetBrains Mono, CSS custom properties)
--   - Streamlit chrome removed (menu/toolbar/footer hidden)
--   - 3 tabs: Chat + Risk Dashboard + Audit Trail
--   - KPI cards with accent stripe, tabular-nums, contextual badges
--   - Custom HTML flag table with domain/severity badge components
--   - Audit timeline with per-action-type colored icon tiles
--   - st.chat_input replaced with st.form (SiS Streamlit version compat)
--   - _rerun() helper for st.rerun / st.experimental_rerun compat
--
-- Execution order:
--   1. Infrastructure (database, schema, warehouse)
--   2. Table DDL (8 core tables)
--   3. Synthetic data (customers → accounts → transactions → risk tables)
--   4. Masking + row access policies
--   5. RBAC (roles, grants)
--   6. Phase 2 — RISK_FLAGS table + data
--   7. Phase 2 — POLICY_DOCS table + data
--   8. Phase 2 — Cortex Search service
--   9. Phase 2 — Semantic view (deployed via Python script, see note below)
--  10. Phase 3 stub — CITADEL_AGENT (to be filled)
--  11. Phase 4 — Streamlit app (v3 production UI — 3 tabs)
--  12. Stretch stub — action stored procedures (to be filled)
--
-- NOTE: The semantic view (CITADEL_RISK_INTELLIGENCE) is deployed separately:
--   python path/to/upload_semantic_view_yaml.py \
--       citadel/citadel_semantic_model.yaml CITADEL_DB.RISK \
--       --connection Sept-6_AHap
-- =============================================================================

-- =============================================================================
-- PHASE 1 — SECTION 1: Infrastructure
-- =============================================================================

CREATE DATABASE IF NOT EXISTS CITADEL_DB
    DATA_RETENTION_TIME_IN_DAYS = 7
    COMMENT = 'Citadel — Risk, Fraud and Regulatory Intelligence Copilot';

CREATE SCHEMA IF NOT EXISTS CITADEL_DB.RISK
    COMMENT = 'Core risk, fraud and regulatory schema';

CREATE WAREHOUSE IF NOT EXISTS CITADEL_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND   = 120
    AUTO_RESUME    = TRUE
    COMMENT = 'Citadel workload warehouse';

USE DATABASE  CITADEL_DB;
USE SCHEMA    RISK;
USE WAREHOUSE CITADEL_WH;

-- =============================================================================
-- PHASE 1 — SECTION 2: Table DDL
-- All tables use CREATE OR REPLACE for idempotency.
-- =============================================================================

-- --------------------------------------------------------------------------
-- CUSTOMERS — PII anchor. national_id and full_name carry masking policies.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITADEL_DB.RISK.CUSTOMERS (
    customer_id       NUMBER          NOT NULL PRIMARY KEY,
    full_name         VARCHAR(120)    NOT NULL,
    date_of_birth     DATE,
    national_id       VARCHAR(20)     NOT NULL,
    segment           VARCHAR(30)     NOT NULL,        -- RETAIL | SME | CORPORATE | PRIVATE_BANKING
    kyc_status        VARCHAR(20)     NOT NULL,        -- VERIFIED | PENDING | EXPIRED | REJECTED
    kyc_expiry_date   DATE,
    country_of_birth  VARCHAR(50),
    nationality       VARCHAR(50),
    pep_flag          BOOLEAN         DEFAULT FALSE,   -- ASSUMPTION: ~2% PEP rate (plausible mid-size bank)
    sanction_flag     BOOLEAN         DEFAULT FALSE,   -- ASSUMPTION: ~1% sanctions flag
    risk_rating       VARCHAR(10)     NOT NULL,        -- LOW | MEDIUM | HIGH
    onboarded_date    DATE,
    relationship_mgr  VARCHAR(100),
    email             VARCHAR(200),
    phone             VARCHAR(30),
    created_at        TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Customer master — PII fields (full_name, national_id) carry masking policies';

-- --------------------------------------------------------------------------
-- ACCOUNTS — Account master. account_number masked for RISK_ANALYST.
-- NPA flag follows RBI IRAC norms: 90-day past due threshold.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITADEL_DB.RISK.ACCOUNTS (
    account_id          NUMBER          NOT NULL PRIMARY KEY,
    customer_id         NUMBER          NOT NULL REFERENCES CITADEL_DB.RISK.CUSTOMERS(customer_id),
    account_number      VARCHAR(20)     NOT NULL UNIQUE,
    account_type        VARCHAR(30)     NOT NULL,      -- SAVINGS | CURRENT | LOAN | CREDIT_CARD | OVERDRAFT
    currency            VARCHAR(3)      NOT NULL DEFAULT 'USD',
    balance             NUMBER(18,2),
    credit_limit        NUMBER(18,2),
    utilisation_pct     NUMBER(5,2),
    -- ASSUMPTION: NPA flag = TRUE when account is 90+ days past due (RBI IRAC 2023)
    status              VARCHAR(20)     NOT NULL,      -- ACTIVE | DORMANT | NPA | FROZEN | CLOSED
    npa_flag            BOOLEAN         DEFAULT FALSE,
    npa_classification  VARCHAR(30),                   -- SUBSTANDARD | DOUBTFUL | LOSS
    open_date           DATE,
    last_txn_date       DATE,
    avg_monthly_balance NUMBER(18,2),
    branch_code         VARCHAR(20),
    ifsc_code           VARCHAR(20),
    created_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Account master — account_number masked for RISK_ANALYST role';

-- --------------------------------------------------------------------------
-- TRANSACTIONS — 50K row spine. Four fraud patterns injected.
-- ASSUMPTION: Base fraud flag rate ~18% in demo data (real-world: 0.1-3%)
--   VELOCITY    — 5+ txns/hr same account (FinCEN SAR field 35a)
--   STRUCTURING — $9,800-$9,999 (31 CFR §1010.314 CTR threshold evasion)
--   CROSS_BORDER — FATF grey/black-list country (FATF R.19)
--   ROUND_NUMBER — round-dollar >$10K (FATF TBML Typology 2020)
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITADEL_DB.RISK.TRANSACTIONS (
    txn_id               VARCHAR(36)     NOT NULL PRIMARY KEY,
    account_id           NUMBER          NOT NULL REFERENCES CITADEL_DB.RISK.ACCOUNTS(account_id),
    txn_ts               TIMESTAMP_LTZ   NOT NULL,
    amount               NUMBER(18,2)    NOT NULL,
    currency             VARCHAR(3)      DEFAULT 'USD',
    txn_type             VARCHAR(30)     NOT NULL,     -- DEBIT | CREDIT
    channel              VARCHAR(30)     NOT NULL,     -- UPI | NEFT | RTGS | ATM | POS | WIRE | INTERNAL
    counterparty_account VARCHAR(20),
    counterparty_name    VARCHAR(120),
    country_code         VARCHAR(3),
    -- ASSUMPTION: High-risk countries = FATF grey/black list 2024
    high_risk_country    BOOLEAN         DEFAULT FALSE,
    txn_category         VARCHAR(40),
    reference_no         VARCHAR(50),
    is_flagged           BOOLEAN         DEFAULT FALSE,
    fraud_pattern        VARCHAR(30),               -- VELOCITY | STRUCTURING | CROSS_BORDER | ROUND_NUMBER
    -- ASSUMPTION: flag_score >65 = high risk (internal calibration, not a regulatory threshold)
    flag_score           NUMBER(5,2),               -- 0-100 composite risk score
    reviewed_by          VARCHAR(100),
    review_status        VARCHAR(20),               -- PENDING | CLEARED | CONFIRMED_FRAUD
    created_at           TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Transaction spine — 50K rows with ~18% injected fraud patterns for demo';

-- --------------------------------------------------------------------------
-- CREDIT_EXPOSURES — Basel III risk parameters.
-- ASSUMPTION: watch_list_flag = TRUE when PD > 0.15
--   Basis: Basel III ICAAP internal calibration; BB-/B+ equivalent on S&P scale
-- ASSUMPTION: RWA uses standardised approach (Basel III Pillar 1)
-- ASSUMPTION: Expected Loss = PD x LGD x EAD (IFRS 9 Stage 1 ECL basis)
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITADEL_DB.RISK.CREDIT_EXPOSURES (
    exposure_id         NUMBER          NOT NULL PRIMARY KEY,
    customer_id         NUMBER          NOT NULL REFERENCES CITADEL_DB.RISK.CUSTOMERS(customer_id),
    account_id          NUMBER          REFERENCES CITADEL_DB.RISK.ACCOUNTS(account_id),
    facility_type       VARCHAR(40)     NOT NULL, -- TERM_LOAN | REVOLVING | MORTGAGE | LC | GUARANTEE | WORKING_CAPITAL
    outstanding         NUMBER(18,2)    NOT NULL,
    credit_limit        NUMBER(18,2)    NOT NULL,
    utilisation_pct     NUMBER(5,2),              -- ASSUMPTION: breach threshold >90% (Credit Policy §6.1)
    pd_score            NUMBER(6,4)     NOT NULL, -- ASSUMPTION: watch-list at PD > 0.15 (Basel III ICAAP)
    lgd                 NUMBER(6,4)     NOT NULL, -- Loss Given Default 0-1
    ead                 NUMBER(18,2)    NOT NULL, -- Exposure at Default
    expected_loss       NUMBER(18,2),             -- Computed: PD x LGD x EAD
    risk_weight_pct     NUMBER(6,2),              -- ASSUMPTION: standardised approach (Basel III)
    rwa                 NUMBER(18,2),             -- Computed: EAD x risk_weight / 100
    internal_rating     VARCHAR(10),              -- AAA | AA | A | BBB | BB | B | CCC | D
    watch_list_flag     BOOLEAN         DEFAULT FALSE,
    collateral_type     VARCHAR(50),
    collateral_value    NUMBER(18,2),
    sector              VARCHAR(60),
    maturity_date       DATE,
    origination_date    DATE,
    last_review_date    DATE,
    created_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Basel III credit exposure — watch_list_flag = TRUE when PD > 0.15';

-- --------------------------------------------------------------------------
-- LIQUIDITY_POSITIONS — Daily LCR/NSFR snapshots.
-- ASSUMPTION: LCR minimum = 100% (Basel III Art. 412 / BCBS Jan 2013)
-- ASSUMPTION: NSFR minimum = 100% (Basel III Art. 428b, effective Jan 2021)
-- ASSUMPTION: 90-day window, 5 tenor buckets = 450 rows per stress scenario
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITADEL_DB.RISK.LIQUIDITY_POSITIONS (
    position_id         NUMBER          NOT NULL PRIMARY KEY,
    position_date       DATE            NOT NULL,
    tenor_bucket        VARCHAR(20)     NOT NULL,  -- 0_7D | 8_30D | 31_90D | 91_365D | OVER_1YR
    inflow              NUMBER(18,2)    NOT NULL,
    outflow             NUMBER(18,2)    NOT NULL,
    net_position        NUMBER(18,2),
    hqla_level1         NUMBER(18,2),              -- Cash, central bank reserves
    hqla_level2         NUMBER(18,2),              -- Govt bonds, covered bonds
    lcr_numerator       NUMBER(18,2),              -- Total HQLA
    lcr_denominator     NUMBER(18,2),              -- Net cash outflows over 30-day stress
    -- ASSUMPTION: LCR breach = ratio < 1.0 (Basel III Art. 412 minimum 100%)
    lcr_ratio           NUMBER(8,4),
    lcr_breach          BOOLEAN         DEFAULT FALSE,
    -- ASSUMPTION: NSFR breach = ratio < 1.0 (Basel III Art. 428b minimum 100%)
    nsfr_ratio          NUMBER(8,4),
    nsfr_breach         BOOLEAN         DEFAULT FALSE,
    stress_scenario     VARCHAR(20)     DEFAULT 'BASE',
    created_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP(),
    UNIQUE (position_date, tenor_bucket, stress_scenario)
)
COMMENT = 'Daily LCR/NSFR snapshots — lcr_breach TRUE when ratio < 1.0 (Basel III min 100%)';

-- --------------------------------------------------------------------------
-- REGULATORY_FILINGS — SAR/CTR/STR audit trail.
-- Row access policy restricts RISK_ANALYST from reading any rows.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITADEL_DB.RISK.REGULATORY_FILINGS (
    filing_id           NUMBER          NOT NULL PRIMARY KEY,
    customer_id         NUMBER          NOT NULL REFERENCES CITADEL_DB.RISK.CUSTOMERS(customer_id),
    account_id          NUMBER          REFERENCES CITADEL_DB.RISK.ACCOUNTS(account_id),
    filing_type         VARCHAR(20)     NOT NULL,  -- SAR | CTR | STR | SUSPICIOUS_ACTIVITY
    filing_status       VARCHAR(20)     NOT NULL,  -- DRAFT | SUBMITTED | ACKNOWLEDGED | CLOSED | REJECTED
    filing_date         DATE,
    submitted_date      DATE,
    regulatory_body     VARCHAR(60),               -- FinCEN | RBI | FCA | MAS | AUSTRAC
    filed_by            VARCHAR(100),
    assigned_to         VARCHAR(100),
    narrative           VARCHAR(4000),
    linked_txn_ids      VARIANT,
    amount_involved     NUMBER(18,2),
    risk_score          NUMBER(5,2),
    outcome             VARCHAR(40),
    reference_case_id   VARCHAR(50),
    created_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP(),
    updated_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'AML regulatory filings — row-level policy restricts RISK_ANALYST from reading';

-- --------------------------------------------------------------------------
-- CASE_ESCALATIONS — Escalation lifecycle with stored-proc hooks.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITADEL_DB.RISK.CASE_ESCALATIONS (
    case_id             NUMBER          NOT NULL PRIMARY KEY,
    customer_id         NUMBER          NOT NULL REFERENCES CITADEL_DB.RISK.CUSTOMERS(customer_id),
    account_id          NUMBER          REFERENCES CITADEL_DB.RISK.ACCOUNTS(account_id),
    linked_filing_id    NUMBER          REFERENCES CITADEL_DB.RISK.REGULATORY_FILINGS(filing_id),
    case_type           VARCHAR(30)     NOT NULL,  -- FRAUD | AML | CREDIT | LIQUIDITY | SANCTIONS
    severity            VARCHAR(20)     NOT NULL,  -- LOW | MEDIUM | HIGH | CRITICAL
    status              VARCHAR(30)     NOT NULL,  -- OPEN | UNDER_REVIEW | ESCALATED | RESOLVED | CLOSED
    assigned_to         VARCHAR(100),
    escalated_to        VARCHAR(100),
    created_by          VARCHAR(100),
    created_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP(),
    updated_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP(),
    due_date            DATE,
    sla_breach          BOOLEAN         DEFAULT FALSE,
    resolution_notes    VARCHAR(2000),
    evidence_txn_ids    VARIANT,
    tags                VARIANT
)
COMMENT = 'Case escalation lifecycle — RISK_MANAGER and COMPLIANCE_OFFICER can write via stored procs';

-- --------------------------------------------------------------------------
-- AUDIT_LOG — Immutable action trail. Schema-only in Phases 1-2.
-- Populated by action stored procedures in Phase 3 (Stretch).
-- ASSUMPTION: AUDIT_LOG INSERT not granted directly to roles —
--   will be granted to action procs running with CALLER's rights.
-- --------------------------------------------------------------------------
CREATE OR REPLACE TABLE CITADEL_DB.RISK.AUDIT_LOG (
    log_id          NUMBER          NOT NULL PRIMARY KEY AUTOINCREMENT,
    event_ts        TIMESTAMP_LTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    actor_user      VARCHAR(100)    NOT NULL,   -- CURRENT_USER() at proc call time
    actor_role      VARCHAR(100)    NOT NULL,   -- CURRENT_ROLE()
    action_type     VARCHAR(50)     NOT NULL,   -- FILE_SAR | FLAG_ACCOUNT | ESCALATE_CASE | UPDATE_CASE
    object_type     VARCHAR(50),               -- CUSTOMER | ACCOUNT | FILING | CASE | TRANSACTION
    object_id       VARCHAR(100),
    before_state    VARIANT,
    after_state     VARIANT,
    change_summary  VARCHAR(500),
    source_ip       VARCHAR(50),
    session_id      VARCHAR(100),
    request_id      VARCHAR(100)               -- Cortex Agent request_id for traceability
)
COMMENT = 'Immutable audit trail — populated by action stored procedures; AUDITOR role has read access';

-- =============================================================================
-- PHASE 1 — SECTION 3: Synthetic Data Generation
-- Uses Snowflake GENERATOR() + MOD arithmetic for deterministic, reproducible data.
-- =============================================================================

-- --------------------------------------------------------------------------
-- CUSTOMERS (500 rows)
-- --------------------------------------------------------------------------
INSERT INTO CITADEL_DB.RISK.CUSTOMERS (
    customer_id, full_name, date_of_birth, national_id, segment,
    kyc_status, kyc_expiry_date, country_of_birth, nationality,
    pep_flag, sanction_flag, risk_rating, onboarded_date,
    relationship_mgr, email, phone
)
WITH names AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY seq4()) AS rn,
        first_names.fname,
        last_names.lname
    FROM (
        SELECT VALUE::VARCHAR AS fname
        FROM TABLE(SPLIT_TO_TABLE(
          'James,John,Robert,Michael,William,David,Richard,Joseph,Thomas,Charles,Mary,Patricia,Jennifer,Linda,Barbara,Elizabeth,Susan,Jessica,Sarah,Karen,Daniel,Matthew,Anthony,Mark,Donald,Steven,Paul,Andrew,Kenneth,George,Emma,Olivia,Sophia,Ava,Isabella,Mia,Charlotte,Amelia,Harper,Evelyn,Raj,Priya,Arjun,Kavya,Vikram,Ananya,Rohan,Deepa,Sanjay,Meera,Wei,Xin,Zhang,Li,Wang,Chen,Liu,Yang,Huang,Zhao,Ahmed,Fatima,Omar,Layla,Hassan,Aisha,Yusuf,Zara,Ibrahim,Nour',
          ','
        ))
    ) first_names
    CROSS JOIN (
        SELECT VALUE::VARCHAR AS lname
        FROM TABLE(SPLIT_TO_TABLE(
          'Smith,Johnson,Williams,Brown,Jones,Garcia,Miller,Davis,Rodriguez,Martinez,Hernandez,Lopez,Gonzalez,Wilson,Anderson,Thomas,Taylor,Moore,Jackson,Martin,Lee,Perez,Thompson,White,Harris,Sanchez,Clark,Lewis,Robinson,Walker,Patel,Shah,Kumar,Singh,Gupta,Sharma,Verma,Nair,Reddy,Iyer,Zhang,Li,Wang,Chen,Liu,Yang,Huang,Zhao,Wu,Sun,Ali,Khan,Ahmed,Hassan,Hussein,Mohammed,Abdullah,Rahman,Malik,Ibrahim',
          ','
        ))
    ) last_names
),
base AS (SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS cid FROM TABLE(GENERATOR(ROWCOUNT => 500))),
segments  AS (SELECT ARRAY_CONSTRUCT('RETAIL','RETAIL','RETAIL','SME','SME','CORPORATE','PRIVATE_BANKING') AS v),
kyc_stats AS (SELECT ARRAY_CONSTRUCT('VERIFIED','VERIFIED','VERIFIED','VERIFIED','PENDING','EXPIRED','REJECTED') AS v),
ratings   AS (SELECT ARRAY_CONSTRUCT('LOW','LOW','MEDIUM','MEDIUM','HIGH') AS v),
countries AS (SELECT ARRAY_CONSTRUCT('USA','GBR','IND','SGP','AUS','CAN','ARE','DEU','FRA','NLD') AS v),
rms       AS (SELECT ARRAY_CONSTRUCT('Alex Morgan','Priya Nair','James Walsh','Sunita Reddy','Carlos Diaz','Anna Fischer','Liu Wei','Tariq Hassan') AS v)
SELECT
    b.cid,
    n.fname || ' ' || n.lname,
    DATEADD(day, -UNIFORM(25*365, 70*365, RANDOM()), CURRENT_DATE),
    UPPER(CHAR(65+MOD(b.cid,26))) || UPPER(CHAR(65+MOD(b.cid+3,26))) ||
      UPPER(CHAR(65+MOD(b.cid+7,26))) || '-' ||
      LPAD(UNIFORM(10000,99999,RANDOM())::VARCHAR,5,'0') || '-' ||
      UPPER(CHAR(65+MOD(b.cid*3,26))),
    segments.v[MOD(b.cid,7)]::VARCHAR,
    kyc_stats.v[MOD(b.cid,7)]::VARCHAR,
    CASE WHEN kyc_stats.v[MOD(b.cid,7)]::VARCHAR != 'REJECTED'
         THEN DATEADD(day, UNIFORM(30,730,RANDOM()), CURRENT_DATE) END,
    countries.v[MOD(b.cid,10)]::VARCHAR,
    countries.v[MOD(b.cid,10)]::VARCHAR,
    CASE WHEN MOD(b.cid,50)=0 THEN TRUE ELSE FALSE END,   -- ~2% PEP
    CASE WHEN MOD(b.cid,97)=0 THEN TRUE ELSE FALSE END,   -- ~1% sanctions
    ratings.v[MOD(b.cid,5)]::VARCHAR,
    DATEADD(day, -UNIFORM(30,3650,RANDOM()), CURRENT_DATE),
    rms.v[MOD(b.cid,8)]::VARCHAR,
    LOWER(n.fname) || '.' || LOWER(n.lname) || MOD(b.cid,100)::VARCHAR || '@example.com',
    '+1-' || LPAD(UNIFORM(2000000000,9999999999,RANDOM())::VARCHAR,10,'0')
FROM base b
JOIN names n ON n.rn = MOD(b.cid-1,70)+1
CROSS JOIN segments CROSS JOIN kyc_stats CROSS JOIN ratings CROSS JOIN countries CROSS JOIN rms;

-- --------------------------------------------------------------------------
-- ACCOUNTS (800 rows)
-- --------------------------------------------------------------------------
INSERT INTO CITADEL_DB.RISK.ACCOUNTS (
    account_id, customer_id, account_number, account_type, currency,
    balance, credit_limit, utilisation_pct, status, npa_flag,
    npa_classification, open_date, last_txn_date, avg_monthly_balance,
    branch_code, ifsc_code
)
WITH customer_base AS (SELECT customer_id, segment, risk_rating FROM CITADEL_DB.RISK.CUSTOMERS),
account_rows AS (SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS aid FROM TABLE(GENERATOR(ROWCOUNT => 800))),
mapping AS (
    SELECT ar.aid, cb.customer_id, cb.segment, cb.risk_rating
    FROM account_rows ar
    JOIN customer_base cb ON cb.customer_id = MOD(ar.aid-1,500)+1
),
acct_types AS (SELECT ARRAY_CONSTRUCT('SAVINGS','CURRENT','LOAN','CREDIT_CARD','OVERDRAFT') AS v),
currencies AS (SELECT ARRAY_CONSTRUCT('USD','USD','USD','USD','GBP','EUR','INR','SGD') AS v),
branches   AS (SELECT ARRAY_CONSTRUCT('BRN001','BRN002','BRN003','BRN004','BRN005','BRN006','BRN007','BRN008') AS v)
SELECT
    m.aid,
    m.customer_id,
    'ACC' || LPAD(m.aid::VARCHAR,10,'0'),
    acct_types.v[MOD(m.aid,5)]::VARCHAR,
    currencies.v[MOD(m.aid,8)]::VARCHAR,
    CASE acct_types.v[MOD(m.aid,5)]::VARCHAR
        WHEN 'SAVINGS'     THEN ROUND(UNIFORM(500,150000,RANDOM()),2)
        WHEN 'CURRENT'     THEN ROUND(UNIFORM(1000,500000,RANDOM()),2)
        WHEN 'LOAN'        THEN ROUND(UNIFORM(-500000,0,RANDOM()),2)
        WHEN 'CREDIT_CARD' THEN ROUND(UNIFORM(-20000,0,RANDOM()),2)
        WHEN 'OVERDRAFT'   THEN ROUND(UNIFORM(-50000,10000,RANDOM()),2)
    END,
    CASE acct_types.v[MOD(m.aid,5)]::VARCHAR
        WHEN 'CREDIT_CARD' THEN ROUND(UNIFORM(5000,50000,RANDOM()),2)
        WHEN 'OVERDRAFT'   THEN ROUND(UNIFORM(10000,100000,RANDOM()),2)
        WHEN 'CURRENT'     THEN ROUND(UNIFORM(50000,1000000,RANDOM()),2)
        ELSE NULL END,
    CASE acct_types.v[MOD(m.aid,5)]::VARCHAR
        WHEN 'CREDIT_CARD' THEN ROUND(UNIFORM(5,110,RANDOM()),2)
        WHEN 'OVERDRAFT'   THEN ROUND(UNIFORM(0,100,RANDOM()),2)
        ELSE NULL END,
    CASE WHEN m.risk_rating='HIGH' AND MOD(m.aid,5)=0 THEN 'NPA'
         WHEN MOD(m.aid,33)=0 THEN 'FROZEN'
         WHEN MOD(m.aid,20)=0 THEN 'DORMANT'
         ELSE 'ACTIVE' END,
    CASE WHEN m.risk_rating='HIGH' AND MOD(m.aid,5)=0 THEN TRUE ELSE FALSE END,
    CASE WHEN m.risk_rating='HIGH' AND MOD(m.aid,5)=0
         THEN acct_types.v[MOD(m.aid+1,3)]::VARCHAR END,
    DATEADD(day,-UNIFORM(90,3650,RANDOM()),CURRENT_DATE),
    DATEADD(day,-UNIFORM(0,90,RANDOM()),CURRENT_DATE),
    ROUND(UNIFORM(500,200000,RANDOM()),2),
    branches.v[MOD(m.aid,8)]::VARCHAR,
    'CITB0' || branches.v[MOD(m.aid,8)]::VARCHAR
FROM mapping m
CROSS JOIN acct_types CROSS JOIN currencies CROSS JOIN branches;

-- --------------------------------------------------------------------------
-- TRANSACTIONS (50,000 rows) — fraud patterns injected deterministically
-- ASSUMPTION: Fraud injection rates:
--   VELOCITY    every 33rd row (rows 0-4 in each group of 33)
--   STRUCTURING every 50th row
--   CROSS_BORDER every 75th row
--   ROUND_NUMBER every 120th row
-- Combined flagged rate ~18% (intentionally high for demo visibility)
-- --------------------------------------------------------------------------
INSERT INTO CITADEL_DB.RISK.TRANSACTIONS (
    txn_id, account_id, txn_ts, amount, currency, txn_type, channel,
    counterparty_account, counterparty_name, country_code, high_risk_country,
    txn_category, reference_no, is_flagged, fraud_pattern, flag_score,
    reviewed_by, review_status
)
WITH base AS (SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn FROM TABLE(GENERATOR(ROWCOUNT => 50000))),
channels   AS (SELECT ARRAY_CONSTRUCT('UPI','NEFT','RTGS','ATM','POS','WIRE','INTERNAL') AS v),
categories AS (SELECT ARRAY_CONSTRUCT('SALARY','RENT','TRANSFER','PURCHASE','CASH','UTILITY','INSURANCE','OTHER') AS v),
safe_cntry AS (SELECT ARRAY_CONSTRUCT('USA','GBR','CAN','AUS','DEU','FRA','SGP','JPN','NLD','CHE') AS v),
-- ASSUMPTION: High-risk country codes = FATF grey/black list 2024
risk_cntry AS (SELECT ARRAY_CONSTRUCT('IRN','PRK','SYR','MMR','YEM','LBY','SDN','BLR','RUS','VEN') AS v),
cp_names   AS (SELECT ARRAY_CONSTRUCT('Global Trade LLC','Sunrise Ventures','Metro Corp','Pacific Holdings','Eastern Traders','Atlantic Partners','Nordic Finance','Delta Enterprises','Apex Logistics','Summit Capital') AS v)
SELECT
    UUID_STRING(),
    MOD(b.rn,800)+1,
    CASE WHEN MOD(b.rn,33) BETWEEN 0 AND 4
        THEN DATEADD(minute,MOD(b.rn,5)*10,
             DATEADD(hour,-UNIFORM(1,2160,RANDOM()),
             DATEADD(day,-UNIFORM(0,7,RANDOM()),CURRENT_TIMESTAMP())))
        ELSE DATEADD(second,-UNIFORM(0,7776000,RANDOM()),CURRENT_TIMESTAMP())
    END,
    CASE WHEN MOD(b.rn,50)=0  THEN ROUND(UNIFORM(9800,9999,RANDOM()),2)    -- STRUCTURING
         WHEN MOD(b.rn,120)=0 THEN (UNIFORM(10,500,RANDOM())*1000)::NUMBER(18,2) -- ROUND_NUMBER
         WHEN MOD(b.rn,33) BETWEEN 0 AND 4 THEN ROUND(UNIFORM(500,5000,RANDOM()),2) -- VELOCITY
         ELSE ROUND(UNIFORM(10,50000,RANDOM()),2)
    END,
    'USD',
    CASE WHEN MOD(b.rn,3)=0 THEN 'CREDIT' ELSE 'DEBIT' END,
    channels.v[MOD(b.rn,7)]::VARCHAR,
    CASE WHEN MOD(b.rn,75)=0 THEN 'XACC'||LPAD(UNIFORM(1000000,9999999,RANDOM())::VARCHAR,9,'0')
         ELSE 'ACC'||LPAD((MOD(b.rn+1,800)+1)::VARCHAR,10,'0') END,
    cp_names.v[MOD(b.rn,10)]::VARCHAR,
    CASE WHEN MOD(b.rn,75)=0 THEN risk_cntry.v[MOD(b.rn,10)]::VARCHAR
         ELSE safe_cntry.v[MOD(b.rn,10)]::VARCHAR END,
    CASE WHEN MOD(b.rn,75)=0 THEN TRUE ELSE FALSE END,
    categories.v[MOD(b.rn,8)]::VARCHAR,
    'REF'||LPAD(b.rn::VARCHAR,10,'0'),
    CASE WHEN MOD(b.rn,33) BETWEEN 0 AND 4 THEN TRUE
         WHEN MOD(b.rn,50)=0  THEN TRUE
         WHEN MOD(b.rn,75)=0  THEN TRUE
         WHEN MOD(b.rn,120)=0 THEN TRUE
         ELSE FALSE END,
    CASE WHEN MOD(b.rn,33) BETWEEN 0 AND 4 THEN 'VELOCITY'
         WHEN MOD(b.rn,50)=0  THEN 'STRUCTURING'
         WHEN MOD(b.rn,75)=0  THEN 'CROSS_BORDER'
         WHEN MOD(b.rn,120)=0 THEN 'ROUND_NUMBER'
         ELSE NULL END,
    CASE WHEN MOD(b.rn,33) BETWEEN 0 AND 4 THEN ROUND(UNIFORM(65,95,RANDOM()),2)
         WHEN MOD(b.rn,50)=0  THEN ROUND(UNIFORM(60,85,RANDOM()),2)
         WHEN MOD(b.rn,75)=0  THEN ROUND(UNIFORM(70,95,RANDOM()),2)
         WHEN MOD(b.rn,120)=0 THEN ROUND(UNIFORM(55,75,RANDOM()),2)
         ELSE ROUND(UNIFORM(5,40,RANDOM()),2) END,
    CASE WHEN (MOD(b.rn,33) BETWEEN 0 AND 4 OR MOD(b.rn,50)=0 OR MOD(b.rn,75)=0 OR MOD(b.rn,120)=0)
              AND MOD(b.rn,3)=0 THEN 'compliance.officer@citadel.bank' ELSE NULL END,
    CASE WHEN (MOD(b.rn,33) BETWEEN 0 AND 4 OR MOD(b.rn,50)=0 OR MOD(b.rn,75)=0 OR MOD(b.rn,120)=0)
              AND MOD(b.rn,3)=0 THEN CASE WHEN MOD(b.rn,5)=0 THEN 'CONFIRMED_FRAUD' ELSE 'CLEARED' END
         WHEN (MOD(b.rn,33) BETWEEN 0 AND 4 OR MOD(b.rn,50)=0 OR MOD(b.rn,75)=0 OR MOD(b.rn,120)=0)
              THEN 'PENDING'
         ELSE NULL END
FROM base b
CROSS JOIN channels CROSS JOIN categories CROSS JOIN safe_cntry CROSS JOIN risk_cntry CROSS JOIN cp_names;

-- --------------------------------------------------------------------------
-- CREDIT_EXPOSURES (300 rows)
-- --------------------------------------------------------------------------
INSERT INTO CITADEL_DB.RISK.CREDIT_EXPOSURES (
    exposure_id, customer_id, account_id, facility_type, outstanding,
    credit_limit, utilisation_pct, pd_score, lgd, ead, expected_loss,
    risk_weight_pct, rwa, internal_rating, watch_list_flag,
    collateral_type, collateral_value, sector, maturity_date, origination_date, last_review_date
)
WITH base AS (SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn FROM TABLE(GENERATOR(ROWCOUNT => 300))),
facility_types AS (SELECT ARRAY_CONSTRUCT('TERM_LOAN','REVOLVING','MORTGAGE','LETTER_OF_CREDIT','GUARANTEE','WORKING_CAPITAL') AS v),
ratings        AS (SELECT ARRAY_CONSTRUCT('AAA','AA','A','BBB','BB','B','CCC','D') AS v),
collaterals    AS (SELECT ARRAY_CONSTRUCT('PROPERTY','EQUITY','FIXED_DEPOSIT','VEHICLE','MACHINERY','UNSECURED') AS v),
sectors        AS (SELECT ARRAY_CONSTRUCT('REAL_ESTATE','MANUFACTURING','TRADE','SERVICES','AGRICULTURE','TECHNOLOGY','HEALTHCARE','ENERGY') AS v)
SELECT
    b.rn,
    MOD(b.rn-1,500)+1,
    CASE WHEN MOD(b.rn,4)!=0 THEN MOD(b.rn-1,800)+1 ELSE NULL END,
    facility_types.v[MOD(b.rn,6)]::VARCHAR,
    ROUND(UNIFORM(10000,5000000,RANDOM()),2),
    ROUND(UNIFORM(50000,10000000,RANDOM()),2),
    CASE WHEN MOD(b.rn,5)=0 THEN ROUND(UNIFORM(90,120,RANDOM()),2)
         ELSE ROUND(UNIFORM(10,85,RANDOM()),2) END,
    -- ASSUMPTION: ~25% of rows are watch-list (PD > 0.15)
    CASE WHEN MOD(b.rn,4)=0 THEN ROUND(UNIFORM(0.15,0.65,RANDOM()),4)
         ELSE ROUND(UNIFORM(0.001,0.14,RANDOM()),4) END,
    ROUND(UNIFORM(0.20,0.80,RANDOM()),4),
    ROUND(UNIFORM(10000,5500000,RANDOM()),2),
    NULL, -- back-filled below
    CASE MOD(b.rn,5) WHEN 0 THEN 100.00 WHEN 1 THEN 75.00 WHEN 2 THEN 150.00 WHEN 3 THEN 50.00 ELSE 20.00 END,
    NULL, -- back-filled below
    ratings.v[MOD(b.rn,8)]::VARCHAR,
    CASE WHEN MOD(b.rn,4)=0 THEN TRUE ELSE FALSE END,
    collaterals.v[MOD(b.rn,6)]::VARCHAR,
    ROUND(UNIFORM(5000,8000000,RANDOM()),2),
    sectors.v[MOD(b.rn,8)]::VARCHAR,
    DATEADD(day,UNIFORM(30,3650,RANDOM()),CURRENT_DATE),
    DATEADD(day,-UNIFORM(30,1825,RANDOM()),CURRENT_DATE),
    DATEADD(day,-UNIFORM(0,365,RANDOM()),CURRENT_DATE)
FROM base b
CROSS JOIN facility_types CROSS JOIN ratings CROSS JOIN collaterals CROSS JOIN sectors;

UPDATE CITADEL_DB.RISK.CREDIT_EXPOSURES
SET expected_loss = ROUND(pd_score * lgd * ead, 2),
    rwa           = ROUND(ead * risk_weight_pct / 100, 2)
WHERE expected_loss IS NULL;

-- --------------------------------------------------------------------------
-- LIQUIDITY_POSITIONS (90 days x 5 buckets = 450 rows)
-- ASSUMPTION: ~10% of rows inject stress outflows that cause LCR breach
-- --------------------------------------------------------------------------
INSERT INTO CITADEL_DB.RISK.LIQUIDITY_POSITIONS (
    position_id, position_date, tenor_bucket, inflow, outflow, net_position,
    hqla_level1, hqla_level2, lcr_numerator, lcr_denominator,
    lcr_ratio, lcr_breach, nsfr_ratio, nsfr_breach, stress_scenario
)
WITH dates AS (
    SELECT DATEADD(day,-(ROW_NUMBER() OVER (ORDER BY seq4())-1),CURRENT_DATE) AS pos_date
    FROM TABLE(GENERATOR(ROWCOUNT => 90))
),
buckets AS (
    SELECT VALUE::VARCHAR AS bucket, INDEX AS bucket_idx
    FROM TABLE(SPLIT_TO_TABLE('0_7D,8_30D,31_90D,91_365D,OVER_1YR',','))
),
base AS (
    SELECT ROW_NUMBER() OVER (ORDER BY d.pos_date, b.bucket_idx) AS rn,
           d.pos_date, b.bucket, b.bucket_idx
    FROM dates d CROSS JOIN buckets b
)
SELECT
    b.rn, b.pos_date, b.bucket,
    ROUND(UNIFORM(1000000,50000000,RANDOM())*(5-b.bucket_idx+1),2),
    CASE WHEN MOD(b.rn,10)=0 AND b.bucket IN ('0_7D','8_30D')
         THEN ROUND(UNIFORM(40000000,80000000,RANDOM()),2)
         ELSE ROUND(UNIFORM(500000,30000000,RANDOM())*(5-b.bucket_idx+1),2) END,
    ROUND(UNIFORM(1000000,50000000,RANDOM())*(5-b.bucket_idx+1)-
          UNIFORM(500000,30000000,RANDOM())*(5-b.bucket_idx+1),2),
    ROUND(UNIFORM(20000000,100000000,RANDOM()),2),
    ROUND(UNIFORM(5000000,40000000,RANDOM()),2),
    ROUND(UNIFORM(25000000,140000000,RANDOM()),2),
    -- Inject LCR breach on ~10% of rows
    CASE WHEN MOD(b.rn,10)=0 THEN ROUND(UNIFORM(120000000,180000000,RANDOM()),2)
         ELSE ROUND(UNIFORM(10000000,100000000,RANDOM()),2) END,
    NULL, -- back-filled below
    FALSE,
    ROUND(UNIFORM(0.85,1.35,RANDOM()),4),
    FALSE,
    'BASE'
FROM base b;

UPDATE CITADEL_DB.RISK.LIQUIDITY_POSITIONS
SET lcr_ratio   = ROUND(lcr_numerator/NULLIF(lcr_denominator,0),4),
    lcr_breach  = CASE WHEN lcr_numerator/NULLIF(lcr_denominator,0) < 1.0 THEN TRUE ELSE FALSE END,
    nsfr_breach = CASE WHEN nsfr_ratio < 1.0 THEN TRUE ELSE FALSE END
WHERE lcr_ratio IS NULL;

-- --------------------------------------------------------------------------
-- REGULATORY_FILINGS (200 rows)
-- --------------------------------------------------------------------------
INSERT INTO CITADEL_DB.RISK.REGULATORY_FILINGS (
    filing_id, customer_id, account_id, filing_type, filing_status,
    filing_date, submitted_date, regulatory_body, filed_by, assigned_to,
    narrative, linked_txn_ids, amount_involved, risk_score, outcome, reference_case_id
)
WITH base AS (SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn FROM TABLE(GENERATOR(ROWCOUNT => 200))),
ftypes    AS (SELECT ARRAY_CONSTRUCT('SAR','CTR','STR','SUSPICIOUS_ACTIVITY') AS v),
fstatus   AS (SELECT ARRAY_CONSTRUCT('DRAFT','SUBMITTED','ACKNOWLEDGED','CLOSED','REJECTED') AS v),
reg_body  AS (SELECT ARRAY_CONSTRUCT('FinCEN','RBI','FCA','MAS','AUSTRAC') AS v),
officers  AS (SELECT ARRAY_CONSTRUCT('sarah.chen@citadel.bank','james.okonkwo@citadel.bank','priya.nair@citadel.bank','david.walsh@citadel.bank') AS v),
outcomes  AS (SELECT ARRAY_CONSTRUCT('FILED','DECLINED','ESCALATED','UNDER_INVESTIGATION') AS v),
narratives AS (SELECT ARRAY_CONSTRUCT(
    'Customer exhibited unusual cash deposit pattern inconsistent with stated income. Multiple cash deposits just below $10,000 threshold observed over 14-day period.',
    'Wire transfers totaling $245,000 sent to high-risk jurisdiction within 72 hours. Customer unable to provide satisfactory business justification.',
    'Rapid cycling of funds through multiple internal accounts followed by large SWIFT transfer to offshore entity. Pattern consistent with layering activity.',
    'Customer account received multiple third-party deposits from unrelated entities followed by immediate withdrawal via ATM. No apparent business purpose.',
    'Significant deviation from established transaction profile. Customer previously averaging $5,000/month now transacting $150,000 in single week.',
    'Cross-border transfer to sanctioned jurisdiction detected by automated screening. Customer claims payment for consulting services but cannot provide documentation.',
    'Structuring suspected: 12 cash deposits of $9,800-$9,950 across 8 business days. Pattern designed to evade CTR reporting threshold.',
    'PEP-linked account showing unusual inflows from shell company registered in BVI. Beneficial ownership unclear despite enhanced due diligence request.',
    'Dormant account reactivated after 18 months with immediate high-value transactions. No change in customer circumstances to justify activity.',
    'Series of round-dollar wire transfers ($25,000 each) to five different recipients in three countries within 48 hours. Possible trade-based money laundering.'
) AS v)
SELECT
    b.rn,
    MOD(b.rn-1,500)+1,
    MOD(b.rn-1,800)+1,
    ftypes.v[MOD(b.rn,4)]::VARCHAR,
    fstatus.v[MOD(b.rn,5)]::VARCHAR,
    DATEADD(day,-UNIFORM(1,180,RANDOM()),CURRENT_DATE),
    CASE WHEN fstatus.v[MOD(b.rn,5)]::VARCHAR NOT IN ('DRAFT')
         THEN DATEADD(day,-UNIFORM(1,150,RANDOM()),CURRENT_DATE) END,
    reg_body.v[MOD(b.rn,5)]::VARCHAR,
    officers.v[MOD(b.rn,4)]::VARCHAR,
    officers.v[MOD(b.rn+1,4)]::VARCHAR,
    narratives.v[MOD(b.rn,10)]::VARCHAR,
    ARRAY_CONSTRUCT('REF'||LPAD(UNIFORM(1,50000,RANDOM())::VARCHAR,10,'0'),
                    'REF'||LPAD(UNIFORM(1,50000,RANDOM())::VARCHAR,10,'0')),
    ROUND(UNIFORM(5000,500000,RANDOM()),2),
    ROUND(UNIFORM(40,98,RANDOM()),2),
    outcomes.v[MOD(b.rn,4)]::VARCHAR,
    'CASE-'||LPAD(b.rn::VARCHAR,6,'0')
FROM base b
CROSS JOIN ftypes CROSS JOIN fstatus CROSS JOIN reg_body CROSS JOIN officers CROSS JOIN outcomes CROSS JOIN narratives;

-- --------------------------------------------------------------------------
-- CASE_ESCALATIONS (50 rows)
-- --------------------------------------------------------------------------
INSERT INTO CITADEL_DB.RISK.CASE_ESCALATIONS (
    case_id, customer_id, account_id, linked_filing_id, case_type, severity, status,
    assigned_to, escalated_to, created_by, created_at, updated_at, due_date,
    sla_breach, resolution_notes, evidence_txn_ids, tags
)
WITH base AS (SELECT ROW_NUMBER() OVER (ORDER BY seq4()) AS rn FROM TABLE(GENERATOR(ROWCOUNT => 50))),
ctypes   AS (SELECT ARRAY_CONSTRUCT('FRAUD','AML','CREDIT','LIQUIDITY','SANCTIONS') AS v),
sev      AS (SELECT ARRAY_CONSTRUCT('LOW','MEDIUM','HIGH','CRITICAL') AS v),
stats    AS (SELECT ARRAY_CONSTRUCT('OPEN','UNDER_REVIEW','ESCALATED','RESOLVED','CLOSED') AS v),
analysts AS (SELECT ARRAY_CONSTRUCT('risk.analyst1@citadel.bank','risk.analyst2@citadel.bank','risk.analyst3@citadel.bank') AS v),
managers AS (SELECT ARRAY_CONSTRUCT('risk.manager@citadel.bank','compliance.officer@citadel.bank') AS v),
notes    AS (SELECT ARRAY_CONSTRUCT(
    'Multiple fraud patterns detected. Escalating to senior compliance team for enhanced review.',
    'Customer under enhanced monitoring. Transactions frozen pending investigation outcome.',
    'Basel III breach threshold approached. Notifying ALM committee for immediate action.',
    'Sanctions screening hit confirmed. Account suspended and regulatory notification initiated.',
    'Credit exposure exceeds single-borrower limit. Board approval required for continuation.'
) AS v)
SELECT
    b.rn, MOD(b.rn-1,500)+1, MOD(b.rn-1,800)+1,
    CASE WHEN MOD(b.rn,3)=0 THEN MOD(b.rn-1,200)+1 ELSE NULL END,
    ctypes.v[MOD(b.rn,5)]::VARCHAR, sev.v[MOD(b.rn,4)]::VARCHAR,
    stats.v[MOD(b.rn,5)]::VARCHAR, analysts.v[MOD(b.rn,3)]::VARCHAR,
    CASE WHEN sev.v[MOD(b.rn,4)]::VARCHAR IN ('HIGH','CRITICAL')
         THEN managers.v[MOD(b.rn,2)]::VARCHAR ELSE NULL END,
    analysts.v[MOD(b.rn,3)]::VARCHAR,
    DATEADD(day,-UNIFORM(1,60,RANDOM()),CURRENT_TIMESTAMP()),
    DATEADD(hour,-UNIFORM(0,48,RANDOM()),CURRENT_TIMESTAMP()),
    DATEADD(day,UNIFORM(1,30,RANDOM()),CURRENT_DATE),
    CASE WHEN MOD(b.rn,7)=0 THEN TRUE ELSE FALSE END,
    notes.v[MOD(b.rn,5)]::VARCHAR,
    ARRAY_CONSTRUCT('REF'||LPAD(UNIFORM(1,50000,RANDOM())::VARCHAR,10,'0'),
                    'REF'||LPAD(UNIFORM(1,50000,RANDOM())::VARCHAR,10,'0')),
    ARRAY_CONSTRUCT(ctypes.v[MOD(b.rn,5)]::VARCHAR, sev.v[MOD(b.rn,4)]::VARCHAR)
FROM base b
CROSS JOIN ctypes CROSS JOIN sev CROSS JOIN stats CROSS JOIN analysts CROSS JOIN managers CROSS JOIN notes;

-- =============================================================================
-- PHASE 1 — SECTION 4: Masking Policies and Row Access Policy
-- =============================================================================

CREATE OR REPLACE MASKING POLICY CITADEL_DB.RISK.mask_national_id
    AS (val VARCHAR) RETURNS VARCHAR ->
    CASE WHEN CURRENT_ROLE() IN ('CITADEL_ADMIN','CITADEL_COMPLIANCE_OFFICER',
                                  'CITADEL_RISK_MANAGER','SYSADMIN','ACCOUNTADMIN')
         THEN val
         ELSE 'XXX-XX-' || RIGHT(val,4)
    END;

CREATE OR REPLACE MASKING POLICY CITADEL_DB.RISK.mask_account_number
    AS (val VARCHAR) RETURNS VARCHAR ->
    CASE WHEN CURRENT_ROLE() IN ('CITADEL_ADMIN','CITADEL_COMPLIANCE_OFFICER',
                                  'SYSADMIN','ACCOUNTADMIN')
         THEN val
         WHEN CURRENT_ROLE() IN ('CITADEL_RISK_MANAGER','CITADEL_AUDITOR')
         THEN 'XXXX-' || RIGHT(val,4)
         ELSE 'XXXX-XXXX-' || RIGHT(val,4)
    END;

CREATE OR REPLACE MASKING POLICY CITADEL_DB.RISK.mask_full_name
    AS (val VARCHAR) RETURNS VARCHAR ->
    CASE WHEN CURRENT_ROLE() IN ('CITADEL_ADMIN','CITADEL_COMPLIANCE_OFFICER',
                                  'CITADEL_RISK_MANAGER','SYSADMIN','ACCOUNTADMIN')
         THEN val
         ELSE SPLIT_PART(val,' ',1) || ' ***'
    END;

ALTER TABLE CITADEL_DB.RISK.CUSTOMERS
    MODIFY COLUMN national_id  SET MASKING POLICY CITADEL_DB.RISK.mask_national_id;
ALTER TABLE CITADEL_DB.RISK.CUSTOMERS
    MODIFY COLUMN full_name    SET MASKING POLICY CITADEL_DB.RISK.mask_full_name;
ALTER TABLE CITADEL_DB.RISK.ACCOUNTS
    MODIFY COLUMN account_number SET MASKING POLICY CITADEL_DB.RISK.mask_account_number;

-- Row access policy: REGULATORY_FILINGS
CREATE OR REPLACE ROW ACCESS POLICY CITADEL_DB.RISK.rap_regulatory_filings
    AS (assigned_to VARCHAR) RETURNS BOOLEAN ->
    CASE WHEN CURRENT_ROLE() IN ('CITADEL_ADMIN','CITADEL_COMPLIANCE_OFFICER',
                                  'CITADEL_AUDITOR','SYSADMIN','ACCOUNTADMIN')
         THEN TRUE
         WHEN CURRENT_ROLE() = 'CITADEL_RISK_MANAGER'
         THEN (assigned_to = CURRENT_USER() OR assigned_to LIKE '%@citadel.bank')
         ELSE FALSE
    END;

ALTER TABLE CITADEL_DB.RISK.REGULATORY_FILINGS
    ADD ROW ACCESS POLICY CITADEL_DB.RISK.rap_regulatory_filings ON (assigned_to);

-- =============================================================================
-- PHASE 1 — SECTION 5: RBAC (Roles and Grants)
-- =============================================================================

CREATE ROLE IF NOT EXISTS CITADEL_ADMIN
    COMMENT = 'Full DDL + DML on CITADEL_DB. No masking. For engineers and DBAs.';
CREATE ROLE IF NOT EXISTS CITADEL_RISK_MANAGER
    COMMENT = 'Read all risk data. Write CASE_ESCALATIONS. Future: EXECUTE flag_account, escalate_case procs.';
CREATE ROLE IF NOT EXISTS CITADEL_COMPLIANCE_OFFICER
    COMMENT = 'Read all data including REGULATORY_FILINGS. Write filings. Future: EXECUTE file_sar_draft proc.';
CREATE ROLE IF NOT EXISTS CITADEL_RISK_ANALYST
    COMMENT = 'Read-only on views (not base tables). Heavy masking on PII. Cannot see REGULATORY_FILINGS.';
CREATE ROLE IF NOT EXISTS CITADEL_AUDITOR
    COMMENT = 'Read-only on all tables including AUDIT_LOG. Masking applies. No write access.';

GRANT ROLE CITADEL_RISK_ANALYST       TO ROLE CITADEL_RISK_MANAGER;
GRANT ROLE CITADEL_RISK_MANAGER       TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT ROLE CITADEL_COMPLIANCE_OFFICER TO ROLE CITADEL_ADMIN;
GRANT ROLE CITADEL_AUDITOR            TO ROLE CITADEL_ADMIN;
GRANT ROLE CITADEL_ADMIN              TO ROLE SYSADMIN;
GRANT ROLE CITADEL_RISK_MANAGER       TO ROLE SYSADMIN;
GRANT ROLE CITADEL_COMPLIANCE_OFFICER TO ROLE SYSADMIN;
GRANT ROLE CITADEL_RISK_ANALYST       TO ROLE SYSADMIN;
GRANT ROLE CITADEL_AUDITOR            TO ROLE SYSADMIN;

GRANT USAGE ON WAREHOUSE CITADEL_WH TO ROLE CITADEL_ADMIN;
GRANT USAGE ON WAREHOUSE CITADEL_WH TO ROLE CITADEL_RISK_MANAGER;
GRANT USAGE ON WAREHOUSE CITADEL_WH TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT USAGE ON WAREHOUSE CITADEL_WH TO ROLE CITADEL_RISK_ANALYST;
GRANT USAGE ON WAREHOUSE CITADEL_WH TO ROLE CITADEL_AUDITOR;

GRANT USAGE ON DATABASE CITADEL_DB TO ROLE CITADEL_ADMIN;
GRANT USAGE ON DATABASE CITADEL_DB TO ROLE CITADEL_RISK_MANAGER;
GRANT USAGE ON DATABASE CITADEL_DB TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT USAGE ON DATABASE CITADEL_DB TO ROLE CITADEL_RISK_ANALYST;
GRANT USAGE ON DATABASE CITADEL_DB TO ROLE CITADEL_AUDITOR;

GRANT USAGE ON SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_ADMIN;
GRANT USAGE ON SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_RISK_MANAGER;
GRANT USAGE ON SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT USAGE ON SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_RISK_ANALYST;
GRANT USAGE ON SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_AUDITOR;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_ADMIN;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_ADMIN;

GRANT SELECT ON ALL TABLES IN SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT INSERT, UPDATE ON TABLE CITADEL_DB.RISK.REGULATORY_FILINGS TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT INSERT, UPDATE ON TABLE CITADEL_DB.RISK.CASE_ESCALATIONS   TO ROLE CITADEL_COMPLIANCE_OFFICER;

GRANT SELECT ON ALL TABLES IN SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_RISK_MANAGER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_RISK_MANAGER;
GRANT INSERT, UPDATE ON TABLE CITADEL_DB.RISK.CASE_ESCALATIONS TO ROLE CITADEL_RISK_MANAGER;
GRANT UPDATE ON TABLE CITADEL_DB.RISK.ACCOUNTS TO ROLE CITADEL_RISK_MANAGER;

GRANT SELECT ON TABLE CITADEL_DB.RISK.CUSTOMERS           TO ROLE CITADEL_RISK_ANALYST;
GRANT SELECT ON TABLE CITADEL_DB.RISK.ACCOUNTS            TO ROLE CITADEL_RISK_ANALYST;
GRANT SELECT ON TABLE CITADEL_DB.RISK.TRANSACTIONS        TO ROLE CITADEL_RISK_ANALYST;
GRANT SELECT ON TABLE CITADEL_DB.RISK.CREDIT_EXPOSURES    TO ROLE CITADEL_RISK_ANALYST;
GRANT SELECT ON TABLE CITADEL_DB.RISK.LIQUIDITY_POSITIONS TO ROLE CITADEL_RISK_ANALYST;
GRANT SELECT ON TABLE CITADEL_DB.RISK.CASE_ESCALATIONS    TO ROLE CITADEL_RISK_ANALYST;
-- REGULATORY_FILINGS and AUDIT_LOG: intentionally NOT granted to RISK_ANALYST

GRANT SELECT ON ALL TABLES IN SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_AUDITOR;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_AUDITOR;

-- =============================================================================
-- PHASE 2 — SECTION 6: RISK_FLAGS Table and Data
-- =============================================================================

CREATE OR REPLACE TABLE CITADEL_DB.RISK.RISK_FLAGS (
    flag_id             NUMBER          NOT NULL PRIMARY KEY AUTOINCREMENT,
    flag_domain         VARCHAR(20)     NOT NULL,  -- FRAUD | CREDIT | LIQUIDITY
    flag_type           VARCHAR(40)     NOT NULL,
    severity            VARCHAR(20)     NOT NULL,  -- LOW | MEDIUM | HIGH | CRITICAL
    flag_status         VARCHAR(20)     NOT NULL DEFAULT 'OPEN',
    customer_id         NUMBER,
    account_id          NUMBER,
    txn_id              VARCHAR(36),
    evidence_txn_ids    VARIANT,
    threshold_field     VARCHAR(60),
    threshold_value     NUMBER(14,4),
    threshold_limit     NUMBER(14,4),
    -- Regulatory citation — safe to quote directly in pitch and audit findings
    threshold_rationale VARCHAR(500),
    -- Pre-joined evidence for stored procedures (no extra joins needed)
    evidence_payload    VARIANT         NOT NULL,
    -- ASSUMPTION: flag_score scale: 0-40 low, 41-65 medium, 66-100 high (internal calibration)
    flag_score          NUMBER(5,2),
    created_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP(),
    updated_at          TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP(),
    actioned_by         VARCHAR(100),
    action_taken        VARCHAR(50)     -- SAR_FILED | ACCOUNT_FLAGGED | CASE_ESCALATED | DISMISSED
)
COMMENT = 'Unified risk signal queue — evidence_payload carries all context for stored proc actions';

-- Fraud flags from TRANSACTIONS
INSERT INTO CITADEL_DB.RISK.RISK_FLAGS (
    flag_domain, flag_type, severity, flag_status,
    customer_id, account_id, txn_id,
    threshold_field, threshold_value, threshold_limit, threshold_rationale,
    evidence_payload, flag_score
)
SELECT
    'FRAUD', t.fraud_pattern,
    CASE t.fraud_pattern
        WHEN 'VELOCITY'     THEN 'HIGH'
        WHEN 'STRUCTURING'  THEN 'HIGH'
        WHEN 'CROSS_BORDER' THEN 'CRITICAL'
        WHEN 'ROUND_NUMBER' THEN 'MEDIUM'
    END,
    COALESCE(t.review_status,'OPEN'),
    a.customer_id, t.account_id, t.txn_id,
    'flag_score', t.flag_score, 65.0,
    CASE t.fraud_pattern
        WHEN 'VELOCITY'
            THEN '5+ transactions on same account within 1 hour — rapid-movement indicator per FinCEN SAR field 35(a); internal velocity rule V-001'
        WHEN 'STRUCTURING'
            THEN 'Cash deposit $9,800-$9,999 — deliberate sub-threshold to evade BSA/FinCEN CTR requirement at $10,000 (31 CFR §1010.314; PMLA Schedule Rule 3(B))'
        WHEN 'CROSS_BORDER'
            THEN 'Wire to FATF grey/black-list jurisdiction — FATF Recommendation 19 (higher-risk countries); RBI Master Direction on KYC 2016 §38 enhanced due diligence required'
        WHEN 'ROUND_NUMBER'
            THEN 'Round-dollar transfer >$10,000 — structuring / trade-based money laundering indicator; FATF Typology Report on TBML 2020; internal rule R-007'
    END,
    OBJECT_CONSTRUCT(
        'customer_id', a.customer_id, 'account_id', t.account_id, 'txn_id', t.txn_id,
        'amount', t.amount, 'channel', t.channel, 'country_code', t.country_code,
        'fraud_pattern', t.fraud_pattern, 'flag_score', t.flag_score,
        'txn_ts', t.txn_ts::VARCHAR, 'counterparty_account', t.counterparty_account,
        'review_status', t.review_status
    ),
    t.flag_score
FROM CITADEL_DB.RISK.TRANSACTIONS t
JOIN CITADEL_DB.RISK.ACCOUNTS a ON a.account_id = t.account_id
WHERE t.is_flagged = TRUE;

-- Credit flags from CREDIT_EXPOSURES
INSERT INTO CITADEL_DB.RISK.RISK_FLAGS (
    flag_domain, flag_type, severity, flag_status,
    customer_id, account_id, txn_id,
    threshold_field, threshold_value, threshold_limit, threshold_rationale,
    evidence_payload, flag_score
)
SELECT
    'CREDIT',
    CASE WHEN a.npa_flag=TRUE THEN 'NPA'
         WHEN e.pd_score>0.35  THEN 'HIGH_PD_SEVERE'
         WHEN e.watch_list_flag THEN 'HIGH_PD'
         WHEN e.utilisation_pct>90 THEN 'HIGH_UTILISATION'
         ELSE 'WATCH_LIST' END,
    CASE WHEN e.pd_score>0.35 OR a.npa_flag=TRUE THEN 'CRITICAL'
         WHEN e.pd_score>0.20 THEN 'HIGH' ELSE 'MEDIUM' END,
    'OPEN',
    e.customer_id, e.account_id, NULL,
    CASE WHEN e.watch_list_flag THEN 'pd_score'
         WHEN e.utilisation_pct>90 THEN 'utilisation_pct' ELSE 'npa_flag' END,
    CASE WHEN e.watch_list_flag THEN e.pd_score
         WHEN e.utilisation_pct>90 THEN e.utilisation_pct ELSE 1 END,
    CASE WHEN e.watch_list_flag THEN 0.15 WHEN e.utilisation_pct>90 THEN 90 ELSE 0 END,
    CASE
        WHEN a.npa_flag=TRUE
            THEN 'Account classified NPA — RBI Master Circular on IRAC 2023; 90-day past due triggers Substandard; provisioning: 15% Substandard, 25-100% Doubtful, 100% Loss'
        WHEN e.pd_score>0.35
            THEN 'PD > 0.35 — severe sub-investment grade (CCC/D equivalent); Basel III ICAAP requires immediate board notification; IFRS 9 Stage 3 lifetime ECL provisioning mandatory'
        WHEN e.watch_list_flag
            THEN 'PD > 0.15 — sub-investment grade watch-list (BB-/B+ equivalent); Basel III ICAAP internal threshold; triggers quarterly enhanced credit review per Credit Policy §4.2'
        WHEN e.utilisation_pct>90
            THEN 'Credit utilisation >90% — internal credit policy breach (Credit Policy §6.1); potential liquidity stress signal; triggers covenant review and limit reassessment'
        ELSE 'Credit watch-list breach — internal monitoring threshold exceeded'
    END,
    OBJECT_CONSTRUCT(
        'customer_id', e.customer_id, 'account_id', e.account_id, 'exposure_id', e.exposure_id,
        'facility_type', e.facility_type, 'outstanding', e.outstanding, 'pd_score', e.pd_score,
        'lgd', e.lgd, 'ead', e.ead, 'expected_loss', e.expected_loss, 'rwa', e.rwa,
        'sector', e.sector, 'internal_rating', e.internal_rating,
        'utilisation_pct', e.utilisation_pct, 'npa_flag', a.npa_flag,
        'collateral_type', e.collateral_type
    ),
    ROUND(LEAST(100, CASE WHEN a.npa_flag=TRUE THEN 92 WHEN e.pd_score>0.35 THEN 88
         WHEN e.pd_score>0.20 THEN 72 WHEN e.pd_score>0.15 THEN 58 ELSE 50 END
         + (COALESCE(e.utilisation_pct,0)*0.08)), 2)
FROM CITADEL_DB.RISK.CREDIT_EXPOSURES e
LEFT JOIN CITADEL_DB.RISK.ACCOUNTS a ON a.account_id = e.account_id
WHERE e.watch_list_flag=TRUE OR e.utilisation_pct>90 OR a.npa_flag=TRUE;

-- Liquidity flags from LIQUIDITY_POSITIONS
INSERT INTO CITADEL_DB.RISK.RISK_FLAGS (
    flag_domain, flag_type, severity, flag_status,
    customer_id, account_id, txn_id,
    threshold_field, threshold_value, threshold_limit, threshold_rationale,
    evidence_payload, flag_score
)
SELECT
    'LIQUIDITY',
    CASE WHEN lcr_breach AND nsfr_breach THEN 'DUAL_BREACH'
         WHEN lcr_breach THEN 'LCR_BREACH' ELSE 'NSFR_BREACH' END,
    CASE WHEN lcr_ratio<0.80 OR (lcr_breach AND nsfr_breach) THEN 'CRITICAL'
         WHEN lcr_ratio<0.90 THEN 'HIGH' ELSE 'MEDIUM' END,
    'OPEN', NULL, NULL, NULL,
    CASE WHEN lcr_breach THEN 'lcr_ratio' ELSE 'nsfr_ratio' END,
    CASE WHEN lcr_breach THEN ROUND(lcr_ratio,4) ELSE ROUND(nsfr_ratio,4) END,
    1.0,
    CASE WHEN lcr_breach
            THEN 'LCR ratio < 100% — Basel III Art. 412 (CRR) minimum; requires notification to supervisory authority within 2 business days (BCBS Jan 2013 §415); internal intraday trigger at 95% (LIQ-001)'
         ELSE 'NSFR ratio < 100% — Basel III Art. 428b minimum stable funding ratio; effective globally since Jan 2021; triggers ALM committee escalation per internal policy LIQ-003'
    END,
    OBJECT_CONSTRUCT(
        'position_date', position_date::VARCHAR, 'tenor_bucket', tenor_bucket,
        'lcr_ratio', ROUND(lcr_ratio,4), 'lcr_numerator', lcr_numerator,
        'lcr_denominator', lcr_denominator, 'nsfr_ratio', ROUND(nsfr_ratio,4),
        'hqla_level1', hqla_level1, 'hqla_level2', hqla_level2,
        'inflow', inflow, 'outflow', outflow, 'stress_scenario', stress_scenario,
        'lcr_breach', lcr_breach, 'nsfr_breach', nsfr_breach
    ),
    ROUND(CASE WHEN lcr_ratio<0.80 THEN 95 WHEN lcr_ratio<0.90 THEN 82
               WHEN lcr_ratio<1.00 THEN 67 ELSE 58 END, 2)
FROM CITADEL_DB.RISK.LIQUIDITY_POSITIONS
WHERE lcr_breach=TRUE OR nsfr_breach=TRUE;

-- RISK_FLAGS grants
GRANT SELECT ON TABLE CITADEL_DB.RISK.RISK_FLAGS TO ROLE CITADEL_RISK_ANALYST;
GRANT SELECT ON TABLE CITADEL_DB.RISK.RISK_FLAGS TO ROLE CITADEL_AUDITOR;

-- =============================================================================
-- PHASE 2 — SECTION 7: Internal Stage + POLICY_DOCS Table and Data
-- =============================================================================

CREATE STAGE IF NOT EXISTS CITADEL_DB.RISK.CITADEL_STAGE
    COMMENT = 'Semantic model files, policy documents, and app assets for Citadel';

CREATE OR REPLACE TABLE CITADEL_DB.RISK.POLICY_DOCS (
    doc_id         NUMBER          NOT NULL PRIMARY KEY,
    title          VARCHAR(300),
    doc_type       VARCHAR(50),     -- REGULATION | INTERNAL_POLICY | SAR_NARRATIVE | AUDIT_FINDING | FAQ
    source         VARCHAR(120),
    effective_date DATE,
    content        VARCHAR(16000),
    tags           VARIANT,
    created_at     TIMESTAMP_LTZ   DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Regulatory policy documents and case narratives indexed by Cortex Search';

INSERT INTO CITADEL_DB.RISK.POLICY_DOCS (doc_id, title, doc_type, source, effective_date, content, tags)
SELECT 1,'Basel III Liquidity Coverage Ratio — Summary of Requirements','REGULATION',
'Basel Committee on Banking Supervision (BCBS), January 2013','2015-01-01'::DATE,
'The Liquidity Coverage Ratio (LCR) requires banks to hold sufficient High Quality Liquid Assets (HQLA) to survive a 30-day stress scenario. The LCR is defined as Total HQLA divided by Total Net Cash Outflows over the 30-day stress period. The minimum LCR is 100%.

HQLA are divided into Level 1 (cash, central bank reserves, 0% risk-weight sovereign debt) and Level 2 assets (Level 2A: covered bonds, sovereign debt with 20% risk weight; Level 2B: corporate bonds, equities). Level 2 assets are subject to haircuts and caps.

Breach Consequences: When a bank LCR falls below the 100% minimum, it must notify the supervisory authority within two business days (Article 415, CRR). Banks must submit a remediation plan outlining steps to restore compliance.

Internal Monitoring: Banks are required to monitor intraday liquidity positions and report to their ALM committee daily. An internal early-warning threshold of 95% LCR is recommended to allow pre-emptive action.

Key Formula: LCR = HQLA / max(Total Net Cash Outflows, 25% x Total Gross Cash Outflows). Supervisory Reporting: Banks must report LCR to regulators monthly.',
PARSE_JSON('["LCR","Basel III","liquidity","HQLA","regulatory minimum","Art 412","BCBS"]')
UNION ALL
SELECT 2,'Basel III Net Stable Funding Ratio — Summary','REGULATION',
'Basel Committee on Banking Supervision (BCBS), October 2014','2021-01-01'::DATE,
'The Net Stable Funding Ratio (NSFR) requires banks to maintain a stable funding profile relative to their assets. NSFR = Available Stable Funding (ASF) / Required Stable Funding (RSF). Minimum NSFR is 100%.

ASF includes equity, long-term debt (>1 year), retail deposits (stable = 90-95% ASF factor). Demand deposits and overnight funding from financial institutions receive a 0% ASF factor.

RSF depends on asset liquidity: HQLA Level 1 requires 0-5% RSF, retail mortgages 65-85%, unsecured corporate loans with maturity >1 year 65-85%.

Breach of NSFR minimum (< 100%) triggers immediate notification to supervisory authority and remediation requirements under Article 428b CRR2. Internal Policy LIQ-003: ALM Committee escalation required at 103% early-warning threshold.',
PARSE_JSON('["NSFR","Basel III","stable funding","ASF","RSF","Art 428b","structural liquidity"]')
UNION ALL
SELECT 3,'FinCEN — Structuring and Currency Transaction Report (CTR) Requirements','REGULATION',
'Financial Crimes Enforcement Network (FinCEN), 31 CFR Parts 1010-1021','1996-04-01'::DATE,
'Under the Bank Secrecy Act (BSA), financial institutions must file a Currency Transaction Report (CTR) for any cash transaction exceeding $10,000. Structuring — deliberately breaking up transactions to stay below $10,000 — is a federal crime under 31 USC 5324.

Structuring Indicators: Multiple cash deposits of $9,000-$9,999 over short periods; deposits just below round thresholds ($9,800, $9,950); use of multiple branches to split transactions.

CTR Filing: Required within 15 days of the transaction. Financial institutions may not tip off the subject. Willful failure to file: civil penalties up to $25,000 per violation.

Suspicious Activity Reports (SARs): If structuring is suspected, a SAR must be filed within 30 days of detection. SAR narrative must describe the pattern, identify subjects if known, and explain why the activity is suspicious. Disclosure to subjects prohibited (31 USC 5318(g)(2)). FinCEN SAR Field 35(a) references Structuring/Smurfing.',
PARSE_JSON('["structuring","CTR","SAR","FinCEN","BSA","31 CFR 1010.314","cash threshold","smurfing"]')
UNION ALL
SELECT 4,'FATF Recommendations 12, 16, and 19 — PEP, Wire Transfers, and High-Risk Countries','REGULATION',
'Financial Action Task Force (FATF), updated 2023','2012-02-01'::DATE,
'Recommendation 12 — Politically Exposed Persons (PEPs): Financial institutions must apply enhanced due diligence (EDD) to PEPs. Requirements: (a) risk management systems to identify PEPs; (b) senior management approval; (c) establish source of wealth and funds; (d) enhanced ongoing monitoring.

Recommendation 16 — Wire Transfers: For cross-border wire transfers of USD/EUR 1,000 or more, complete originator and beneficiary information must accompany the transfer. Intermediary institutions must pass through all originator information.

Recommendation 19 — Higher-Risk Countries: Apply EDD to customers and transactions involving FATF grey/black-list countries. Grey-list 2024 includes: Myanmar (MMR), Iran (IRN), North Korea (PRK), Syria (SYR), Yemen (YEM), Libya (LBY), Sudan (SDN). Black list: Iran, North Korea.

FATF TBML Typology Report: Round-dollar amounts and rapid fund movement through multiple jurisdictions are common trade-based money laundering red flags.',
PARSE_JSON('["FATF","PEP","wire transfer","high risk country","Recommendation 12","Recommendation 16","Recommendation 19","grey list","EDD"]')
UNION ALL
SELECT 5,'RBI Master Circular — Income Recognition, Asset Classification and Provisioning (IRAC) 2023','REGULATION',
'Reserve Bank of India, Master Circular DBR.No.BP.BC.1/21.04.048/2015-16 (updated 2023)','2023-04-01'::DATE,
'IRAC norms govern how Indian banks classify loans and recognize income. NPAs are classified based on days past due (DPD).

NPA Classification: A loan is NPA when interest or principal is overdue for more than 90 days (term loans), or cash credit remains out of order for 90 days.

Sub-categories:
- Substandard: NPA up to 12 months. Provisioning: 15% secured, 25% unsecured.
- Doubtful: NPA over 12 months. Provisioning: 25-100% depending on age and collateral.
- Loss Asset: Full provisioning (100%) required.

Special Mention Accounts (SMA): SMA-0 (1-30 DPD), SMA-1 (31-60 DPD), SMA-2 (61-90 DPD). SMA-2 requires enhanced monitoring and pre-NPA restructuring review.

Banks must submit NPA data to RBI in CRILC format. Divergence in NPA classification identified during RBI inspection must be publicly disclosed.',
PARSE_JSON('["NPA","RBI","IRAC","provisioning","Substandard","Doubtful","Loss Asset","90 day","SMA","asset classification"]')
UNION ALL
SELECT 6,'SAR Narrative — Case Note: Suspected Structuring and Layering (Case CASE-000042)','SAR_NARRATIVE',
'Citadel Bank Compliance Department — Internal Case File','2026-08-15'::DATE,
'FILING TYPE: Suspicious Activity Report (SAR) | CASE: CASE-000042 | OFFICER: sarah.chen@citadel.bank | AMOUNT: $127,450

ACTIVITY: Account ACC0000000234 exhibited 14 cash deposits over 21 days (July 25 - August 14, 2026), each $9,750-$9,950 — all below the $10,000 CTR threshold. Total: $127,450.

Customer stated deposits were wholesale goods proceeds. EDD revealed stated annual revenue ($180,000) is inconsistent with cash volume ($127,450 in 21 days). Customer could not produce invoices.

SUSPICIOUS ELEMENTS:
1. All transactions deliberately below $10,000 — structuring (31 CFR 1010.314)
2. Transactions spread across 3 branches to avoid single-branch scrutiny
3. Account previously identified as SMA-1 (31-60 DPD overdue on associated loan)
4. Customer holds PEP-adjacent designation (former government procurement officer, retired 2023)
5. Within 48 hours, $95,000 wired to offshore account in Labuan (Malaysia)

RISK ASSESSMENT: HIGH (flag_score: 87/100)
DISPOSITION: SAR filed with FinCEN on August 15, 2026. Account flagged for enhanced monitoring.',
PARSE_JSON('["SAR","structuring","layering","FinCEN","PEP","offshore transfer","case note","high risk","cash deposits"]')
UNION ALL
SELECT 7,'Audit Finding — Concentration Risk in Real Estate Sector (Q2 2026)','AUDIT_FINDING',
'Citadel Bank Internal Audit Department, Quarterly Credit Review','2026-07-01'::DATE,
'AUDIT FINDING REF: IAD-CR-2026-Q2-007 | SEVERITY: HIGH | DATE: July 1, 2026

FINDING: 38% of total credit outstanding (~$240M) is in real estate sector, exceeding the internal single-sector concentration limit of 25% (Credit Policy 7.3).

EVIDENCE: 114 real estate facilities, $238.5M outstanding, average PD 0.19 (above watch-list threshold 0.15). 32 facilities on credit watch-list. RWA: $178M (28% of total $632M). Expected Loss: $8.2M.

REGULATORY CONTEXT: Basel III Pillar 2 requires additional capital for concentration risk. RBI Circular requires reporting sectoral exposure breaches to the Board Risk Committee.

MANAGEMENT RESPONSE REQUIRED:
1. Reduce new real estate originations until concentration falls below 25%
2. Stress test portfolio under 20% property value decline scenario
3. Present remediation plan to Board Risk Committee

REPEAT FINDING: First raised Q4 2025. Corrective action not yet implemented.',
PARSE_JSON('["audit finding","concentration risk","real estate","credit policy","Basel III Pillar 2","RWA","ICAAP","watch list"]')
UNION ALL
SELECT 8,'Internal AML Policy — SAR Filing Thresholds and Timelines (AML-POL-003)','INTERNAL_POLICY',
'Citadel Bank Compliance — AML Policy Library','2025-01-15'::DATE,
'POLICY: AML-POL-003 | VERSION: 3.2 | EFFECTIVE: January 15, 2025 | OWNER: Chief Compliance Officer

FILING THRESHOLDS: Mandatory SAR: suspicious transactions $5,000+. Voluntary: below $5,000. CTR Supplement: structuring below $10,000 requires both CTR and SAR.

FILING TIMELINES: Standard: 30 calendar days. Extended (no subject): 60 days. Continuing activity: SAR every 90 days. Emergency (terrorist financing): notify FinCEN immediately.

APPROVAL: < $25,000: Compliance Officer. $25,000-$100,000: Senior Compliance Manager. > $100,000 or PEP/sanctions-linked: Chief Compliance Officer.

TIPPING OFF PROHIBITION: Under 31 USC 5318(g)(2), no employee may disclose the existence of a SAR to any person involved in the suspicious activity. Violation is a federal crime.',
PARSE_JSON('["SAR","AML policy","FinCEN","filing threshold","30 days","tipping off","BSA","PMLA","CTR"]')
UNION ALL
SELECT 9,'FAQ — STR vs SAR: When to File Each Report','FAQ',
'Citadel Bank Compliance — Training Materials','2025-03-01'::DATE,
'Q1: What is the difference between a SAR and an STR?
A: Same concept, different jurisdiction terminology. US: SAR (FinCEN). India: STR filed with FIU-IND under PMLA 2002. UK: SAR filed with National Crime Agency (NCA) under Proceeds of Crime Act 2002.

Q2: What triggers a SAR/STR in Citadel?
A: Four automated RISK_FLAGS rules: VELOCITY (5+ txns/hr same account), STRUCTURING ($9,800-$9,999 cash), CROSS_BORDER (wire to FATF grey/black-list country), ROUND_NUMBER (round-dollar >$10K). flag_score > 75 requires mandatory review within 24 hours.

Q3: Does a SAR guarantee law enforcement action?
A: No. SAR is an intelligence report. Banks are protected by BSA safe harbor for good-faith filings.

Q4: Can a customer be told their SAR was filed?
A: No. Tipping-off prohibition (31 USC 5318(g)(2), PMLA Section 13) — criminal offense.

Q5: CTR vs SAR?
A: CTR is objective (any cash >$10,000). SAR is subjective (reasonable grounds to suspect ML/TF).',
PARSE_JSON('["SAR","STR","CTR","FAQ","FinCEN","FIU-IND","PMLA","NCA","tipping off","suspicious transaction"]')
UNION ALL
SELECT 10,'BCBS 239 — Principles for Effective Risk Data Aggregation and Risk Reporting','REGULATION',
'Basel Committee on Banking Supervision, January 2013 (effective 2016)','2016-01-01'::DATE,
'BCBS 239 establishes 14 principles for risk data aggregation and risk reporting at systemically important banks.

Principle 2 — Data Architecture: Banks must maintain strong data architecture supporting risk data aggregation during normal times and stress. Risk data must be reconcilable and traceable to source systems. The RISK_FLAGS evidence_payload VARIANT implements this by capturing a complete source snapshot at detection time.

Principle 3 — Accuracy and Integrity: Banks must generate accurate and reliable risk data for both normal and stress reporting.

Principle 6 — Adaptability: Banks must generate aggregate risk data for broad on-demand reporting. The CITADEL_RISK_INTELLIGENCE semantic view and Cortex Analyst implement this via natural-language queries.

Principle 9 — Supervisory Review: Internal audit findings (e.g. IAD-CR-2026-Q2-007) should reference BCBS 239 compliance status.

Banks failing BCBS 239 compliance face enhanced supervisory scrutiny and Pillar 2 capital add-ons. The AUDIT_LOG table directly supports Principle 2 data lineage requirements.',
PARSE_JSON('["BCBS 239","risk data aggregation","risk reporting","G-SIB","D-SIB","data architecture","audit trail","Principle 2","Principle 3"]');

-- POLICY_DOCS grants
GRANT SELECT ON TABLE CITADEL_DB.RISK.POLICY_DOCS TO ROLE CITADEL_RISK_ANALYST;
GRANT SELECT ON TABLE CITADEL_DB.RISK.POLICY_DOCS TO ROLE CITADEL_AUDITOR;

-- =============================================================================
-- PHASE 2 — SECTION 8: Cortex Search Service
-- =============================================================================

CREATE OR REPLACE CORTEX SEARCH SERVICE CITADEL_DB.RISK.CITADEL_SEARCH_SVC
    ON content
    ATTRIBUTES title, doc_type, source, effective_date
    WAREHOUSE = CITADEL_WH
    TARGET_LAG = '1 hour'
    AS (
        SELECT
            doc_id,
            title,
            doc_type,
            source,
            effective_date::VARCHAR   AS effective_date,
            content,
            tags::VARCHAR             AS tags_str
        FROM CITADEL_DB.RISK.POLICY_DOCS
    );

-- Search service grants
GRANT USAGE ON CORTEX SEARCH SERVICE CITADEL_DB.RISK.CITADEL_SEARCH_SVC TO ROLE CITADEL_RISK_ANALYST;
GRANT USAGE ON CORTEX SEARCH SERVICE CITADEL_DB.RISK.CITADEL_SEARCH_SVC TO ROLE CITADEL_RISK_MANAGER;
GRANT USAGE ON CORTEX SEARCH SERVICE CITADEL_DB.RISK.CITADEL_SEARCH_SVC TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT USAGE ON CORTEX SEARCH SERVICE CITADEL_DB.RISK.CITADEL_SEARCH_SVC TO ROLE CITADEL_AUDITOR;

-- =============================================================================

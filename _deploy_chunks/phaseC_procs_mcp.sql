-- STRETCH — ACTION STORED PROCEDURES + MCP SERVERS + OAUTH (COMPLETE)
-- All procs: EXECUTE AS CALLER — RBAC masking/row policies still apply inside.
-- ASSUMPTION: OBJECT_CONSTRUCT in VALUES clauses not supported in Snowflake SQL
--   stored procedures; use INSERT...SELECT FROM (SELECT 1) instead.
-- ASSUMPTION: Snowflake uses USAGE not EXECUTE for stored procedure grants.
-- =============================================================================

CREATE OR REPLACE PROCEDURE CITADEL_DB.RISK.FILE_SAR_DRAFT(p_flag_id NUMBER, p_notes VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER DEFAULT 0; v_customer_id NUMBER DEFAULT 0; v_account_id NUMBER DEFAULT 0;
    v_flag_type VARCHAR DEFAULT ''; v_rationale VARCHAR DEFAULT ''; v_score NUMBER DEFAULT 0;
    v_new_id NUMBER DEFAULT 0; v_actor VARCHAR DEFAULT ''; v_role VARCHAR DEFAULT '';
    v_narrative VARCHAR DEFAULT ''; v_ref_case VARCHAR DEFAULT ''; v_summary VARCHAR DEFAULT '';
    v_notes_part VARCHAR DEFAULT '';
BEGIN
    IF (CURRENT_ROLE() NOT IN ('CITADEL_COMPLIANCE_OFFICER','CITADEL_ADMIN','SYSADMIN','ACCOUNTADMIN')) THEN
        RETURN OBJECT_CONSTRUCT('error', 'CITADEL_COMPLIANCE_OFFICER or higher required.');
    END IF;
    SELECT COUNT(*) INTO :v_count FROM CITADEL_DB.RISK.RISK_FLAGS
    WHERE flag_id = :p_flag_id AND flag_status NOT IN ('ACTIONED','DISMISSED');
    IF (:v_count = 0) THEN RETURN OBJECT_CONSTRUCT('error','Flag not found or already actioned'); END IF;
    SELECT customer_id, COALESCE(account_id,0), flag_type,
           COALESCE(threshold_rationale,''), COALESCE(flag_score,0)
    INTO   :v_customer_id, :v_account_id, :v_flag_type, :v_rationale, :v_score
    FROM   CITADEL_DB.RISK.RISK_FLAGS WHERE flag_id = :p_flag_id;
    SELECT CURRENT_USER() INTO :v_actor FROM (SELECT 1);
    SELECT CURRENT_ROLE() INTO :v_role  FROM (SELECT 1);
    SELECT CASE WHEN :p_notes IS NOT NULL THEN '. Notes: ' || :p_notes ELSE '' END INTO :v_notes_part FROM (SELECT 1);
    SELECT 'SAR drafted from RISK_FLAGS flag_id=' || :p_flag_id::VARCHAR || '. Flag: ' || :v_flag_type
        || '. Regulatory basis: ' || :v_rationale || :v_notes_part INTO :v_narrative FROM (SELECT 1);
    SELECT 'SAR-FLAG-' || :p_flag_id::VARCHAR INTO :v_ref_case FROM (SELECT 1);
    SELECT COALESCE(MAX(filing_id),0)+1 INTO :v_new_id FROM CITADEL_DB.RISK.REGULATORY_FILINGS;
    INSERT INTO CITADEL_DB.RISK.REGULATORY_FILINGS (filing_id, customer_id, account_id, filing_type,
        filing_status, filing_date, filed_by, assigned_to, narrative, risk_score, outcome, reference_case_id)
    VALUES (:v_new_id, :v_customer_id, CASE WHEN :v_account_id=0 THEN NULL ELSE :v_account_id END,
        'SAR','DRAFT',CURRENT_DATE(),:v_actor,:v_actor,:v_narrative,:v_score,'FILED',:v_ref_case);
    UPDATE CITADEL_DB.RISK.RISK_FLAGS SET flag_status='ACTIONED', action_taken='SAR_FILED',
        actioned_by=:v_actor, updated_at=CURRENT_TIMESTAMP() WHERE flag_id = :p_flag_id;
    SELECT 'SAR filed from flag_id=' || :p_flag_id::VARCHAR || ' filing_id=' || :v_new_id::VARCHAR
    INTO :v_summary FROM (SELECT 1);
    INSERT INTO CITADEL_DB.RISK.AUDIT_LOG (actor_user, actor_role, action_type, object_type,
        object_id, after_state, change_summary)
    SELECT :v_actor, :v_role, 'FILE_SAR', 'FILING', :v_new_id::VARCHAR,
        OBJECT_CONSTRUCT('filing_id',:v_new_id,'flag_id',:p_flag_id), :v_summary FROM (SELECT 1);
    RETURN OBJECT_CONSTRUCT('filing_id',:v_new_id,'status','DRAFT','flag_id',:p_flag_id,'message','SAR draft created.');
END;
$$;

CREATE OR REPLACE PROCEDURE CITADEL_DB.RISK.FLAG_ACCOUNT(p_account_id NUMBER, p_reason VARCHAR, p_linked_flag_id NUMBER)
RETURNS VARIANT LANGUAGE SQL EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER DEFAULT 0; v_customer_id NUMBER DEFAULT 0; v_before_st VARCHAR DEFAULT '';
    v_new_case_id NUMBER DEFAULT 0; v_actor VARCHAR DEFAULT ''; v_role VARCHAR DEFAULT '';
    v_notes_txt VARCHAR DEFAULT ''; v_summary VARCHAR DEFAULT '';
BEGIN
    IF (CURRENT_ROLE() NOT IN ('CITADEL_RISK_MANAGER','CITADEL_COMPLIANCE_OFFICER','CITADEL_ADMIN','SYSADMIN','ACCOUNTADMIN')) THEN
        RETURN OBJECT_CONSTRUCT('error', 'CITADEL_RISK_MANAGER or higher required.');
    END IF;
    SELECT COUNT(*) INTO :v_count FROM CITADEL_DB.RISK.ACCOUNTS WHERE account_id = :p_account_id;
    IF (:v_count = 0) THEN RETURN OBJECT_CONSTRUCT('error','Account not found'); END IF;
    SELECT status, customer_id INTO :v_before_st, :v_customer_id FROM CITADEL_DB.RISK.ACCOUNTS WHERE account_id = :p_account_id;
    SELECT CURRENT_USER() INTO :v_actor FROM (SELECT 1);
    SELECT CURRENT_ROLE() INTO :v_role  FROM (SELECT 1);
    SELECT 'Account frozen. Reason: ' || :p_reason INTO :v_notes_txt FROM (SELECT 1);
    SELECT COALESCE(MAX(case_id),0)+1 INTO :v_new_case_id FROM CITADEL_DB.RISK.CASE_ESCALATIONS;
    UPDATE CITADEL_DB.RISK.ACCOUNTS SET status = 'FROZEN' WHERE account_id = :p_account_id;
    INSERT INTO CITADEL_DB.RISK.CASE_ESCALATIONS (case_id, customer_id, account_id, linked_filing_id,
        case_type, severity, status, assigned_to, created_by, created_at, updated_at, resolution_notes)
    VALUES (:v_new_case_id, :v_customer_id, :p_account_id,
        CASE WHEN :p_linked_flag_id=0 THEN NULL ELSE :p_linked_flag_id END,
        'FRAUD','HIGH','OPEN',:v_actor,:v_actor,CURRENT_TIMESTAMP(),CURRENT_TIMESTAMP(),:v_notes_txt);
    SELECT 'Account ' || :p_account_id::VARCHAR || ' frozen. Case ' || :v_new_case_id::VARCHAR INTO :v_summary FROM (SELECT 1);
    INSERT INTO CITADEL_DB.RISK.AUDIT_LOG (actor_user, actor_role, action_type, object_type, object_id,
        before_state, after_state, change_summary)
    SELECT :v_actor, :v_role, 'FLAG_ACCOUNT', 'ACCOUNT', :p_account_id::VARCHAR,
        OBJECT_CONSTRUCT('status',:v_before_st), OBJECT_CONSTRUCT('status','FROZEN','reason',:p_reason), :v_summary FROM (SELECT 1);
    RETURN OBJECT_CONSTRUCT('account_id',:p_account_id,'new_status','FROZEN','case_id',:v_new_case_id,'message','Account flagged and case opened.');
END;
$$;

CREATE OR REPLACE PROCEDURE CITADEL_DB.RISK.ESCALATE_CASE(p_case_id NUMBER, p_escalate_to VARCHAR, p_notes VARCHAR)
RETURNS VARIANT LANGUAGE SQL EXECUTE AS CALLER
AS
$$
DECLARE
    v_count NUMBER DEFAULT 0; v_before_st VARCHAR DEFAULT ''; v_before_asg VARCHAR DEFAULT '';
    v_actor VARCHAR DEFAULT ''; v_role VARCHAR DEFAULT ''; v_notes_sfx VARCHAR DEFAULT ''; v_summary VARCHAR DEFAULT '';
BEGIN
    IF (CURRENT_ROLE() NOT IN ('CITADEL_RISK_MANAGER','CITADEL_COMPLIANCE_OFFICER','CITADEL_ADMIN','SYSADMIN','ACCOUNTADMIN')) THEN
        RETURN OBJECT_CONSTRUCT('error', 'CITADEL_RISK_MANAGER or higher required.');
    END IF;
    SELECT COUNT(*) INTO :v_count FROM CITADEL_DB.RISK.CASE_ESCALATIONS
    WHERE case_id = :p_case_id AND status NOT IN ('RESOLVED','CLOSED');
    IF (:v_count = 0) THEN RETURN OBJECT_CONSTRUCT('error','Case not found or already resolved/closed'); END IF;
    SELECT COALESCE(status,''), COALESCE(assigned_to,'') INTO :v_before_st, :v_before_asg
    FROM CITADEL_DB.RISK.CASE_ESCALATIONS WHERE case_id = :p_case_id;
    SELECT CURRENT_USER() INTO :v_actor FROM (SELECT 1);
    SELECT CURRENT_ROLE() INTO :v_role  FROM (SELECT 1);
    SELECT CASE WHEN :p_notes IS NOT NULL THEN ': ' || :p_notes ELSE '' END INTO :v_notes_sfx FROM (SELECT 1);
    SELECT 'Case ' || :p_case_id::VARCHAR || ' escalated to ' || :p_escalate_to INTO :v_summary FROM (SELECT 1);
    UPDATE CITADEL_DB.RISK.CASE_ESCALATIONS
    SET status='ESCALATED', escalated_to=:p_escalate_to, updated_at=CURRENT_TIMESTAMP(),
        resolution_notes=COALESCE(resolution_notes,'')||' | Escalated by '||:v_actor||' to '||:p_escalate_to||:v_notes_sfx
    WHERE case_id = :p_case_id;
    INSERT INTO CITADEL_DB.RISK.AUDIT_LOG (actor_user, actor_role, action_type, object_type, object_id,
        before_state, after_state, change_summary)
    SELECT :v_actor, :v_role, 'ESCALATE_CASE', 'CASE', :p_case_id::VARCHAR,
        OBJECT_CONSTRUCT('status',:v_before_st,'assigned_to',:v_before_asg),
        OBJECT_CONSTRUCT('status','ESCALATED','escalated_to',:p_escalate_to), :v_summary FROM (SELECT 1);
    RETURN OBJECT_CONSTRUCT('case_id',:p_case_id,'new_status','ESCALATED','escalated_to',:p_escalate_to,'message','Case escalated.');
END;
$$;

-- Procedure access grants (USAGE = right to call in Snowflake)
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FILE_SAR_DRAFT(NUMBER, VARCHAR)   TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FLAG_ACCOUNT(NUMBER, VARCHAR, NUMBER) TO ROLE CITADEL_RISK_MANAGER;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FLAG_ACCOUNT(NUMBER, VARCHAR, NUMBER) TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.ESCALATE_CASE(NUMBER, VARCHAR, VARCHAR) TO ROLE CITADEL_RISK_MANAGER;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.ESCALATE_CASE(NUMBER, VARCHAR, VARCHAR) TO ROLE CITADEL_COMPLIANCE_OFFICER;

-- =============================================================================
-- STRETCH — MCP SERVERS
-- Two servers: AI gateway (read) + action server (write/restricted)
-- =============================================================================

CREATE OR REPLACE MCP SERVER CITADEL_DB.RISK.CITADEL_AGENT_MCP_SERVER
FROM SPECIFICATION $$
tools:
  - title: "CITADEL Risk Intelligence Copilot"
    name: "citadel_agent"
    type: "CORTEX_AGENT_RUN"
    identifier: "CITADEL_DB.RISK.CITADEL_AGENT"
    description: >
      Governed AI copilot for banking risk and AML compliance. Answers questions about
      fraud flags (VELOCITY, STRUCTURING, CROSS_BORDER, ROUND_NUMBER), credit watch-list
      (PD > 0.15, Basel III ICAAP), liquidity breaches (LCR < 100%, Basel III Art. 412),
      and regulatory obligations (FATF, FinCEN, RBI). Always cites regulations.
$$;

CREATE OR REPLACE MCP SERVER CITADEL_DB.RISK.CITADEL_ACTIONS_MCP_SERVER
FROM SPECIFICATION $$
tools:
  - title: "File SAR Draft"
    name: "file_sar_draft"
    identifier: "CITADEL_DB.RISK.FILE_SAR_DRAFT"
    type: "GENERIC"
    description: "File a SAR draft from an open RISK_FLAGS entry. Requires CITADEL_COMPLIANCE_OFFICER."
    config:
      type: "procedure"
      warehouse: "CITADEL_WH"
      query_timeout: 120
      input_schema:
        type: "object"
        properties:
          p_flag_id: { type: "number", description: "flag_id from RISK_FLAGS" }
          p_notes:   { type: "string", description: "Optional analyst notes" }
        required: ["p_flag_id"]
  - title: "Flag Account for Review"
    name: "flag_account"
    identifier: "CITADEL_DB.RISK.FLAG_ACCOUNT"
    type: "GENERIC"
    description: "Freeze a bank account and open a case. Requires CITADEL_RISK_MANAGER."
    config:
      type: "procedure"
      warehouse: "CITADEL_WH"
      query_timeout: 60
      input_schema:
        type: "object"
        properties:
          p_account_id:    { type: "number", description: "account_id to freeze" }
          p_reason:        { type: "string", description: "Reason for flagging" }
          p_linked_flag_id: { type: "number", description: "Linked flag_id (use 0 if none)" }
        required: ["p_account_id","p_reason"]
  - title: "Escalate Case"
    name: "escalate_case"
    identifier: "CITADEL_DB.RISK.ESCALATE_CASE"
    type: "GENERIC"
    description: "Escalate a case to a named officer. Requires CITADEL_RISK_MANAGER."
    config:
      type: "procedure"
      warehouse: "CITADEL_WH"
      query_timeout: 60
      input_schema:
        type: "object"
        properties:
          p_case_id:     { type: "number", description: "case_id to escalate" }
          p_escalate_to: { type: "string", description: "Target officer email/username" }
          p_notes:       { type: "string", description: "Optional escalation notes" }
        required: ["p_case_id","p_escalate_to"]
$$;

-- =============================================================================
-- STRETCH — MCP RBAC + OAuth
-- =============================================================================

CREATE ROLE IF NOT EXISTS CITADEL_MCP_READER_ROLE COMMENT = 'MCP read-only AI gateway';
CREATE ROLE IF NOT EXISTS CITADEL_MCP_ACTION_ROLE  COMMENT = 'MCP write: action procs';
GRANT ROLE CITADEL_MCP_READER_ROLE TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT ROLE CITADEL_MCP_READER_ROLE TO ROLE CITADEL_RISK_ANALYST;
GRANT ROLE CITADEL_MCP_READER_ROLE TO ROLE CITADEL_AUDITOR;
GRANT ROLE CITADEL_MCP_ACTION_ROLE  TO ROLE CITADEL_RISK_MANAGER;
GRANT ROLE CITADEL_MCP_ACTION_ROLE  TO ROLE CITADEL_COMPLIANCE_OFFICER;
GRANT ROLE CITADEL_MCP_READER_ROLE  TO ROLE SYSADMIN;
GRANT ROLE CITADEL_MCP_ACTION_ROLE  TO ROLE SYSADMIN;

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON WAREHOUSE CITADEL_WH TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON DATABASE CITADEL_DB TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON SCHEMA CITADEL_DB.RISK TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON MCP SERVER CITADEL_DB.RISK.CITADEL_AGENT_MCP_SERVER TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON AGENT CITADEL_DB.RISK.CITADEL_AGENT TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON SEMANTIC VIEW CITADEL_DB.RISK.CITADEL_RISK_INTELLIGENCE TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON CORTEX SEARCH SERVICE CITADEL_DB.RISK.CITADEL_SEARCH_SVC TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON TABLE CITADEL_DB.RISK.RISK_FLAGS TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON TABLE CITADEL_DB.RISK.TRANSACTIONS TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON TABLE CITADEL_DB.RISK.ACCOUNTS TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON TABLE CITADEL_DB.RISK.CUSTOMERS TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON TABLE CITADEL_DB.RISK.CREDIT_EXPOSURES TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON TABLE CITADEL_DB.RISK.LIQUIDITY_POSITIONS TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON TABLE CITADEL_DB.RISK.POLICY_DOCS TO ROLE CITADEL_MCP_READER_ROLE;

GRANT USAGE ON MCP SERVER CITADEL_DB.RISK.CITADEL_ACTIONS_MCP_SERVER TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FILE_SAR_DRAFT(NUMBER, VARCHAR) TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FLAG_ACCOUNT(NUMBER, VARCHAR, NUMBER) TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.ESCALATE_CASE(NUMBER, VARCHAR, VARCHAR) TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT INSERT, UPDATE ON TABLE CITADEL_DB.RISK.REGULATORY_FILINGS TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT INSERT, UPDATE ON TABLE CITADEL_DB.RISK.CASE_ESCALATIONS   TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT UPDATE          ON TABLE CITADEL_DB.RISK.RISK_FLAGS         TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT UPDATE          ON TABLE CITADEL_DB.RISK.ACCOUNTS           TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT INSERT          ON TABLE CITADEL_DB.RISK.AUDIT_LOG          TO ROLE CITADEL_MCP_ACTION_ROLE;

-- OAuth security integrations (run SYSTEM$SHOW_OAUTH_CLIENT_SECRETS after creation)
-- =============================================================================
-- MCP TOOL GRANTS  (CRITICAL — do not omit)
-- Snowflake rule: USAGE on an MCP server does NOT grant access to its tools.
-- Each tool needs its own grant. Missing these produces HTTP 200 with an error
-- in the RESPONSE BODY (not a 401), which is easy to misdiagnose as transport.
-- All four grants below were missing on first deploy and broke 3 of 4 tools.
-- =============================================================================

-- AI Gateway: the agent object itself. Without this, tools/call returns
--   "The agent does not exist or access is not authorized for the current role"
GRANT USAGE ON AGENT CITADEL_DB.RISK.CITADEL_AGENT
    TO ROLE CITADEL_MCP_READER_ROLE;

-- Action Server: one grant per procedure, signature-qualified.
-- ESCALATE_CASE was granted on first deploy; the other two were not.
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FILE_SAR_DRAFT(NUMBER, VARCHAR)
    TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FLAG_ACCOUNT(NUMBER, VARCHAR, NUMBER)
    TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.ESCALATE_CASE(NUMBER, VARCHAR, VARCHAR)
    TO ROLE CITADEL_MCP_ACTION_ROLE;

-- Verify before testing:
--   SHOW GRANTS ON AGENT CITADEL_DB.RISK.CITADEL_AGENT;
--   SHOW GRANTS TO ROLE CITADEL_MCP_ACTION_ROLE;

-- =============================================================================

USE ROLE ACCOUNTADMIN;
-- OAUTH SECURITY INTEGRATIONS
--
-- Snowflake OAuth supports ONLY authorization_code and refresh_token.
--   client_credentials -> 400 invalid_grant           (verified)
--   jwt-bearer         -> 400 unsupported_grant_type  (verified)
-- There is NO machine-to-machine flow: CLIENT_ID + CLIENT_SECRET alone cannot
-- mint a token. Consent once in a browser, then the refresh token (90 days here)
-- runs unattended.
--
-- The loopback URIs let a test client capture the auth code automatically
-- instead of the user copy/pasting it. Permitted because
-- OAUTH_ALLOW_NON_TLS_REDIRECT_URI = TRUE.
-- =============================================================================

CREATE OR REPLACE SECURITY INTEGRATION CITADEL_MCP_READER_OAUTH
    TYPE=OAUTH OAUTH_CLIENT=CUSTOM ENABLED=TRUE OAUTH_CLIENT_TYPE='CONFIDENTIAL'
    OAUTH_REDIRECT_URI='https://claude.ai/api/mcp/auth_callback'
    OAUTH_ALTERNATE_REDIRECT_URIS=(
        'https://app.snowflake.com/oauth/callback',
        'http://localhost:8586/callback',
        'http://localhost:8586')
    OAUTH_USE_SECONDARY_ROLES=NONE OAUTH_ALLOW_NON_TLS_REDIRECT_URI=TRUE
    ALLOWED_ROLES_LIST=('CITADEL_MCP_READER_ROLE');

-- NOTE: scoped to CITADEL_COMPLIANCE_OFFICER, not CITADEL_MCP_ACTION_ROLE.
-- The action procedures are EXECUTE AS CALLER and guard on
--   CURRENT_ROLE() IN ('CITADEL_COMPLIANCE_OFFICER','CITADEL_ADMIN',
--                      'SYSADMIN','ACCOUNTADMIN')
-- CITADEL_MCP_ACTION_ROLE is granted TO the officer role, so it is the CHILD and
-- cannot inherit it — scoping here to the action role returns
--   "CITADEL_COMPLIANCE_OFFICER or higher required."
-- Scoping to the officer satisfies the guard AND inherits every MCP/procedure/
-- table grant through the hierarchy, so one token reaches both servers and all
-- four tools. It also records a named officer in AUDIT_LOG.actor_role rather
-- than a service-account role.
CREATE OR REPLACE SECURITY INTEGRATION CITADEL_MCP_ACTION_OAUTH
    TYPE=OAUTH OAUTH_CLIENT=CUSTOM ENABLED=TRUE OAUTH_CLIENT_TYPE='CONFIDENTIAL'
    OAUTH_REDIRECT_URI='https://claude.ai/api/mcp/auth_callback'
    OAUTH_ALTERNATE_REDIRECT_URIS=(
        'https://app.snowflake.com/oauth/callback',
        'http://localhost:8585/callback',
        'http://localhost:8585')
    OAUTH_USE_SECONDARY_ROLES=NONE OAUTH_ALLOW_NON_TLS_REDIRECT_URI=TRUE
    ALLOWED_ROLES_LIST=('CITADEL_COMPLIANCE_OFFICER');

-- After running above, retrieve credentials:
-- SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_READER_OAUTH');
-- SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_ACTION_OAUTH');

-- Set user defaults for OAuth sessions.
-- DEFAULT_WAREHOUSE is mandatory — MCP sessions fail to initialise without it.
-- Clients that request scope session:role:all (e.g. Claude) use DEFAULT_ROLE.
ALTER USER AVINASHREDDY508 SET DEFAULT_ROLE='CITADEL_MCP_READER_ROLE' DEFAULT_WAREHOUSE='CITADEL_WH';

-- =============================================================================

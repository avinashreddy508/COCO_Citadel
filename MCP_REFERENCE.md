# CITADEL — MCP Server Reference

Complete reference for CITADEL's Model Context Protocol layer: the **AI Gateway**,
the **Action Server**, the **Registry**, authentication, and the verified test suite.

Everything in this document was validated against account `JSTEYZM-MP60447` on
2026-09-06. Response codes, payload shapes, and error strings are copied from real
responses, not inferred from documentation.

---

## 1. Architecture — Gateway, Actions, Registry

CITADEL exposes three distinct MCP concerns. Keeping them separate is what makes the
design governable.

```
                    ┌─────────────────────────────────────────────┐
   MCP CLIENTS      │              REGISTRY (discovery)           │
   ───────────      │  SHOW MCP SERVERS · DESCRIBE MCP SERVER      │
   CoCo Desktop     │  /.well-known/oauth-protected-resource/...   │
   Claude / Cursor  │  tools/list                                  │
   test_mcp.py      └─────────────────────────────────────────────┘
        │                              │
        │  OAuth 2.0 (authorization_code + refresh_token)
        ▼                              ▼
┌──────────────────────────┐  ┌──────────────────────────────┐
│   AI GATEWAY (read)      │  │   ACTION SERVER (write)      │
│ CITADEL_AGENT_MCP_SERVER │  │ CITADEL_ACTIONS_MCP_SERVER   │
│                          │  │                              │
│ 1 tool  CORTEX_AGENT_RUN │  │ 3 tools  GENERIC procedures  │
│   citadel_agent          │  │   file_sar_draft             │
│                          │  │   flag_account               │
│ Role: MCP_READER_ROLE    │  │   escalate_case              │
└──────────────────────────┘  │ Role: COMPLIANCE_OFFICER     │
        │                     └──────────────────────────────┘
        ▼                              │
┌──────────────────────────┐           ▼
│ CITADEL_AGENT            │  ┌──────────────────────────────┐
│ claude-sonnet-4-6        │  │ REGULATORY_FILINGS (SAR/CTR) │
│  ├ RiskSignalAnalytics   │  │ ACCOUNTS      (status FROZEN)│
│  │   semantic view       │  │ CASE_ESCALATIONS             │
│  ├ RegulatoryKnowledge   │  │ AUDIT_LOG     (INSERT only)  │
│  │   Cortex Search       │  └──────────────────────────────┘
│  └ system_execute_sql    │
└──────────────────────────┘
```

### Why two servers rather than one

Snowflake's own guidance is to expose a Cortex Agent as the single client-facing tool
for governed business questions, and to put direct-execution tools behind a **separate
server with a dedicated least-privileged role**. CITADEL follows that:

| Concern | AI Gateway | Action Server |
|---|---|---|
| Side effects | none — read only | writes 4 tables |
| Tool count | 1 (agent decides internally) | 3 (explicit, named) |
| OAuth integration | `CITADEL_MCP_READER_OAUTH` | `CITADEL_MCP_ACTION_OAUTH` |
| Session role | `CITADEL_MCP_READER_ROLE` | `CITADEL_COMPLIANCE_OFFICER` |
| Audit footprint | query history only | `AUDIT_LOG` row per call |

A client holding only the reader credential **cannot** file a SAR or freeze an account.
That separation is enforced by Snowflake RBAC, not by client-side convention.

---

## 2. The Registry — discovery without credentials

"Registry" covers three layers of discovery. The first two need no authentication,
which makes them the right first diagnostic when a client won't connect.

### 2.1 Snowflake object catalog

```sql
SHOW MCP SERVERS IN SCHEMA CITADEL_DB.RISK;
SHOW MCP SERVERS IN ACCOUNT;
DESCRIBE MCP SERVER CITADEL_DB.RISK.CITADEL_AGENT_MCP_SERVER;
```

`DESCRIBE` returns the full `server_spec` JSON — tool names, types, identifiers,
descriptions, and `input_schema` for GENERIC tools. This is the authoritative source
for what arguments a tool accepts.

### 2.2 OAuth Protected Resource Metadata (RFC 9728) — no auth required

```
GET https://<account>.snowflakecomputing.com
    /.well-known/oauth-protected-resource
    /api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_AGENT_MCP_SERVER
```

Verified response:

```json
{
  "resource": "https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_AGENT_MCP_SERVER",
  "authorization_servers": ["https://jsteyzm-mp60447.snowflakecomputing.com/oauth"],
  "scopes_supported": ["session:role:all"],
  "bearer_methods_supported": ["header"],
  "resource_name": "CITADEL_DB.RISK.CITADEL_AGENT_MCP_SERVER"
}
```

An unauthenticated `POST` to the server returns `401` with the pointer to that document:

```
WWW-Authenticate: Bearer resource_metadata="https://.../.well-known/oauth-protected-resource/..."
```

> `scopes_supported: ["session:role:all"]` does **not** mean "all roles are active".
> It means the session adopts the connecting user's `DEFAULT_ROLE`. Requesting an
> explicit `session:role:<ROLE>` scope overrides it, subject to the integration's
> `ALLOWED_ROLES_LIST`.

### 2.3 `tools/list` — requires a token

```json
POST /api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_ACTIONS_MCP_SERVER
{ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }
```

### 2.4 Current registry inventory

| Server | Tool | Type | Required args |
|---|---|---|---|
| `CITADEL_AGENT_MCP_SERVER` | `citadel_agent` | `CORTEX_AGENT_RUN` | `text` |
| `CITADEL_ACTIONS_MCP_SERVER` | `file_sar_draft` | `GENERIC` procedure | `p_flag_id` |
| | `flag_account` | `GENERIC` procedure | `p_account_id`, `p_reason` |
| | `escalate_case` | `GENERIC` procedure | `p_case_id`, `p_escalate_to` |

> The agent tool's argument is **`text`**, not `message`. Confirmed from the
> `inputSchema` in `tools/list`. Passing `message` is silently ignored.

---

## 3. Authentication

### 3.1 Supported grant types — verified empirically

| `grant_type` | Result | Usable |
|---|---|---|
| `authorization_code` | `200` | yes — one browser consent |
| `refresh_token` | `200` | yes — scriptable, 90-day validity |
| `client_credentials` | `400 invalid_grant` | **no** |
| `urn:ietf:params:oauth:grant-type:jwt-bearer` | `400 unsupported_grant_type` | **no** |

**Snowflake OAuth has no machine-to-machine flow.** A CLIENT_ID + CLIENT_SECRET pair
alone cannot mint a token — this is the single most common wrong assumption when
automating against a Snowflake MCP server. The working pattern is: consent once in a
browser, cache the refresh token, then run unattended for 90 days.

The alternative is a **Programmatic Access Token**, which is genuinely
non-interactive but requires the user be subject to a network policy (or an
authentication policy setting `PAT_NETWORK_POLICY_EVALUATION = NOT_ENFORCED`).
This account has no network policy, so PAT is not currently viable here.

### 3.2 OAuth integrations

| Integration | `ALLOWED_ROLES_LIST` | Serves |
|---|---|---|
| `CITADEL_MCP_READER_OAUTH` | `CITADEL_MCP_READER_ROLE` | AI Gateway |
| `CITADEL_MCP_ACTION_OAUTH` | `CITADEL_COMPLIANCE_OFFICER` | Action Server |

Both are `OAUTH_CLIENT_TYPE = CONFIDENTIAL`, issue refresh tokens
(`OAUTH_REFRESH_TOKEN_VALIDITY = 7776000`), have `OAUTH_ENFORCE_PKCE = FALSE`,
`OAUTH_USE_SECONDARY_ROLES = NONE`, and block `ACCOUNTADMIN`, `ORGADMIN`,
`SECURITYADMIN`.

Registered redirect URIs:

| Integration | Primary | Alternates |
|---|---|---|
| Reader | `https://claude.ai/api/mcp/auth_callback` | `app.snowflake.com/oauth/callback`, `http://localhost:8586/callback`, `http://localhost:8586` |
| Action | `https://claude.ai/api/mcp/auth_callback` | `app.snowflake.com/oauth/callback`, `http://localhost:8585/callback`, `http://localhost:8585` |

The loopback URIs enable automatic code capture — no copy/paste. `http` on localhost
is permitted because `OAUTH_ALLOW_NON_TLS_REDIRECT_URI = TRUE`.

Retrieve credentials:

```sql
SELECT SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_ACTION_OAUTH');
```

### 3.3 Why the Action Server runs as `CITADEL_COMPLIANCE_OFFICER`

The action procedures are `EXECUTE AS CALLER` and guard on `CURRENT_ROLE()`:

```sql
IF (CURRENT_ROLE() NOT IN ('CITADEL_COMPLIANCE_OFFICER','CITADEL_ADMIN',
                           'SYSADMIN','ACCOUNTADMIN')) THEN
    RETURN OBJECT_CONSTRUCT('error','CITADEL_COMPLIANCE_OFFICER or higher required.');
END IF;
```

`CITADEL_MCP_ACTION_ROLE` is granted **to** `CITADEL_COMPLIANCE_OFFICER`, so the
action role is the child and cannot inherit the officer role. Scoping the OAuth
integration to `CITADEL_COMPLIANCE_OFFICER` satisfies the guard *and* inherits every
MCP/procedure/table grant through the hierarchy.

It also produces the correct audit record: `AUDIT_LOG.actor_role` reads
`CITADEL_COMPLIANCE_OFFICER` rather than a service-account role.

### 3.4 Role hierarchy

```
ACCOUNTADMIN
└── SYSADMIN
    ├── CITADEL_COMPLIANCE_OFFICER   ← Action Server session role
    │   ├── CITADEL_RISK_MANAGER
    │   └── CITADEL_MCP_ACTION_ROLE  ← USAGE on actions server + procs
    │       └── CITADEL_MCP_READER_ROLE  ← USAGE on agent server + agent
    └── CITADEL_AUDITOR
```

Because the chain is transitive, **one compliance-officer token reaches both servers
and all four tools.**

---

## 4. Required grants

Snowflake's rule: *access to an MCP server does not grant access to its tools.* Each
tool needs its own grant. Missing these produces `HTTP 200` with an error in the body,
not a `401` — which makes it easy to misdiagnose.

```sql
-- Registry / server access
GRANT USAGE ON MCP SERVER CITADEL_DB.RISK.CITADEL_AGENT_MCP_SERVER
  TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON MCP SERVER CITADEL_DB.RISK.CITADEL_ACTIONS_MCP_SERVER
  TO ROLE CITADEL_MCP_ACTION_ROLE;

-- AI Gateway: the agent itself, plus Cortex entitlement
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON AGENT CITADEL_DB.RISK.CITADEL_AGENT
  TO ROLE CITADEL_MCP_READER_ROLE;
GRANT USAGE ON CORTEX SEARCH SERVICE CITADEL_DB.RISK.CITADEL_SEARCH_SVC
  TO ROLE CITADEL_MCP_READER_ROLE;
GRANT SELECT ON SEMANTIC VIEW CITADEL_DB.RISK.CITADEL_RISK_INTELLIGENCE
  TO ROLE CITADEL_MCP_READER_ROLE;

-- Action Server: one grant per procedure, signature-qualified
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FILE_SAR_DRAFT(NUMBER, VARCHAR)
  TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.FLAG_ACCOUNT(NUMBER, VARCHAR, NUMBER)
  TO ROLE CITADEL_MCP_ACTION_ROLE;
GRANT USAGE ON PROCEDURE CITADEL_DB.RISK.ESCALATE_CASE(NUMBER, VARCHAR, VARCHAR)
  TO ROLE CITADEL_MCP_ACTION_ROLE;
```

Verify:

```sql
SHOW GRANTS ON AGENT CITADEL_DB.RISK.CITADEL_AGENT;
SHOW GRANTS TO ROLE CITADEL_MCP_ACTION_ROLE;
```

---

## 5. Transport details that break naive clients

### 5.1 Responses are Server-Sent Events

Since **2026-08-20**, `tools/call` returns SSE rather than a single JSON body. Clients
must advertise both content types:

```
Accept: application/json, text/event-stream
```

The stream emits `data:` lines and terminates with `data: [DONE]`. A client calling
`response.json()` fails outright.

```python
def parse_sse(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        out.append(json.loads(payload))
    return out
```

### 5.2 Agent responses are a nested JSON envelope

`CORTEX_AGENT_RUN` returns one text block whose payload is itself JSON containing the
complete reasoning trace:

```json
{"content": [
  {"type": "thinking",    "thinking": {"text": "..."}},
  {"type": "tool_use",    "tool_use": {"name": "RegulatoryKnowledgeSearch", ...}},
  {"type": "tool_result", "tool_result": {...}},
  {"type": "text",        "text": "the actual answer"}
]}
```

A verified call returned **100,975 bytes** wrapping a **2,105-character** answer. Parse
the envelope and select the final `text` part, or you will surface ~98 KB of trace.
Responses can exceed 200 KB; cap `max_results` on the agent's search tool to reduce it.

### 5.3 Other limits

| Limit | Value |
|---|---|
| Tools per server | 50 |
| GENERIC tool response | truncated at 250 KB |
| SQL execution tool response | truncated at 250 KB |
| Recursion depth | 10 invocations |
| Protocol revision | MCP 2025-11-25 |
| Unsupported | resources, prompts, roots, notifications, sampling |
| Hostnames | must use hyphens, not underscores |

MCP server objects are **not replicated** in failover groups; recreate them on the
secondary. OAuth integrations *are* replicated.

---

## 6. Client registration

### 6.1 CoCo Desktop / CoCo CLI

Config lives at **`~/.snowflake/cortex/mcp.json`**. A project-level `.cortex/mcp.json`
is *not* read by CoCo.

```json
{
  "mcpServers": {
    "citadel-ai": {
      "type": "http",
      "url": "https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_AGENT_MCP_SERVER",
      "oauth": {
        "client_id": "${env:CITADEL_READER_CLIENT_ID}",
        "client_name": "Cortex Code",
        "redirect_port": 8586,
        "scope": "session:role:CITADEL_MCP_READER_ROLE",
        "authorization_server_url": "https://jsteyzm-mp60447.snowflakecomputing.com/oauth"
      },
      "timeout": 180000
    },
    "citadel-actions": {
      "type": "http",
      "url": "https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_ACTIONS_MCP_SERVER",
      "oauth": {
        "client_id": "${env:CITADEL_ACTION_CLIENT_ID}",
        "client_name": "Cortex Code",
        "redirect_port": 8585,
        "scope": "session:role:CITADEL_COMPLIANCE_OFFICER",
        "authorization_server_url": "https://jsteyzm-mp60447.snowflakecomputing.com/oauth"
      },
      "timeout": 120000
    }
  }
}
```

Schema requirements that are easy to get wrong:

- `type` is **required** — omit it and the server never connects.
- OAuth goes in an `oauth` block with **lowercase** keys. A Cursor-style
  `"auth": {"CLIENT_ID": ...}` block is silently ignored by CoCo.
- `redirect_port` must correspond to a URI registered on the security integration.
- CoCo migrates secrets into the OS keychain on first connect and rewrites the file.

Manage with `/mcp` inside a session, or `cortex mcp list` / `cortex mcp get <name>` /
`cortex mcp start` from a shell. Tools are namespaced `mcp__<server>__<tool>`, e.g.
`mcp__citadel-actions__file_sar_draft`, and can be gated in
`~/.snowflake/cortex/permissions.json`.

> CoCo's documented `oauth` block does not include `client_secret`, but these
> integrations are `CONFIDENTIAL` and need a secret at token exchange. If the flow
> fails, switch to a public client:
> `ALTER SECURITY INTEGRATION ... SET OAUTH_CLIENT_TYPE='PUBLIC' OAUTH_ENFORCE_PKCE=TRUE;`

### 6.2 Claude, ChatGPT, Cursor

Register the server URL and the client ID/secret; the client drives consent. The
primary `OAUTH_REDIRECT_URI` is already `https://claude.ai/api/mcp/auth_callback`.
Claude requests `session:role:all`, so the session uses the user's `DEFAULT_ROLE` —
set that to the intended MCP role.

If a network policy is ever enabled on this account, the client provider's outbound
IPs must be allowlisted, or the token endpoint returns `invalid_client`.

### 6.3 Registering the Action Server onto a Cortex Agent (MCP Connectors)

To let `CITADEL_AGENT` invoke the action tools itself — making it genuinely agentic
rather than advisory:

```sql
CREATE API INTEGRATION citadel_actions_mcp_api
  API_PROVIDER = external_mcp
  API_ALLOWED_PREFIXES = ('https://jsteyzm-mp60447.snowflakecomputing.com/api/v2')
  API_USER_AUTHENTICATION = (
    TYPE = OAUTH2
    OAUTH_CLIENT_ID = '<action_client_id>'
    OAUTH_CLIENT_SECRET = '<action_client_secret>'
    OAUTH_AUTHORIZATION_ENDPOINT = 'https://jsteyzm-mp60447.snowflakecomputing.com/oauth/authorize'
    OAUTH_TOKEN_ENDPOINT = 'https://jsteyzm-mp60447.snowflakecomputing.com/oauth/token-request'
    OAUTH_ALLOWED_SCOPES = ('session:role:CITADEL_COMPLIANCE_OFFICER')
    OAUTH_REFRESH_TOKEN_VALIDITY = 86400
  )
  ENABLED = TRUE;

CREATE EXTERNAL MCP SERVER citadel_actions_ext
  WITH DISPLAY_NAME = 'CITADEL Compliance Actions'
  URL = 'https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_ACTIONS_MCP_SERVER'
  API_INTEGRATION = citadel_actions_mcp_api;

ALTER AGENT CITADEL_DB.RISK.CITADEL_AGENT MODIFY LIVE VERSION SET SPECIFICATION $$
  <existing_spec>
  mcp_servers:
    - server_spec:
        name: "CITADEL_DB.RISK.citadel_actions_ext"
$$;
```

Then consent once:

```sql
SELECT SYSTEM$START_USER_OAUTH_FLOW('CITADEL_ACTIONS_MCP_API');
-- open the returned URL, approve, then in the same session:
SELECT SYSTEM$FINISH_OAUTH_FLOW('<query_string_from_redirect>');
```

Register `https://identity.snowflake.com/oauth2/callback` on the action integration
first.

**Recursion check:** the action server exposes only stored procedures — no agent — so
`CITADEL_AGENT → citadel_actions_ext → procedures` terminates. No loop. Attaching the
*agent* server to the agent itself would loop and must be avoided.

Calls appear in `SNOWFLAKE.LOCAL.AI_OBSERVABILITY_EVENTS` as spans. Full inputs and
outputs are redacted unless the role holds
`READ UNREDACTED AI OBSERVABILITY EVENTS TABLE`.

---

## 7. Test suite

`scripts/test_mcp.py` covers both endpoints. It handles SSE parsing, envelope
unwrapping, token refresh on `401`, loopback code capture, and UTF-8 console output.

```powershell
python scripts\test_mcp.py discover                  # no auth — 401 + RFC 9728
python scripts\test_mcp.py auth action               # one-time consent
python scripts\test_mcp.py list                      # tools/list, both servers
python scripts\test_mcp.py ask "question"            # AI Gateway
python scripts\test_mcp.py full <flag_id> <acct_id>  # read + write + audit
python scripts\test_mcp.py escalate <case_id>
```

Tokens cache to `scripts/.mcp_tokens.json` (chmod 600). Refresh validity is 90 days,
so only the first run needs a browser.

### 7.1 Verified results — 2026-09-06

**READ — `CITADEL_AGENT_MCP_SERVER`**

| Step | Result |
|---|---|
| `tools/list` | `200`, 1 tool |
| `tools/call citadel_agent` | `200`, 100,975 bytes |
| Tools orchestrated | `RegulatoryKnowledgeSearch`, `RiskSignalAnalytics`, `system_execute_sql` |
| Answer | 16 flagged accounts; 31 CFR §1010.314; 31 USC 5324; SAR 30 days; CTR 15 days; AML-POL-003 routing; tipping-off 31 USC 5318(g)(2) |

**WRITE — `CITADEL_ACTIONS_MCP_SERVER`**

| Step | Result |
|---|---|
| `tools/list` | `200`, 3 tools |
| `file_sar_draft(5445)` | `filing_id 1004`, 2,074-char AI narrative |
| `flag_account(126)` | `status FROZEN`, `case_id 54` auto-opened |
| `escalate_case(54)` | `status ESCALATED` → `compliance.officer@citadel.bank` |

**AUDIT — `AUDIT_LOG` 64 → 67**

| log_id | action | object | actor_role |
|---|---|---|---|
| 402 | `FILE_SAR` | FILING 1004 | `CITADEL_COMPLIANCE_OFFICER` |
| 403 | `FLAG_ACCOUNT` | ACCOUNT 126 | `CITADEL_COMPLIANCE_OFFICER` |
| 303 | `ESCALATE_CASE` | CASE 54 | `CITADEL_COMPLIANCE_OFFICER` |

Dashboard-driven actions in the same table show `actor_role = ACCOUNTADMIN`. One
immutable log, each channel correctly attributed.

---

## 8. Defects found and fixed

Every item below was a real failure discovered by running the suite, not a
hypothetical.

| # | Defect | Symptom | Fix |
|---|---|---|---|
| 1 | `client_credentials` assumed to work | `400 invalid_grant` | Use `authorization_code` + cached `refresh_token` |
| 2 | `USAGE ON AGENT` never granted | `200` + *"agent does not exist or access is not authorized"* | `GRANT USAGE ON AGENT ... TO ROLE CITADEL_MCP_READER_ROLE` |
| 3 | `USAGE ON PROCEDURE` missing for `FILE_SAR_DRAFT` and `FLAG_ACCOUNT` (only `ESCALATE_CASE` had it) | tools listed but not invocable | Granted both, signature-qualified |
| 4 | Action OAuth scoped to a role the procedure guard rejects | `200` + *"CITADEL_COMPLIANCE_OFFICER or higher required"* | `ALLOWED_ROLES_LIST = ('CITADEL_COMPLIANCE_OFFICER')` |
| 5 | `mcp.json` used Cursor's `auth` block, missing `type`, wrong location | CoCo never connected | Rewrote to CoCo schema at `~/.snowflake/cortex/mcp.json` |
| 6 | No loopback redirect URI registered | consent required manual code paste | Added `localhost:8585/8586` to alternates |
| 7 | Agent tool called with `message` | argument ignored | Correct name is `text` |
| 8 | Agent response treated as plain text | 75 KB of trace shown instead of the answer | Parse the nested envelope |
| 9 | `AUDIT_LOG` sorted by `log_id DESC` | timeline out of chronological order — `log_id` is per-procedure, so 303 is newer than 403 | Sort by `event_ts DESC` |
| 10 | Windows `cp1252` console | `UnicodeEncodeError` on `§` and `—` | `sys.stdout.reconfigure(encoding="utf-8")` |

---

## 9. Troubleshooting

| Symptom | Cause | Check |
|---|---|---|
| `401` on every call | no/expired token | `discover` should still return `200` metadata; re-run `auth` |
| `400 invalid_grant` | using `client_credentials`, or a reused/expired code | Codes are single-use and expire in minutes |
| `400 unsupported_grant_type` | `jwt-bearer` | Not supported for MCP |
| `200` + "agent does not exist or access is not authorized" | missing `USAGE ON AGENT` | `SHOW GRANTS ON AGENT ...` |
| `200` + "CITADEL_COMPLIANCE_OFFICER or higher required" | session role fails the procedure guard | `ALLOWED_ROLES_LIST` on the integration |
| Tools listed but not invocable | server granted, tool not | Grant per tool |
| Client connects, no tools | `DEFAULT_ROLE` lacks `USAGE` on the server | `ALTER USER ... SET DEFAULT_ROLE` |
| Session fails to initialise | user has no `DEFAULT_WAREHOUSE` | `ALTER USER ... SET DEFAULT_WAREHOUSE` |
| `invalid_client` at token endpoint | network policy blocking the client's IPs | Allowlist provider outbound IPs |
| Hostname connection failure | underscores in hostname | Use hyphens |
| `REGULATORY_FILINGS` returns 0 rows | row access policy blocks `CITADEL_MCP_READER_ROLE` | `USE ROLE ACCOUNTADMIN` for direct SQL |
| CoCo shows no servers | wrong file or schema | `~/.snowflake/cortex/mcp.json`, `type` + `oauth` present |
| Response parse error | SSE not handled | Add `text/event-stream` to `Accept` |

---

## 10. Object inventory

| Object | Type | Purpose |
|---|---|---|
| `CITADEL_AGENT_MCP_SERVER` | MCP SERVER | AI Gateway — 1 `CORTEX_AGENT_RUN` tool |
| `CITADEL_ACTIONS_MCP_SERVER` | MCP SERVER | Action Server — 3 `GENERIC` tools |
| `CITADEL_AGENT` | CORTEX AGENT | `claude-sonnet-4-6` orchestrator |
| `CITADEL_RISK_INTELLIGENCE` | SEMANTIC VIEW | `RiskSignalAnalytics` tool |
| `CITADEL_SEARCH_SVC` | CORTEX SEARCH | `RegulatoryKnowledgeSearch` tool |
| `CITADEL_MCP_READER_OAUTH` | SECURITY INTEGRATION | Gateway auth |
| `CITADEL_MCP_ACTION_OAUTH` | SECURITY INTEGRATION | Action auth |
| `FILE_SAR_DRAFT` | PROCEDURE | SAR draft + AI narrative + audit |
| `FLAG_ACCOUNT` | PROCEDURE | Freeze + open case + audit |
| `ESCALATE_CASE` | PROCEDURE | Escalate + audit |
| `CITADEL_MCP_READER_ROLE` | ROLE | Gateway session role |
| `CITADEL_MCP_ACTION_ROLE` | ROLE | Holds action grants |
| `CITADEL_COMPLIANCE_OFFICER` | ROLE | Action session role |

---

## 11. Endpoints

```
Account         https://jsteyzm-mp60447.snowflakecomputing.com
Authorize       {account}/oauth/authorize
Token           {account}/oauth/token-request
AI Gateway      {account}/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_AGENT_MCP_SERVER
Action Server   {account}/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_ACTIONS_MCP_SERVER
Registry meta   {account}/.well-known/oauth-protected-resource/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/{server}
```

---
name: citadel-mcp-connector
description: >
  Connects CoCo Desktop to the CITADEL Risk Intelligence MCP servers.
  Provides two MCP tools: (1) citadel-ai — natural language risk, fraud, credit,
  and liquidity Q&A through CITADEL_AGENT; (2) citadel-actions — action tools
  (FILE_SAR_DRAFT, FLAG_ACCOUNT, ESCALATE_CASE) for compliance officers.
  All answers cite Basel III, FATF, FinCEN, and RBI regulatory references.
metadata:
  type: mcp_connector
  account: JSTEYZM-MP60447
  hackathon: Snowflake CoCo CLI Hackathon 2026
---

# CITADEL MCP Connector

## What This Provides

Two MCP tools for CoCo Desktop:

| Tool | MCP Server | Who Can Use |
|---|---|---|
| `citadel_agent` | CITADEL_AGENT_MCP_SERVER | All users with CITADEL_MCP_READER_ROLE |
| `file_sar_draft` / `flag_account` / `escalate_case` | CITADEL_ACTIONS_MCP_SERVER | CITADEL_MCP_ACTION_ROLE only |

## Setup

**1. Get OAuth credentials** from your Snowflake admin:
```sql
SELECT PARSE_JSON(SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_READER_OAUTH')):OAUTH_CLIENT_ID::STRING,
       PARSE_JSON(SYSTEM$SHOW_OAUTH_CLIENT_SECRETS('CITADEL_MCP_READER_OAUTH')):OAUTH_CLIENT_SECRET::STRING;
```

**2. Set environment variables:**
```bash
export CITADEL_READER_CLIENT_ID=<client_id from above>
export CITADEL_READER_CLIENT_SECRET=<client_secret from above>
# For action tools (RISK_MANAGER+ only):
export CITADEL_ACTION_CLIENT_ID=<from CITADEL_MCP_ACTION_OAUTH>
export CITADEL_ACTION_CLIENT_SECRET=<from CITADEL_MCP_ACTION_OAUTH>
```

**3. Add to `~/.snowflake/cortex/mcp.json`:**
```json
{
  "mcpServers": {
    "citadel-ai": {
      "url": "https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_AGENT_MCP_SERVER",
      "auth": {
        "CLIENT_ID": "${env:CITADEL_READER_CLIENT_ID}",
        "CLIENT_SECRET": "${env:CITADEL_READER_CLIENT_SECRET}"
      }
    },
    "citadel-actions": {
      "url": "https://jsteyzm-mp60447.snowflakecomputing.com/api/v2/databases/CITADEL_DB/schemas/RISK/mcp-servers/CITADEL_ACTIONS_MCP_SERVER",
      "auth": {
        "CLIENT_ID": "${env:CITADEL_ACTION_CLIENT_ID}",
        "CLIENT_SECRET": "${env:CITADEL_ACTION_CLIENT_SECRET}"
      }
    }
  }
}
```

## Demo Questions (AI Gateway)

- "Which accounts show fraud-risk patterns this week and what regulation applies?"
- "Show me the credit watch-list by sector with RWA and Expected Loss"
- "What is the LCR status and what does Basel III require on a breach?"
- "Are there any PEP customers with open fraud flags?"

## Action Tools (requires CITADEL_MCP_ACTION_ROLE)

```
file_sar_draft(p_flag_id=10, p_notes="Structuring confirmed")
flag_account(p_account_id=100, p_reason="Cross-border velocity", p_linked_flag_id=50)
escalate_case(p_case_id=3, p_escalate_to="compliance.officer@citadel.bank")
```

## Regulatory Citations Supported

| Domain | Regulation |
|---|---|
| Structuring | 31 CFR §1010.314 (BSA/FinCEN); PMLA Schedule Rule 3(B) |
| Cross-border | FATF Recommendation 19; RBI Master Direction KYC 2016 §38 |
| Velocity | FinCEN SAR field 35(a) |
| LCR breach | Basel III Art. 412; BCBS Jan 2013 §415 |
| NSFR breach | Basel III Art. 428b |
| PEP | FATF Recommendation 12 |
| NPA | RBI Master Circular on IRAC 2023 |
| Credit watch-list | Basel III ICAAP internal threshold (PD > 0.15) |

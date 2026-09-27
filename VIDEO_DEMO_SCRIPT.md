# CITADEL — 3-5 Minute Demo Video Script
## Snowflake CoCo CLI Hackathon 2026

**Recording tool:** CoCo Desktop's native chat panel (the MCP tools are invoked live, in
natural language — no CLI script needed for the actual recording).
**Target runtime:** ~4 minutes. **Account:** VFWIQMM-HB26136 (already fully deployed and verified).

Both MCP servers (`citadel-ai`, `citadel-actions`) connect natively in CoCo Desktop via a
static bearer-token header workaround for a CoCo OAuth client-credential bug (see
`refresh_coco_mcp_tokens.py`). **Access tokens last ~10 minutes** — run that script immediately
before recording, then fully restart CoCo Desktop so it picks up the fresh tokens.

---

### 0:00 – 0:20 — Problem statement (talk to camera / voiceover, no chat yet)

> "Banking compliance teams manually cross-reference thousands of flagged transactions
> against Basel III, FATF, and FinCEN rules every day. CITADEL is a Snowflake-native
> copilot that reads that context automatically — and can act on it, with a full audit
> trail — all invoked live from Cortex Code's chat, through two governed MCP servers."

---

### 0:20 – 1:00 — Registry: show the two MCP servers connected in CoCo Desktop

**Action on screen:** Open Agent Settings -> MCP tab (or the MCP Connectors panel) and show
`citadel-ai` and `citadel-actions` both in a **Connected** state, with tool counts visible
(1 tool on citadel-ai, 3 tools on citadel-actions).

**Narration:** "Two purpose-scoped MCP servers, live-connected inside Cortex Code — one
read-only AI gateway, one write-capable action server. This is the modular-skills split:
read vs. write are separate credentials, separate Snowflake roles, separate OAuth integrations."

---

### 1:00 – 2:00 — Skill 1 (READ): ask a live regulatory question, in chat

**Type directly into CoCo's chat:**
```
Using the citadel-ai MCP tool, what accounts show fraud-risk patterns this week?
Include the regulatory basis for each pattern.
```

**What happens on screen (real):** CoCo shows it invoking `mcp__citadel-ai__citadel_agent`,
then streams back a grounded answer citing exact regulations, e.g.:
```
| Pattern       | Txns   | Regulatory basis                                              |
|---------------|--------|----------------------------------------------------------------|
| STRUCTURING   | 60,912 | Cash deposit $9,800-$9,999 to evade $10,000 CTR — 31 CFR §1010.314 |
| CROSS_BORDER  |  3,549 | Wire to FATF grey/black-list jurisdiction — FATF R.19          |
```

**Narration:** "Input: a plain-English compliance question, typed straight into Cortex Code.
Processing: the agent calls the MCP tool, which queries live transaction data through a
semantic model and cites the exact regulation. Output: a grounded answer with the article
number — not a hallucinated citation."

---

### 2:00 – 3:15 — Skill 2 (WRITE): file a SAR, freeze an account, open a case — in chat

**Type directly into CoCo's chat** (use a fresh, still-open flag_id — see checklist):
```
Using the citadel-actions MCP tools, file a SAR for flag_id <FLAG_ID> with notes
"Suspicious velocity pattern detected", then freeze account_id <ACCOUNT_ID> linked to that flag.
```

**What happens on screen (real):** CoCo invokes `mcp__citadel-actions__file_sar_draft` then
`mcp__citadel-actions__flag_account` in sequence, returning the filing_id, case_id, and
FROZEN status directly in the chat response.

**Follow-up, typed into the same chat:**
```
Escalate case_id <CASE_ID> to compliance.officer@citadel.bank with notes
"High-confidence fraud pattern, needs review."
```

**What happens on screen (real):** CoCo invokes `mcp__citadel-actions__escalate_case`,
returning `"new_status": "ESCALATED"`.

**Narration:** "Input: a flag ID surfaced by the read step. Processing: three governed
stored procedures, invoked live from chat, each requiring the CITADEL_COMPLIANCE_OFFICER
role — a reader-only credential cannot call these. Output: a SAR filed, an account frozen,
a case escalated — three real Snowflake table writes, driven entirely by natural language."

---

### 3:15 – 3:50 — Skill 3 (GOVERNANCE): prove it's attributable, not just "something happened"

**Input** (run in a SQL tab in CoCo Desktop, or ask in chat: "Show me the last 3 audit log entries"):
```sql
SELECT log_id, event_ts, actor_role, action_type, object_id, change_summary
FROM CITADEL_DB.RISK.AUDIT_LOG
ORDER BY event_ts DESC LIMIT 3;
```

**Output (real):**
```
| LOG_ID | ACTOR_ROLE                  | ACTION_TYPE   | OBJECT_ID | CHANGE_SUMMARY                                       |
| 3      | CITADEL_COMPLIANCE_OFFICER  | ESCALATE_CASE | <CASE_ID> | Case escalated to compliance.officer@citadel.bank    |
| 2      | CITADEL_COMPLIANCE_OFFICER  | FLAG_ACCOUNT  | <ACCT_ID> | Account frozen. Case opened.                         |
| 1      | CITADEL_COMPLIANCE_OFFICER  | FILE_SAR      | <FLAG_ID> | SAR filed                                            |
```

**Narration:** "Every write triggered from chat is stamped with the real actor role, not a
generic service account — because the stored procedures run EXECUTE AS CALLER. This
immutable log is what a bank examiner would actually check."

---

### 3:50 – 4:10 — Wrap-up (talk to camera)

> "Ask, file, freeze, escalate, verify — all driven live from Cortex Code's chat through two
> governed MCP servers, fully backed by Snowflake RBAC, fully auditable, no hallucinated
> regulations. That's CITADEL."

---

## Recording checklist

- [ ] **Run `python citadel/scripts/refresh_coco_mcp_tokens.py` immediately before recording**
      (access tokens expire in ~10 min) — then **fully restart CoCo Desktop** so it loads the
      fresh tokens, and confirm both `citadel-ai` / `citadel-actions` show Connected before
      you start filming.
- [ ] Pick a **fresh, still-open** flag_id/account_id before recording (earlier test runs
      already actioned flag 102/account 266/case 51):
      ```sql
      SELECT flag_id, account_id FROM CITADEL_DB.RISK.RISK_FLAGS
      WHERE flag_status NOT IN ('ACTIONED','DISMISSED') AND flag_domain='FRAUD'
      ORDER BY flag_score DESC LIMIT 1;
      ```
- [ ] Chat font size large enough to read on a recorded video
- [ ] Run each prompt for real during the recording (don't pre-can output — actually type it
      so timestamps and IDs look live)
- [ ] Have a fallback ready: if a token expires mid-recording, `refresh_coco_mcp_tokens.py` +
      CoCo restart takes under a minute to recover
- [ ] Total runtime target: 4:00-4:15 (under the 5-minute cap with margin)

## Fallback: CLI-only path (if native chat connection breaks again)

`python scripts/test_mcp.py discover|list|ask|write|escalate` — already fully verified
end-to-end and requires no CoCo MCP connection at all. See git history of this file for the
original CLI-driven script if needed.

"""
Refresh CITADEL MCP access tokens (10-min TTL) and rewrite CoCo Desktop's
global mcp.json with fresh 'Authorization: Bearer <token>' static headers.

Run this right before recording the demo video (and again if a connection
drops mid-recording, since tokens expire after 10 minutes).

Usage:
    python refresh_coco_mcp_tokens.py
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import test_mcp as m

MCP_JSON = pathlib.Path.home() / ".snowflake" / "cortex" / "mcp.json"

reader_token = m.refresh("reader")
action_token = m.refresh("action")

config = {
    "mcpServers": {
        "citadel-ai": {
            "type": "http",
            "url": f"{m.BASE}/api/v2/databases/{m.DB}/schemas/{m.SCH}/mcp-servers/CITADEL_AGENT_MCP_SERVER",
            "headers": {"Authorization": f"Bearer {reader_token}"},
            "timeout": 60000,
        },
        "citadel-actions": {
            "type": "http",
            "url": f"{m.BASE}/api/v2/databases/{m.DB}/schemas/{m.SCH}/mcp-servers/CITADEL_ACTIONS_MCP_SERVER",
            "headers": {"Authorization": f"Bearer {action_token}"},
            "timeout": 60000,
        },
    }
}

MCP_JSON.write_text(json.dumps(config, indent=2), encoding="utf-8")
print(f"Wrote fresh tokens to {MCP_JSON}")
print("Now fully restart CoCo Desktop, then reconnect citadel-ai / citadel-actions.")
print("Tokens expire in ~10 minutes -- rerun this script if they lapse.")

#!/usr/bin/env python
"""
CITADEL — MCP server endpoint test harness (OAuth 2.0)

IMPORTANT — Snowflake OAuth grant support (verified against this account):
    client_credentials  -> HTTP 400 invalid_grant          (NOT supported)
    jwt-bearer          -> HTTP 400 unsupported_grant_type (NOT supported)
    authorization_code  -> supported (one browser consent)
    refresh_token       -> supported (scriptable afterwards)

So CLIENT_ID + CLIENT_SECRET alone cannot mint a token. You authorise once in a
browser; this script caches the refresh_token (valid 90 days on this account) and
every later run is fully automated.

Transport notes:
  * tools/call responses are Server-Sent Events since 2026-08-20, so Accept must
    list  application/json, text/event-stream  and the body must be SSE-parsed.
  * The MCP session's primary role comes from the OAuth scope
    session:role:<ROLE>, constrained by the integration's ALLOWED_ROLES_LIST.

Servers / roles on this account:
  CITADEL_AGENT_MCP_SERVER    <- CITADEL_MCP_READER_OAUTH  -> CITADEL_MCP_READER_ROLE
  CITADEL_ACTIONS_MCP_SERVER  <- CITADEL_MCP_ACTION_OAUTH  -> CITADEL_MCP_ACTION_ROLE
(CITADEL_MCP_READER_ROLE is granted to CITADEL_MCP_ACTION_ROLE, so the action
 role inherits read access to both servers.)

Usage
-----
  python test_mcp.py discover              # no auth: 401 challenge + RFC 9728 metadata
  python test_mcp.py auth reader           # one-time browser consent -> caches tokens
  python test_mcp.py auth action
  python test_mcp.py list                  # tools/list on both servers
  python test_mcp.py ask "question"        # call citadel_agent
  python test_mcp.py write <flag_id> <account_id>   # SAR -> freeze -> escalate chain
  python test_mcp.py all                   # discover + list + ask
"""

import http.server
import json
import os
import pathlib
import socketserver
import sys
import threading
import urllib.parse
import webbrowser

import requests

# Windows consoles default to cp1252, which cannot encode the section signs and
# em dashes that appear in regulatory citations. Force UTF-8 on stdout.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

ACCOUNT = "vfwiqmm-hb26136"
BASE    = f"https://{ACCOUNT}.snowflakecomputing.com"
DB, SCH = "CITADEL_DB", "RISK"

AUTHZ_EP = f"{BASE}/oauth/authorize"
TOKEN_EP = f"{BASE}/oauth/token-request"

# Loopback redirect URIs, registered on each integration's
# OAUTH_ALTERNATE_REDIRECT_URIS. OAUTH_ALLOW_NON_TLS_REDIRECT_URI = TRUE permits
# plain http on localhost. Using loopback capture means no copy/paste of the code.
REDIRECT_PORTS = {"reader": 8586, "action": 8585}

# Set False to fall back to manual paste via https://app.snowflake.com/oauth/callback
USE_LOCALHOST = True
MANUAL_REDIRECT = "https://app.snowflake.com/oauth/callback"


def redirect_uri(kind: str) -> str:
    if USE_LOCALHOST:
        return f"http://localhost:{REDIRECT_PORTS[kind]}/callback"
    return MANUAL_REDIRECT

CLIENTS = {
    "reader": {
        "server":        "CITADEL_AGENT_MCP_SERVER",
        "client_id":     "Fo5auYqEm1tXDhw2SJWsbB7P59I=",
        "client_secret": "yy9i62whlXae4exaDQjVQPgg1oqnFLIZg2DOvLHVZGc=",
        "role":          "CITADEL_MCP_READER_ROLE",
    },
    "action": {
        "server":        "CITADEL_ACTIONS_MCP_SERVER",
        "client_id":     "kVpkwthaPNoiecwGtDjv/m8dNo4=",
        "client_secret": "Dh247uwLbde5AOAnxYEkpk224pN1ImTm0qVzZI9jf8A=",
        # The action procedures guard on CURRENT_ROLE() IN ('CITADEL_COMPLIANCE_OFFICER',
        # 'CITADEL_ADMIN','SYSADMIN','ACCOUNTADMIN') and run EXECUTE AS CALLER, so the
        # MCP session must BE the compliance officer. That role inherits
        # CITADEL_MCP_ACTION_ROLE -> CITADEL_MCP_READER_ROLE, so this single token also
        # reaches the agent server, and AUDIT_LOG records a named officer as the actor.
        "role":          "CITADEL_COMPLIANCE_OFFICER",
    },
}

TOKEN_CACHE = pathlib.Path(__file__).parent / ".mcp_tokens.json"


# ────────────────────────── token cache ──────────────────────────

def load_cache() -> dict:
    if TOKEN_CACHE.exists():
        try:
            return json.loads(TOKEN_CACHE.read_text())
        except json.JSONDecodeError:
            return {}
    return {}


def save_cache(cache: dict):
    TOKEN_CACHE.write_text(json.dumps(cache, indent=2))
    try:
        os.chmod(TOKEN_CACHE, 0o600)
    except OSError:
        pass


# ────────────────────────── OAuth flow ──────────────────────────

def _capture_code_via_localhost(port: int, timeout: int = 180) -> str:
    """Serve one request on localhost to capture ?code=... from the redirect."""
    box  = {}
    done = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.urlparse(self.path).query
            parsed = urllib.parse.parse_qs(q)
            box["code"]  = parsed.get("code", [None])[0]
            box["error"] = parsed.get("error", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            msg = ("<h2>CITADEL &mdash; authorised.</h2><p>You can close this tab.</p>"
                   if box.get("code") else
                   f"<h2>Authorisation failed</h2><p>{box.get('error')}</p>")
            self.wfile.write(msg.encode("utf-8"))
            done.set()

        def log_message(self, *a):
            pass

    class Server(socketserver.TCPServer):
        allow_reuse_address = True

    with Server(("127.0.0.1", port), Handler) as srv:
        srv.timeout = timeout
        threading.Thread(target=srv.handle_request, daemon=True).start()
        if not done.wait(timeout):
            raise TimeoutError(f"No redirect received on port {port} within {timeout}s")

    if box.get("error"):
        raise RuntimeError(f"Authorisation denied: {box['error']}")
    return box.get("code") or ""


def authorize(kind: str):
    """One-time authorization_code exchange -> caches access + refresh token."""
    c   = CLIENTS[kind]
    ru  = redirect_uri(kind)
    params = {
        "response_type": "code",
        "client_id":     c["client_id"],
        "redirect_uri":  ru,
        "scope":         f"session:role:{c['role']}",
    }
    authz_url = AUTHZ_EP + "?" + urllib.parse.urlencode(params)

    print(f"\n=== OAuth consent — {kind} (as {c['role']}) ===")
    print(f"redirect_uri: {ru}\n")

    if USE_LOCALHOST:
        port = REDIRECT_PORTS[kind]
        print(f"Listening on 127.0.0.1:{port} — opening browser now.")
        print("Approve the consent screen; the code is captured automatically.\n")
        try:
            webbrowser.open(authz_url)
        except Exception:
            print(f"Open manually:\n{authz_url}\n")
        code = _capture_code_via_localhost(port)
        print("Code captured.")
    else:
        print(authz_url + "\n")
        try:
            webbrowser.open(authz_url)
        except Exception:
            pass
        print("Approve, then copy the 'code' parameter from the address bar.")
        print("(A 'Page not found' page is expected — the code is still in the URL.)\n")
        code = input("Paste code here: ").strip()

    if not code:
        sys.exit("No authorization code received.")

    r = requests.post(
        TOKEN_EP,
        data={"grant_type": "authorization_code", "code": code, "redirect_uri": ru},
        auth=(c["client_id"], c["client_secret"]),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=30,
    )
    if r.status_code != 200:
        sys.exit(f"Token exchange failed: HTTP {r.status_code}\n{r.text[:500]}")

    tok   = r.json()
    cache = load_cache()
    cache[kind] = {"access_token":  tok.get("access_token"),
                   "refresh_token": tok.get("refresh_token")}
    save_cache(cache)
    print(f"Authorised as {c['role']}. Tokens cached in {TOKEN_CACHE.name} "
          f"(refresh valid 90 days).")


def refresh(kind: str) -> str:
    c = CLIENTS[kind]
    cache = load_cache()
    rt = cache.get(kind, {}).get("refresh_token")
    if not rt:
        sys.exit(f"No refresh token for '{kind}'. Run:  python test_mcp.py auth {kind}")

    r = requests.post(
        TOKEN_EP,
        data={"grant_type": "refresh_token", "refresh_token": rt,
              "redirect_uri": redirect_uri(kind)},
        auth=(c["client_id"], c["client_secret"]),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=30,
    )
    if r.status_code != 200:
        sys.exit(f"Refresh failed: HTTP {r.status_code}\n{r.text[:400]}\n"
                 f"Re-run:  python test_mcp.py auth {kind}")

    at = r.json().get("access_token")
    cache.setdefault(kind, {})["access_token"] = at
    save_cache(cache)
    return at


def token_for(kind: str) -> str:
    """Return an access token usable for `kind`.

    CITADEL_MCP_READER_ROLE is granted to CITADEL_MCP_ACTION_ROLE, so an 'action'
    token inherits read access to both servers. If the requested client has no
    cached token, fall back to 'action'.
    """
    cache = load_cache()
    if cache.get(kind, {}).get("access_token"):
        return cache[kind]["access_token"]
    if cache.get(kind, {}).get("refresh_token"):
        return refresh(kind)

    if kind != "action" and cache.get("action", {}).get("refresh_token"):
        print(f"  (no '{kind}' token — using 'action' token, which inherits it)")
        a = cache["action"]
        return a.get("access_token") or refresh("action")

    sys.exit(f"No token for '{kind}'. Run:  python test_mcp.py auth action")


def auth_kind_for(kind: str) -> str:
    """Which cached client actually supplies the bearer token for `kind`."""
    cache = load_cache()
    if cache.get(kind, {}).get("refresh_token"):
        return kind
    return "action" if cache.get("action", {}).get("refresh_token") else kind


# ────────────────────────── MCP transport ──────────────────────────

def url_for(server: str) -> str:
    return f"{BASE}/api/v2/databases/{DB}/schemas/{SCH}/mcp-servers/{server}"


def parse_sse(text: str) -> list:
    """tools/call returns SSE; stream terminates with  data: [DONE]."""
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        try:
            out.append(json.loads(payload))
        except json.JSONDecodeError:
            pass
    return out


def rpc(kind: str, method: str, params: dict = None, retry: bool = True) -> dict:
    c    = CLIENTS[kind]
    body = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        body["params"] = params

    hdr = {"Authorization": f"Bearer {token_for(kind)}",
           "Content-Type": "application/json",
           "Accept": "application/json, text/event-stream"}

    r = requests.post(url_for(c["server"]), headers=hdr, json=body, timeout=180)

    if r.status_code == 401 and retry:
        print("  (401 — refreshing access token)")
        refresh(auth_kind_for(kind))
        return rpc(kind, method, params, retry=False)

    print(f"  HTTP {r.status_code}  ({len(r.content)} bytes)")
    if r.status_code != 200:
        print(f"  {r.text[:500]}")
        return {}

    if "text/event-stream" in r.headers.get("Content-Type", ""):
        events = parse_sse(r.text)
        for ev in events:
            if "result" in ev or "error" in ev:
                return ev
        return events[-1] if events else {}
    try:
        return r.json()
    except json.JSONDecodeError:
        return {}


# ────────────────────────── commands ──────────────────────────

def cmd_discover():
    for kind, c in CLIENTS.items():
        srv = c["server"]
        print(f"\n=== {srv} ===")
        r = requests.post(
            url_for(srv),
            headers={"Accept": "application/json, text/event-stream",
                     "Content-Type": "application/json"},
            json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, timeout=30)
        print(f"  unauthenticated POST -> HTTP {r.status_code}  (401 expected)")
        ok = "WWW-Authenticate" in r.headers
        print(f"  auth challenge present: {ok}")

        meta = (f"{BASE}/.well-known/oauth-protected-resource"
                f"/api/v2/databases/{DB}/schemas/{SCH}/mcp-servers/{srv}")
        rm = requests.get(meta, timeout=30)
        print(f"  RFC 9728 metadata -> HTTP {rm.status_code}")
        if rm.ok:
            j = rm.json()
            print(f"    authorization_servers : {j.get('authorization_servers')}")
            print(f"    scopes_supported      : {j.get('scopes_supported')}")


def cmd_list():
    for kind, c in CLIENTS.items():
        print(f"\n=== tools/list — {c['server']} (as {c['role']}) ===")
        resp  = rpc(kind, "tools/list")
        tools = resp.get("result", {}).get("tools", [])
        if not tools:
            print(f"  no tools. raw: {json.dumps(resp)[:400]}")
            continue
        for t in tools:
            print(f"  * {t.get('name')}")
            props = (t.get("inputSchema") or {}).get("properties", {})
            if props:
                print(f"      args: {', '.join(props.keys())}")


def _extract_agent_answer(blocks: list) -> tuple:
    """Unwrap a CORTEX_AGENT_RUN response.

    The MCP result carries a single text block whose payload is itself a JSON
    envelope: {"content": [ {thinking}, {tool_use}, {tool_result}, ..., {text} ]}
    Returns (answer_text, [tool names used]).
    """
    answer, tools = "", []

    for b in blocks:
        raw = b.get("text", "") if b.get("type") == "text" else ""
        if not raw:
            continue

        # Plain-text answer (no envelope).
        if not raw.lstrip().startswith("{"):
            if len(raw) > len(answer):
                answer = raw
            continue

        try:
            inner = json.loads(raw).get("content", [])
        except json.JSONDecodeError:
            if len(raw) > len(answer):
                answer = raw
            continue

        for part in inner:
            ptype = part.get("type")
            if ptype == "tool_use":
                nm = (part.get("tool_use") or {}).get("name")
                if nm and nm not in tools:
                    tools.append(nm)
            elif ptype == "text":
                txt = part.get("text", "")
                if len(txt) > len(answer):
                    answer = txt

    return answer, tools


def cmd_ask(question: str):
    print(f"\n=== tools/call citadel_agent ===\nQ: {question}")
    # NOTE: the CORTEX_AGENT_RUN tool's argument is named "text" (confirmed via
    # tools/list inputSchema) — not "message".
    resp = rpc("reader", "tools/call",
               {"name": "citadel_agent", "arguments": {"text": question}})

    if "error" in resp:
        print(f"  ERROR: {json.dumps(resp['error'])[:600]}")
        return

    blocks = resp.get("result", {}).get("content", [])
    answer, tools = _extract_agent_answer(blocks)

    if tools:
        print(f"\n  agent orchestrated {len(tools)} tool(s): {', '.join(tools)}")

    if not answer:
        print(f"  no answer text found. raw: {json.dumps(resp)[:600]}")
        return

    print(f"\n--- answer ({len(answer)} chars) ---\n")
    print(answer[:4000])


def cmd_write(flag_id: int, account_id: int):
    """Full signal -> finding -> audit chain over MCP. MUTATES DATA."""
    print("\n" + "=" * 62)
    print("WRITE CHAIN over MCP — this mutates real data")
    print("=" * 62)

    print(f"\n[1/3] file_sar_draft(p_flag_id={flag_id})")
    r1 = rpc("action", "tools/call",
             {"name": "file_sar_draft",
              "arguments": {"p_flag_id": flag_id,
                            "p_notes": "Filed via MCP endpoint test harness"}})
    print(json.dumps(r1, indent=2)[:700])

    print(f"\n[2/3] flag_account(p_account_id={account_id})")
    r2 = rpc("action", "tools/call",
             {"name": "flag_account",
              "arguments": {"p_account_id": account_id,
                            "p_reason": "MCP harness — confirmed fraud pattern",
                            "p_linked_flag_id": flag_id}})
    print(json.dumps(r2, indent=2)[:700])

    print("\n[3/3] escalate_case — needs a case_id from step 2")
    print("      Look up the open case, then run:")
    print('      python test_mcp.py escalate <case_id>')

    print("\nVerify the immutable trail:")
    print("  SELECT log_id, action_type, object_type, object_id, actor_role, event_ts")
    print("  FROM CITADEL_DB.RISK.AUDIT_LOG ORDER BY log_id DESC LIMIT 10;")


def cmd_escalate(case_id: int):
    print(f"\n=== tools/call escalate_case(p_case_id={case_id}) ===")
    r = rpc("action", "tools/call",
            {"name": "escalate_case",
             "arguments": {"p_case_id": case_id,
                           "p_escalate_to": "compliance.officer@citadel.bank",
                           "p_notes": "Escalated via MCP endpoint test harness"}})
    print(json.dumps(r, indent=2)[:700])


def cmd_full(flag_id: int, account_id: int):
    """End-to-end: consent if needed -> READ endpoint -> WRITE endpoint -> audit."""
    cache = load_cache()
    if not cache.get("action", {}).get("refresh_token"):
        print("No cached token — running one-time consent first.")
        authorize("action")

    print("\n" + "#" * 64)
    print("#  PART 1 — READ ENDPOINT   (CITADEL_AGENT_MCP_SERVER)")
    print("#" * 64)
    print("\n[1a] tools/list")
    resp  = rpc("reader", "tools/list")
    tools = resp.get("result", {}).get("tools", [])
    print(f"     -> {len(tools)} tool(s): {', '.join(t.get('name','?') for t in tools)}")

    print("\n[1b] tools/call citadel_agent")
    cmd_ask("Which accounts have open structuring flags, and what does "
            "FinCEN require me to file?")

    print("\n" + "#" * 64)
    print("#  PART 2 — WRITE ENDPOINT  (CITADEL_ACTIONS_MCP_SERVER)")
    print("#" * 64)
    print("\n[2a] tools/list")
    resp  = rpc("action", "tools/list")
    tools = resp.get("result", {}).get("tools", [])
    print(f"     -> {len(tools)} tool(s): {', '.join(t.get('name','?') for t in tools)}")

    print(f"\n[2b] tools/call file_sar_draft(p_flag_id={flag_id})")
    r1 = rpc("action", "tools/call",
             {"name": "file_sar_draft",
              "arguments": {"p_flag_id": flag_id,
                            "p_notes": "Filed via MCP write-endpoint test"}})
    _show_action_result(r1)

    print(f"\n[2c] tools/call flag_account(p_account_id={account_id})")
    r2 = rpc("action", "tools/call",
             {"name": "flag_account",
              "arguments": {"p_account_id": account_id,
                            "p_reason": "MCP write-endpoint test — confirmed pattern",
                            "p_linked_flag_id": flag_id}})
    case_id = _show_action_result(r2)

    if case_id:
        print(f"\n[2d] tools/call escalate_case(p_case_id={case_id})")
        r3 = rpc("action", "tools/call",
                 {"name": "escalate_case",
                  "arguments": {"p_case_id": case_id,
                                "p_escalate_to": "compliance.officer@citadel.bank",
                                "p_notes": "Escalated via MCP write-endpoint test"}})
        _show_action_result(r3)
    else:
        print("\n[2d] escalate_case skipped — no case_id returned by flag_account.")

    print("\n" + "#" * 64)
    print("#  PART 3 — VERIFY THE IMMUTABLE TRAIL")
    print("#" * 64)
    print("\nRun this in SQL to confirm the chain was recorded:\n")
    print("  SELECT log_id, action_type, object_type, object_id,")
    print("         actor_user, actor_role, change_summary, event_ts")
    print("  FROM CITADEL_DB.RISK.AUDIT_LOG")
    print("  ORDER BY log_id DESC LIMIT 10;\n")
    print("actor_role should read CITADEL_COMPLIANCE_OFFICER for MCP-driven actions.")


def _show_action_result(resp: dict):
    """Print a GENERIC tool result; return case_id if the payload carries one."""
    if "error" in resp:
        print(f"     ERROR: {json.dumps(resp['error'])[:400]}")
        return None

    for block in resp.get("result", {}).get("content", []):
        if block.get("type") != "text":
            continue
        raw = block.get("text", "")
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            print(f"     {raw[:400]}")
            continue

        if isinstance(payload, dict) and payload.get("error"):
            print(f"     BLOCKED: {payload['error']}")
            return None

        print(f"     OK: {json.dumps(payload)[:400]}")
        if isinstance(payload, dict):
            for k in ("case_id", "CASE_ID", "new_case_id"):
                if payload.get(k):
                    return int(payload[k])
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1].lower()

    if cmd == "discover":
        cmd_discover()
    elif cmd == "auth":
        if len(sys.argv) < 3 or sys.argv[2] not in CLIENTS:
            sys.exit("usage: python test_mcp.py auth [reader|action]")
        authorize(sys.argv[2])
    elif cmd == "list":
        cmd_list()
    elif cmd == "ask":
        if len(sys.argv) < 3:
            sys.exit('usage: python test_mcp.py ask "question"')
        cmd_ask(" ".join(sys.argv[2:]))
    elif cmd == "write":
        if len(sys.argv) < 4:
            sys.exit("usage: python test_mcp.py write <flag_id> <account_id>")
        cmd_write(int(sys.argv[2]), int(sys.argv[3]))
    elif cmd == "escalate":
        if len(sys.argv) < 3:
            sys.exit("usage: python test_mcp.py escalate <case_id>")
        cmd_escalate(int(sys.argv[2]))
    elif cmd == "full":
        fid = int(sys.argv[2]) if len(sys.argv) > 2 else 5445
        aid = int(sys.argv[3]) if len(sys.argv) > 3 else 126
        cmd_full(fid, aid)
    elif cmd == "all":
        cmd_discover()
        cmd_list()
        cmd_ask("How many open fraud flags are there, and what regulation "
                "applies to structuring?")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()

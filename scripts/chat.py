"""
chat.py — Interactive terminal chat with CITADEL_AGENT.

Usage:
    python scripts/chat.py [--connection <name>] [--thread-id <id>]

  --connection  Snowflake connection name (default: Sept-6_AHap or SNOWFLAKE_CONNECTION_NAME)
  --thread-id   Resume a specific conversation thread ID (optional)
  --no-stream   Disable streaming (wait for full response)

Sends messages to CITADEL_DB.RISK.CITADEL_AGENT via the Snowflake Cortex Agent
REST API (POST /api/v2/cortex/agent:run) with server-sent event streaming.

Authentication: uses session token from the Snowflake connector.
Set SNOWFLAKE_PAT env var to use a Personal Access Token instead.

Exit: Ctrl+C or type 'exit', 'quit', or '/q'

Required packages:
    pip install snowflake-connector-python requests sseclient-py
"""

import argparse
import json
import os
import sys
import time
import uuid
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from citadel_config import (
    get_connection, get_account_url, get_auth_headers, get_pat_headers,
    AGENT_FQN
)

try:
    import requests
    import sseclient
    _HAS_SSE = True
except ImportError:
    import requests
    _HAS_SSE = False

RESET  = "\033[0m"
BOLD   = "\033[1m"
CYAN   = "\033[36m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
DIM    = "\033[2m"

AGENT_ENDPOINT = "/api/v2/cortex/agent:run"


def build_request_body(message: str, thread_id: str | None) -> dict:
    body = {
        "model": "claude-sonnet-4-6",
        "messages": [
            {
                "role": "user",
                "content": [{"type": "text", "text": message}]
            }
        ],
        "agent": AGENT_FQN,
        "experimental": {"output_mode": "stream"}
    }
    if thread_id:
        body["thread_id"] = thread_id
    return body


def extract_text_from_event(event_data: str) -> str:
    """Parse a single SSE data line and return any assistant text content."""
    if not event_data or event_data.strip() in ("[DONE]", ""):
        return ""
    try:
        obj = json.loads(event_data)
        # Snowflake Cortex Agent SSE format:
        # {"choices": [{"delta": {"content": [{"type": "text", "text": "..."}]}}]}
        choices = obj.get("choices", [])
        for choice in choices:
            delta = choice.get("delta", {})
            content = delta.get("content", [])
            for block in content:
                if block.get("type") == "text":
                    return block.get("text", "")
        # Also handle tool_use markers for display
        for choice in choices:
            delta = choice.get("delta", {})
            content = delta.get("content", [])
            for block in content:
                if block.get("type") == "tool_use":
                    tool_name = block.get("name", "")
                    return f"\n{DIM}[calling {tool_name}...]{RESET}"
    except json.JSONDecodeError:
        pass
    return ""


def stream_agent_response(
    base_url: str,
    headers: dict,
    message: str,
    thread_id: str | None,
    no_stream: bool,
) -> tuple[str, str | None]:
    """
    Call the Cortex Agent REST API and stream/return the response.
    Returns (full_response_text, returned_thread_id).
    """
    url  = base_url + AGENT_ENDPOINT
    body = build_request_body(message, thread_id)

    if no_stream:
        body["experimental"]["output_mode"] = "complete"

    try:
        resp = requests.post(url, headers=headers, json=body, stream=True, timeout=120)
    except requests.exceptions.ConnectionError as e:
        return f"[Connection error: {e}]", thread_id

    if resp.status_code == 401:
        return "[Authentication failed. Check your connection credentials or set SNOWFLAKE_PAT.]", thread_id
    if resp.status_code == 403:
        return "[Forbidden. Ensure your role has USAGE on CITADEL_AGENT.]", thread_id
    if not resp.ok:
        return f"[HTTP {resp.status_code}: {resp.text[:300]}]", thread_id

    full_text = ""
    returned_thread = thread_id

    if no_stream:
        try:
            data = resp.json()
            choices = data.get("choices", [])
            for choice in choices:
                content = choice.get("message", {}).get("content", [])
                for block in content:
                    if block.get("type") == "text":
                        full_text += block.get("text", "")
            returned_thread = data.get("thread_id", thread_id)
        except Exception as e:
            full_text = f"[Parse error: {e}]"
    else:
        # Stream SSE
        print(f"\n{GREEN}CITADEL{RESET}  ", end="", flush=True)
        for line in resp.iter_lines():
            if not line:
                continue
            decoded = line.decode("utf-8") if isinstance(line, bytes) else line
            if decoded.startswith("data: "):
                chunk = extract_text_from_event(decoded[6:])
                if chunk:
                    print(chunk, end="", flush=True)
                    full_text += chunk
            elif decoded.startswith("id: "):
                pass  # event ID
            elif decoded.startswith("event: "):
                pass
            # Extract thread_id from response headers if present
        returned_thread = resp.headers.get("X-Thread-Id", thread_id)
        print()  # newline after streaming

    return full_text, returned_thread


def run(connection_name: str | None, thread_id: str | None, no_stream: bool) -> None:
    conn = get_connection(connection_name)
    base_url = get_account_url(conn)

    # Prefer PAT if available (more reliable for REST API)
    headers = get_pat_headers()
    auth_method = "PAT"
    if headers is None:
        try:
            headers = get_auth_headers(conn)
            auth_method = "session token"
        except RuntimeError as e:
            print(f"\n  Error: {e}")
            print("  Set SNOWFLAKE_PAT to your Personal Access Token and retry.")
            conn.close()
            return

    print(f"\n{BOLD}CITADEL — Risk, Fraud & Regulatory Intelligence Copilot{RESET}")
    print(f"  Agent   : {AGENT_FQN}")
    print(f"  Auth    : {auth_method}")
    if thread_id:
        print(f"  Thread  : {thread_id} (resuming)")
    print(f"\nType your question and press Enter. Commands: /q to quit, /thread to show thread ID.\n")
    print(f"{DIM}{'─' * 60}{RESET}")

    current_thread = thread_id

    while True:
        try:
            user_input = input(f"\n{CYAN}You{RESET}  ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\n\nGoodbye.")
            break

        if not user_input:
            continue
        if user_input.lower() in ("exit", "quit", "/q"):
            print("Goodbye.")
            break
        if user_input.lower() == "/thread":
            print(f"  Current thread ID: {current_thread or '(none — new thread will be created)'}")
            continue
        if user_input.lower() == "/new":
            current_thread = None
            print("  Started new conversation thread.")
            continue
        if user_input.lower() == "/help":
            print("  Commands: /q quit | /thread show thread ID | /new start new thread | /help this message")
            continue

        response_text, current_thread = stream_agent_response(
            base_url, headers, user_input, current_thread, no_stream
        )

        # If not streaming (no_stream mode), print the response now
        if no_stream and response_text:
            print(f"\n{GREEN}CITADEL{RESET}  {response_text}")

        if current_thread:
            print(f"\n{DIM}  thread: {current_thread}{RESET}")

    conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Interactive chat with CITADEL_AGENT",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment variables:
  SNOWFLAKE_CONNECTION_NAME  Connection name (default: Sept-6_AHap)
  SNOWFLAKE_PAT              Personal Access Token (preferred for REST API)
  SNOWFLAKE_ACCOUNT          Account identifier (alternative to connections.toml)
  SNOWFLAKE_USER             Username
  SNOWFLAKE_PASSWORD         Password
        """
    )
    parser.add_argument("--connection", default=None,        help="Snowflake connection name")
    parser.add_argument("--thread-id",  default=None,        help="Resume a conversation thread")
    parser.add_argument("--no-stream",  action="store_true", help="Disable response streaming")
    args = parser.parse_args()
    run(args.connection, args.thread_id, args.no_stream)


if __name__ == "__main__":
    main()

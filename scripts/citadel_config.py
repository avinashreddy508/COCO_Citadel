"""
citadel_config.py — Shared connection helper for all Citadel scripts.

Usage (imported by other scripts):
    from citadel_config import get_connection, AGENT_FQN, SEMANTIC_VIEW_FQN

Authentication: reads from ~/.snowflake/connections.toml or environment variables.
Set SNOWFLAKE_CONNECTION_NAME env var to switch connections (default: Sept-6_AHap).

Required packages:
    pip install snowflake-connector-python requests
"""

import os
import sys
import json
import pathlib
import tomllib
import requests
import snowflake.connector
from snowflake.connector import SnowflakeConnection

# ─── Citadel object coordinates ──────────────────────────────────────────────
DATABASE            = "CITADEL_DB"
SCHEMA              = "RISK"
WAREHOUSE           = "CITADEL_WH"
AGENT_NAME          = "CITADEL_AGENT"
SEMANTIC_VIEW_NAME  = "CITADEL_RISK_INTELLIGENCE"
SEARCH_SERVICE_NAME = "CITADEL_SEARCH_SVC"

AGENT_FQN           = f"{DATABASE}.{SCHEMA}.{AGENT_NAME}"
SEMANTIC_VIEW_FQN   = f"{DATABASE}.{SCHEMA}.{SEMANTIC_VIEW_NAME}"
SEARCH_SVC_FQN      = f"{DATABASE}.{SCHEMA}.{SEARCH_SERVICE_NAME}"

SEMANTIC_MODEL_YAML = pathlib.Path(__file__).parent.parent / "citadel_semantic_model.yaml"

# ─── Connection helper ────────────────────────────────────────────────────────
_CONNECTIONS_TOML = pathlib.Path.home() / ".snowflake" / "connections.toml"
_DEFAULT_CONNECTION = os.environ.get("SNOWFLAKE_CONNECTION_NAME", "Sept-6_AHap")


def _load_connection_params(connection_name: str) -> dict:
    """Read connection params from ~/.snowflake/connections.toml."""
    if not _CONNECTIONS_TOML.exists():
        raise FileNotFoundError(
            f"connections.toml not found at {_CONNECTIONS_TOML}. "
            "Set SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD env vars instead."
        )
    with open(_CONNECTIONS_TOML, "rb") as f:
        toml = tomllib.load(f)
    if connection_name not in toml:
        available = ", ".join(toml.keys())
        raise KeyError(
            f"Connection '{connection_name}' not found in connections.toml. "
            f"Available: {available}"
        )
    return toml[connection_name]


def get_connection(connection_name: str | None = None) -> SnowflakeConnection:
    """
    Return an open Snowflake connection.

    Priority order for credentials:
      1. connection_name argument (or SNOWFLAKE_CONNECTION_NAME env var)
      2. SNOWFLAKE_ACCOUNT / SNOWFLAKE_USER / SNOWFLAKE_PASSWORD env vars
      3. ~/.snowflake/connections.toml
    """
    name = connection_name or _DEFAULT_CONNECTION

    # Env vars override everything
    account  = os.environ.get("SNOWFLAKE_ACCOUNT")
    user     = os.environ.get("SNOWFLAKE_USER")
    password = os.environ.get("SNOWFLAKE_PASSWORD")

    if account and user and password:
        params = {"account": account, "user": user, "password": password}
    else:
        params = _load_connection_params(name)

    params.setdefault("database",  DATABASE)
    params.setdefault("schema",    SCHEMA)
    params.setdefault("warehouse", WAREHOUSE)

    conn = snowflake.connector.connect(**params)
    return conn


def get_account_url(conn: SnowflakeConnection) -> str:
    """Return the base HTTPS URL for REST API calls, e.g. https://JSTEYZM-MP60447.snowflakecomputing.com."""
    host = conn.host  # e.g. jsteyzm-mp60447.snowflakecomputing.com
    return f"https://{host}"


def get_auth_headers(conn: SnowflakeConnection) -> dict:
    """
    Build Authorization headers for the Snowflake REST API using the active session token.
    The token is extracted from the connector's internal REST client.
    """
    try:
        token = conn.rest.token
        return {
            "Authorization":  f"Snowflake Token=\"{token}\"",
            "Content-Type":   "application/json",
            "Accept":         "application/json",
            "X-Snowflake-Authorization-Token-Type": "OAUTH",
        }
    except AttributeError:
        # Fallback: use the session token via a SQL call
        cur = conn.cursor()
        cur.execute("SELECT SYSTEM$GENERATE_SCIM_ACCESS_TOKEN()")
        # This is a placeholder — in production use a proper OAuth flow
        raise RuntimeError(
            "Could not extract session token automatically. "
            "Use a PAT (Personal Access Token) by setting SNOWFLAKE_PAT env var."
        )


def get_pat_headers() -> dict | None:
    """Return auth headers using SNOWFLAKE_PAT env var if set, else None."""
    pat = os.environ.get("SNOWFLAKE_PAT")
    if not pat:
        return None
    return {
        "Authorization":  f"Bearer {pat}",
        "Content-Type":   "application/json",
        "Accept":         "application/json",
    }


def execute_sql(conn: SnowflakeConnection, sql: str) -> list[dict]:
    """Execute SQL and return rows as list of dicts."""
    cur = conn.cursor(snowflake.connector.DictCursor)
    cur.execute(sql)
    return cur.fetchall()


def print_table(rows: list[dict], max_col_width: int = 60) -> None:
    """Print a list of dicts as a formatted ASCII table."""
    if not rows:
        print("  (no rows)")
        return
    headers = list(rows[0].keys())
    widths  = {h: min(len(str(h)), max_col_width) for h in headers}
    for row in rows:
        for h in headers:
            widths[h] = max(widths[h], min(len(str(row.get(h, ""))), max_col_width))

    sep = "+" + "+".join("-" * (w + 2) for w in widths.values()) + "+"
    print(sep)
    print("|" + "|".join(f" {h:<{widths[h]}} " for h in headers) + "|")
    print(sep)
    for row in rows:
        def cell(h):
            v = str(row.get(h, ""))
            return v[:max_col_width - 3] + "..." if len(v) > max_col_width else v
        print("|" + "|".join(f" {cell(h):<{widths[h]}} " for h in headers) + "|")
    print(sep)
    print(f"  {len(rows)} row(s)")

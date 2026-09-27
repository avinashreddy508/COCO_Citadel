"""
deploy_semantic_view.py — Deploy or update the CITADEL_RISK_INTELLIGENCE semantic view.

Usage:
    python scripts/deploy_semantic_view.py [--connection <name>] [--verify-only]

  --verify-only   Validate the YAML without creating/replacing the semantic view.
  --force         Replace the semantic view even if it already exists (default: True).

The semantic model YAML is loaded from:
    <project_root>/citadel_semantic_model.yaml

This script calls SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML which is the Snowflake-native
deployment path for Cortex Analyst semantic models.

Required packages:
    pip install snowflake-connector-python
"""

import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from citadel_config import (
    get_connection, execute_sql, DATABASE, SCHEMA,
    SEMANTIC_VIEW_FQN, SEMANTIC_MODEL_YAML
)

PASS = "\033[32m✓\033[0m"
FAIL = "\033[31m✗\033[0m"
INFO = "\033[34mℹ\033[0m"


def load_yaml(path: pathlib.Path) -> str:
    if not path.exists():
        raise FileNotFoundError(
            f"Semantic model YAML not found: {path}\n"
            "Make sure you are running from the citadel/ directory."
        )
    content = path.read_text(encoding="utf-8")
    print(f"  {INFO}  Loaded YAML: {path.name} ({len(content):,} chars)")
    return content


def validate_yaml(conn, yaml_content: str) -> bool:
    """Run verify-only validation. Returns True if valid."""
    print(f"\n  Validating semantic model YAML (verify-only mode)...")
    try:
        conn.cursor().execute(
            f"CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('{DATABASE}.{SCHEMA}', "
            f"$${yaml_content}$$, TRUE)"
        )
        print(f"  {PASS}  YAML is valid.")
        return True
    except Exception as e:
        msg = str(e)
        print(f"  {FAIL}  Validation failed:\n    {msg}")
        return False


def deploy_yaml(conn, yaml_content: str) -> bool:
    """Deploy the semantic view (CREATE OR REPLACE). Returns True on success."""
    print(f"\n  Deploying CITADEL_RISK_INTELLIGENCE to {DATABASE}.{SCHEMA}...")
    start = time.time()
    try:
        conn.cursor().execute(
            f"CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML('{DATABASE}.{SCHEMA}', "
            f"$${yaml_content}$$, FALSE)"
        )
        elapsed = time.time() - start
        print(f"  {PASS}  Semantic view deployed in {elapsed:.1f}s")
        return True
    except Exception as e:
        msg = str(e)
        print(f"  {FAIL}  Deployment failed:\n    {msg}")
        return False


def verify_exists(conn) -> bool:
    """Check the semantic view exists after deployment."""
    rows = execute_sql(
        conn,
        f"SHOW SEMANTIC VIEWS LIKE 'CITADEL_RISK_INTELLIGENCE' IN SCHEMA {DATABASE}.{SCHEMA}"
    )
    return bool(rows)


def grant_access(conn) -> None:
    """Grant SELECT on the semantic view to all Citadel roles."""
    roles = [
        "CITADEL_RISK_ANALYST",
        "CITADEL_RISK_MANAGER",
        "CITADEL_COMPLIANCE_OFFICER",
        "CITADEL_AUDITOR",
    ]
    print("\n  Granting SELECT to Citadel roles...")
    for role in roles:
        try:
            conn.cursor().execute(
                f"GRANT SELECT ON SEMANTIC VIEW {SEMANTIC_VIEW_FQN} TO ROLE {role}"
            )
            print(f"    {PASS}  {role}")
        except Exception as e:
            print(f"    {FAIL}  {role}: {e}")


def run(connection_name: str | None, verify_only: bool) -> int:
    conn = get_connection(connection_name)
    print(f"\nCITADEL — Semantic View Deployment")
    print(f"  Target  : {SEMANTIC_VIEW_FQN}")
    print(f"  Account : {conn.account}")
    print(f"  Mode    : {'verify-only' if verify_only else 'deploy'}")

    # Load YAML
    try:
        yaml_content = load_yaml(SEMANTIC_MODEL_YAML)
    except FileNotFoundError as e:
        print(f"\n  {FAIL}  {e}")
        conn.close()
        return 1

    if verify_only:
        ok = validate_yaml(conn, yaml_content)
    else:
        ok = deploy_yaml(conn, yaml_content)
        if ok:
            exists = verify_exists(conn)
            if exists:
                print(f"  {PASS}  Verified: semantic view exists in {DATABASE}.{SCHEMA}")
                grant_access(conn)
            else:
                print(f"  {FAIL}  Semantic view not found after deployment.")
                ok = False

    conn.close()
    return 0 if ok else 1


def main() -> None:
    parser = argparse.ArgumentParser(description="Deploy Citadel semantic view to Snowflake")
    parser.add_argument("--connection",   default=None,        help="Snowflake connection name")
    parser.add_argument("--verify-only",  action="store_true", help="Validate YAML without deploying")
    args = parser.parse_args()
    sys.exit(run(args.connection, args.verify_only))


if __name__ == "__main__":
    main()

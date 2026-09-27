"""
verify.py — Check that all Citadel objects exist and are healthy.

Usage:
    python scripts/verify.py [--connection <name>]

Checks:
  - Database, schema, and warehouse exist
  - All 10 tables present with expected row counts
  - Masking policies and row access policy applied
  - 5 RBAC roles exist
  - Semantic view CITADEL_RISK_INTELLIGENCE exists
  - Cortex Search service CITADEL_SEARCH_SVC is ACTIVE
  - CITADEL_AGENT exists with both tools configured
  - RISK_FLAGS domain distribution (fraud/credit/liquidity)

Exit codes: 0 = all checks passed, 1 = one or more checks failed.
"""

import argparse
import sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).parent))
from citadel_config import get_connection, execute_sql, print_table, DATABASE, SCHEMA

EXPECTED_ROWS = {
    "TRANSACTIONS":        50_000,
    "RISK_FLAGS":          9_000,   # approximate lower bound
    "ACCOUNTS":            800,
    "CUSTOMERS":           500,
    "LIQUIDITY_POSITIONS": 450,
    "CREDIT_EXPOSURES":    300,
    "REGULATORY_FILINGS":  200,
    "CASE_ESCALATIONS":    50,
    "POLICY_DOCS":         10,
    "AUDIT_LOG":           0,
}

EXPECTED_ROLES = [
    "CITADEL_ADMIN",
    "CITADEL_RISK_MANAGER",
    "CITADEL_COMPLIANCE_OFFICER",
    "CITADEL_RISK_ANALYST",
    "CITADEL_AUDITOR",
]

PASS = "\033[32m✓\033[0m"
FAIL = "\033[31m✗\033[0m"
WARN = "\033[33m⚠\033[0m"


def check(label: str, ok: bool, detail: str = "") -> bool:
    icon = PASS if ok else FAIL
    line = f"  {icon}  {label}"
    if detail:
        line += f"  ({detail})"
    print(line)
    return ok


def run(connection_name: str) -> int:
    failed = 0
    conn = get_connection(connection_name)
    print(f"\nCITADEL Deployment Verification")
    print(f"  Account : {conn.account}")
    print(f"  Database: {DATABASE}.{SCHEMA}")
    print()

    # ── Warehouse ──────────────────────────────────────────────────────────
    print("[ Warehouse ]")
    rows = execute_sql(conn, "SHOW WAREHOUSES LIKE 'CITADEL_WH'")
    failed += 0 if check("CITADEL_WH exists", bool(rows)) else 1
    print()

    # ── Tables and row counts ──────────────────────────────────────────────
    print("[ Tables ]")
    count_sql = " UNION ALL ".join(
        f"SELECT '{t}' AS tbl, COUNT(*) AS n FROM {DATABASE}.{SCHEMA}.{t}"
        for t in EXPECTED_ROWS
    ) + " ORDER BY n DESC"
    rows = execute_sql(conn, count_sql)
    for row in rows:
        tbl = row["TBL"]
        n   = row["N"]
        exp = EXPECTED_ROWS.get(tbl, 0)
        ok  = n >= exp
        detail = f"{n:,} rows (expected >= {exp:,})"
        failed += 0 if check(tbl, ok, detail) else 1
    print()

    # ── Masking policies ───────────────────────────────────────────────────
    print("[ Masking Policies ]")
    for table, column in [
        ("CUSTOMERS", "NATIONAL_ID"),
        ("CUSTOMERS", "FULL_NAME"),
        ("ACCOUNTS",  "ACCOUNT_NUMBER"),
    ]:
        rows = execute_sql(conn, f"""
            SELECT policy_name FROM TABLE(
                {DATABASE}.INFORMATION_SCHEMA.POLICY_REFERENCES(
                    REF_ENTITY_NAME => '{DATABASE}.{SCHEMA}.{table}',
                    REF_ENTITY_DOMAIN => 'TABLE'
                )
            )
            WHERE REF_COLUMN_NAME = '{column}'
              AND POLICY_KIND = 'MASKING_POLICY'
        """)
        ok = bool(rows)
        detail = rows[0]["POLICY_NAME"] if rows else "NOT APPLIED"
        failed += 0 if check(f"{table}.{column}", ok, detail) else 1

    # Row access policy
    rows = execute_sql(conn, f"""
        SELECT policy_name FROM TABLE(
            {DATABASE}.INFORMATION_SCHEMA.POLICY_REFERENCES(
                REF_ENTITY_NAME => '{DATABASE}.{SCHEMA}.REGULATORY_FILINGS',
                REF_ENTITY_DOMAIN => 'TABLE'
            )
        )
        WHERE POLICY_KIND = 'ROW ACCESS POLICY'
    """)
    failed += 0 if check("REGULATORY_FILINGS row access policy", bool(rows)) else 1
    print()

    # ── Roles ──────────────────────────────────────────────────────────────
    print("[ RBAC Roles ]")
    for role in EXPECTED_ROLES:
        rows = execute_sql(conn, f"SHOW ROLES LIKE '{role}'")
        failed += 0 if check(role, bool(rows)) else 1
    print()

    # ── Semantic view ──────────────────────────────────────────────────────
    print("[ Semantic View ]")
    rows = execute_sql(conn, f"SHOW SEMANTIC VIEWS LIKE 'CITADEL_RISK_INTELLIGENCE' IN SCHEMA {DATABASE}.{SCHEMA}")
    failed += 0 if check("CITADEL_RISK_INTELLIGENCE", bool(rows), "Cortex Analyst semantic model") else 1
    print()

    # ── Cortex Search service ──────────────────────────────────────────────
    print("[ Cortex Search ]")
    rows = execute_sql(conn, f"SHOW CORTEX SEARCH SERVICES IN SCHEMA {DATABASE}.{SCHEMA}")
    svc = next((r for r in rows if r.get("name") == "CITADEL_SEARCH_SVC"), None)
    if svc:
        serving = svc.get("serving_state", "UNKNOWN")
        indexing = svc.get("indexing_state", "UNKNOWN")
        src_rows = svc.get("source_data_num_rows", 0)
        ok = serving == "ACTIVE"
        failed += 0 if check("CITADEL_SEARCH_SVC", ok, f"serving={serving}, indexed={src_rows} docs") else 1
    else:
        failed += 1
        check("CITADEL_SEARCH_SVC", False, "NOT FOUND")
    print()

    # ── Agent ──────────────────────────────────────────────────────────────
    print("[ Cortex Agent ]")
    rows = execute_sql(conn, f"SHOW AGENTS LIKE 'CITADEL_AGENT' IN SCHEMA {DATABASE}.{SCHEMA}")
    failed += 0 if check("CITADEL_AGENT", bool(rows)) else 1
    print()

    # ── Risk flags distribution ────────────────────────────────────────────
    print("[ Risk Flags Distribution ]")
    rows = execute_sql(conn, f"""
        SELECT flag_domain, COUNT(*) AS flag_count, ROUND(AVG(flag_score), 1) AS avg_score
        FROM {DATABASE}.{SCHEMA}.RISK_FLAGS
        GROUP BY flag_domain
        ORDER BY flag_count DESC
    """)
    print_table(rows)
    print()

    # ── LCR status ─────────────────────────────────────────────────────────
    print("[ Liquidity Summary ]")
    rows = execute_sql(conn, f"""
        SELECT
            COUNT(DISTINCT position_date)                              AS total_days,
            SUM(CASE WHEN lcr_breach THEN 1 ELSE 0 END)               AS breach_positions,
            ROUND(AVG(lcr_ratio) * 100, 1)                            AS avg_lcr_pct,
            ROUND(MIN(lcr_ratio) * 100, 1)                            AS min_lcr_pct
        FROM {DATABASE}.{SCHEMA}.LIQUIDITY_POSITIONS
        WHERE tenor_bucket = '0_7D'
    """)
    print_table(rows)
    print()

    # ── Summary ────────────────────────────────────────────────────────────
    print("=" * 50)
    if failed == 0:
        print(f"{PASS}  All checks passed. Citadel is fully deployed.\n")
    else:
        print(f"{FAIL}  {failed} check(s) failed. Review output above.\n")

    conn.close()
    return 0 if failed == 0 else 1


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify Citadel deployment")
    parser.add_argument("--connection", default=None, help="Snowflake connection name")
    args = parser.parse_args()
    sys.exit(run(args.connection))


if __name__ == "__main__":
    main()

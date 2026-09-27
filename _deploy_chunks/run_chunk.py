"""Execute a SQL file against the vfwiqmm-hb26136 account, one statement at a
time, using the connector's own statement splitter directly (not
execute_string's generator) so a failure on statement N doesn't hide whether
statements 1..N-1 actually succeeded."""
import io
import sys
import tomllib
import pathlib
import snowflake.connector
from snowflake.connector.util_text import split_statements

chunk_file = sys.argv[1]

cfg_path = pathlib.Path.home() / ".snowflake" / "connections.toml"
cfg = tomllib.load(open(cfg_path, "rb"))["vfwiqmm-hb26136"]

conn = snowflake.connector.connect(
    account=cfg["account"],
    user=cfg["user"],
    password=cfg["password"],
)
cur = conn.cursor()

sql_text = pathlib.Path(chunk_file).read_text(encoding="utf-8")
statements = [s for s, _ in split_statements(io.StringIO(sql_text), remove_comments=True) if s.strip()]

print(f"{len(statements)} statement(s) found in {chunk_file}\n")

ok = 0
for i, stmt in enumerate(statements, 1):
    preview = stmt.strip().replace("\n", " ")[:100]
    try:
        cur.execute(stmt)
        cur.fetchall()
        print(f"OK  {i:>3}/{len(statements)} | {preview}")
        ok += 1
    except Exception as e:
        print(f"ERR {i:>3}/{len(statements)} | {preview}")
        print(f"    -> {e}")

print(f"\n{chunk_file}: {ok}/{len(statements)} statements succeeded.")
conn.close()
sys.exit(0 if ok == len(statements) else 1)

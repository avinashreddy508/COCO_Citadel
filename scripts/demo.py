"""
demo.py — Run all 8 Citadel demo questions against CITADEL_AGENT and save results.

Usage:
    python scripts/demo.py [--connection <name>] [--output <dir>] [--question <N>]

  --output     Directory to save JSON result files (default: ./demo_results/)
  --question   Run only question N (1-8); default runs all
  --list       Print the list of demo questions and exit

The 8 demo questions correspond to the verified queries pre-registered in
CITADEL_RISK_INTELLIGENCE and cover all three risk domains:
  1-3  Fraud / AML
  4-5  Multi-domain risk
  6    Credit risk
  7    Credit / RWA
  8    Liquidity

Results are saved as:
  demo_results/q01_fraud_flags_this_week.json
  demo_results/q02_structuring_detail.json
  ...
  demo_results/summary.json

Required packages:
    pip install snowflake-connector-python requests
"""

import argparse
import json
import os
import pathlib
import sys
import time
import datetime

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from citadel_config import (
    get_connection, get_account_url, get_auth_headers, get_pat_headers,
    AGENT_FQN
)
import requests

PASS = "\033[32m✓\033[0m"
FAIL = "\033[31m✗\033[0m"
INFO = "\033[34mℹ\033[0m"
BOLD = "\033[1m"
RESET = "\033[0m"

AGENT_ENDPOINT = "/api/v2/cortex/agent:run"

DEMO_QUESTIONS = [
    {
        "id": "q01",
        "slug": "fraud_flags_this_week",
        "domain": "FRAUD",
        "question": "Which accounts show fraud-risk patterns this week? Include the fraud pattern type, flag score, and the regulatory basis for each pattern.",
        "expected_tool": "RiskSignalAnalytics",
        "pitch_notes": "Demonstrates VELOCITY/STRUCTURING/CROSS_BORDER/ROUND_NUMBER detection with regulatory citations (FinCEN SAR 35a, 31 CFR 1010.314, FATF R.19)"
    },
    {
        "id": "q02",
        "slug": "structuring_detail",
        "domain": "FRAUD / AML",
        "question": "Show me the structuring transactions and the customers behind them. Are any of these customers PEPs?",
        "expected_tool": "RiskSignalAnalytics",
        "pitch_notes": "Joins fraud flags to customer PEP status — FATF R.12 combined with BSA structuring rule"
    },
    {
        "id": "q03",
        "slug": "regulation_structuring",
        "domain": "REGULATION",
        "question": "What regulation applies to structuring transactions, and what are the SAR filing obligations when structuring is detected?",
        "expected_tool": "RegulatoryKnowledgeSearch",
        "pitch_notes": "Retrieves FinCEN CTR/SAR rules + internal AML policy AML-POL-003 — cites 31 USC 5324, 31 CFR 1010.314, and the tipping-off prohibition"
    },
    {
        "id": "q04",
        "slug": "high_risk_customers_fraud",
        "domain": "FRAUD + CREDIT",
        "question": "Which high-risk customers have open fraud flags this week? Show me their segment, flag scores, and whether they are PEPs or sanctioned.",
        "expected_tool": "RiskSignalAnalytics",
        "pitch_notes": "Cross-domain query combining customer risk rating with active fraud signals — FATF R.12 PEP mention expected"
    },
    {
        "id": "q05",
        "slug": "open_flags_summary",
        "domain": "ALL DOMAINS",
        "question": "Give me a summary of all open risk flags grouped by domain (fraud, credit, liquidity) and severity, with the average risk score for each group.",
        "expected_tool": "RiskSignalAnalytics",
        "pitch_notes": "Executive-level view across all three risk domains — good opening slide for a board risk committee"
    },
    {
        "id": "q06",
        "slug": "credit_watch_list_by_sector",
        "domain": "CREDIT",
        "question": "Show me the credit watch-list broken down by sector. Include outstanding balance, RWA, average PD, and Expected Loss for each sector.",
        "expected_tool": "RiskSignalAnalytics",
        "pitch_notes": "Basel III PD > 0.15 watch-list with RWA and ECL — real estate concentration finding visible"
    },
    {
        "id": "q07",
        "slug": "rwa_by_sector_rating",
        "domain": "CREDIT",
        "question": "What is the total RWA exposure by sector and internal rating? What does Basel III require in terms of minimum capital for this portfolio?",
        "expected_tool": "both",
        "pitch_notes": "Compound question: RiskSignalAnalytics for the RWA breakdown, RegulatoryKnowledgeSearch for the 8% Pillar 1 minimum capital rule"
    },
    {
        "id": "q08",
        "slug": "lcr_breach_detail",
        "domain": "LIQUIDITY",
        "question": "Show me the days where LCR was below 100%. What does Basel III require when an LCR breach is detected, and what is the supervisory notification timeline?",
        "expected_tool": "both",
        "pitch_notes": "Compound question: breach data + Basel III Art. 412 notification requirement (2 business days) — BCBS Jan 2013 §415 cited"
    },
]


def call_agent(
    base_url: str,
    headers: dict,
    question: str,
) -> tuple[str, float]:
    """Call CITADEL_AGENT and return (response_text, latency_seconds)."""
    url  = base_url + AGENT_ENDPOINT
    body = {
        "model": "claude-sonnet-4-6",
        "messages": [{"role": "user", "content": [{"type": "text", "text": question}]}],
        "agent": AGENT_FQN,
        "experimental": {"output_mode": "stream"}
    }

    start = time.time()
    full_text = ""

    try:
        resp = requests.post(url, headers=headers, json=body, stream=True, timeout=180)
    except requests.exceptions.ConnectionError as e:
        return f"[Connection error: {e}]", 0.0

    if not resp.ok:
        return f"[HTTP {resp.status_code}: {resp.text[:200]}]", 0.0

    for line in resp.iter_lines():
        if not line:
            continue
        decoded = line.decode("utf-8") if isinstance(line, bytes) else line
        if decoded.startswith("data: "):
            data = decoded[6:]
            if data.strip() in ("[DONE]", ""):
                continue
            try:
                obj = json.loads(data)
                for choice in obj.get("choices", []):
                    for block in choice.get("delta", {}).get("content", []):
                        if block.get("type") == "text":
                            full_text += block.get("text", "")
            except json.JSONDecodeError:
                pass

    latency = time.time() - start
    return full_text, latency


def run(
    connection_name: str | None,
    output_dir: str,
    question_filter: int | None,
) -> int:
    out = pathlib.Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    conn = get_connection(connection_name)
    base_url = get_account_url(conn)

    headers = get_pat_headers()
    auth_method = "PAT"
    if headers is None:
        try:
            headers = get_auth_headers(conn)
            auth_method = "session token"
        except RuntimeError as e:
            print(f"\nError: {e}")
            print("Set SNOWFLAKE_PAT env var to your Personal Access Token.")
            conn.close()
            return 1

    questions = DEMO_QUESTIONS
    if question_filter is not None:
        idx = question_filter - 1
        if not (0 <= idx < len(questions)):
            print(f"Invalid --question: must be 1-{len(questions)}")
            return 1
        questions = [questions[idx]]

    print(f"\n{BOLD}CITADEL Demo Query Runner{RESET}")
    print(f"  Agent  : {AGENT_FQN}")
    print(f"  Auth   : {auth_method}")
    print(f"  Output : {out.resolve()}")
    print(f"  Queries: {len(questions)}")
    print()

    summary = {
        "run_at":   datetime.datetime.now().isoformat(),
        "agent":    AGENT_FQN,
        "results":  []
    }

    for i, q in enumerate(questions, 1):
        print(f"  [{i}/{len(questions)}] {q['id']} — {q['domain']}")
        print(f"         Q: {q['question'][:90]}...")
        print(f"         ", end="", flush=True)

        response, latency = call_agent(base_url, headers, q["question"])

        ok = bool(response) and not response.startswith("[")
        icon = PASS if ok else FAIL
        print(f"{icon}  {latency:.1f}s")

        result = {
            "id":              q["id"],
            "domain":          q["domain"],
            "question":        q["question"],
            "expected_tool":   q["expected_tool"],
            "pitch_notes":     q["pitch_notes"],
            "response":        response,
            "latency_seconds": round(latency, 2),
            "success":         ok,
        }

        # Save individual result
        out_file = out / f"{q['id']}_{q['slug']}.json"
        out_file.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")

        summary["results"].append({
            "id":              q["id"],
            "domain":          q["domain"],
            "success":         ok,
            "latency_seconds": result["latency_seconds"],
            "file":            out_file.name,
        })

        # Print first 400 chars of response for visibility
        preview = response[:400].replace("\n", " ")
        print(f"           {preview}{'...' if len(response) > 400 else ''}\n")

    # Save summary
    passed = sum(1 for r in summary["results"] if r["success"])
    summary["passed"] = passed
    summary["failed"] = len(questions) - passed
    (out / "summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    print("─" * 60)
    print(f"  Results : {passed}/{len(questions)} passed")
    print(f"  Saved to: {out.resolve()}")
    print()

    conn.close()
    return 0 if passed == len(questions) else 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Run Citadel demo questions against CITADEL_AGENT",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Demo questions:
""" + "\n".join(
    f"  {q['id']}  [{q['domain']:20}]  {q['question'][:60]}..."
    for q in DEMO_QUESTIONS
)
    )
    parser.add_argument("--connection", default=None,          help="Snowflake connection name")
    parser.add_argument("--output",     default="demo_results", help="Output directory (default: ./demo_results/)")
    parser.add_argument("--question",   type=int, default=None, help="Run only question N (1-8)")
    parser.add_argument("--list",       action="store_true",    help="Print demo questions and exit")
    args = parser.parse_args()

    if args.list:
        print(f"\n{BOLD}CITADEL Demo Questions{RESET}\n")
        for q in DEMO_QUESTIONS:
            print(f"  {q['id']}  [{q['domain']:25}]  {q['question'][:70]}...")
            print(f"        Tool: {q['expected_tool']:20}  {q['pitch_notes'][:70]}")
            print()
        return

    sys.exit(run(args.connection, args.output, args.question))


if __name__ == "__main__":
    main()

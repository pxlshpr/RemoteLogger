#!/usr/bin/env python3
"""
Search Stress Test Server for NutriKit.

Receives structured stress test results from the app via RemoteLogger,
displays formatted terminal output in real-time, and saves results to JSON.

Run standalone:
    python3 stress_test_server.py

Or via fish alias:
    search-stress

Results saved to: ~/Developer/.remote-logs/NutriKit/stress-test-latest.json
"""

import argparse
import json
import os
import sys
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

PORT = 9876
LOG_DIR = os.path.expanduser("~/Developer/.remote-logs")
RESULTS_DIR = os.path.expanduser("~/Developer/.remote-logs/NutriKit")

# ANSI colors
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
MAGENTA = "\033[35m"
WHITE = "\033[37m"
BOLD_GREEN = "\033[1;32m"
BOLD_RED = "\033[1;31m"
BOLD_CYAN = "\033[1;36m"
BOLD_YELLOW = "\033[1;33m"
BOLD_WHITE = "\033[1;37m"
BG_RED = "\033[41m"
BG_GREEN = "\033[42m"


class StressTestState:
    """Tracks the current stress test run state."""
    def __init__(self):
        self.results = []
        self.total_count = 0
        self.started = False
        self.finished = False
        self.start_time = None
        self.current_category = None

    def reset(self):
        self.results = []
        self.total_count = 0
        self.started = False
        self.finished = False
        self.start_time = datetime.now()
        self.current_category = None


state = StressTestState()


class StressTestHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        if self.path.startswith("/log"):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                entry = json.loads(body)
                self._handle_entry(entry)
            except json.JSONDecodeError:
                pass
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        if self.path == "/ping":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"pong")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # suppress default HTTP logging

    def _handle_entry(self, entry):
        category = entry.get("category", "")
        message = entry.get("message", "")
        extra = entry.get("extra", {})

        if category != "search-stress-test":
            # Also write non-stress-test logs to the regular log file (passthrough)
            self._write_regular_log(entry)
            return

        if message.startswith("STRESS_TEST_START"):
            count_str = message.split("count=")[-1] if "count=" in message else "0"
            state.reset()
            state.total_count = int(count_str)
            state.started = True
            print()
            print(f"  {BOLD_CYAN}── Running {state.total_count} tests ──{RESET}")
            print()
            sys.stdout.flush()

        elif message.startswith("STRESS_TEST_RESULT"):
            self._handle_result(extra)

        elif message.startswith("STRESS_TEST_END"):
            state.finished = True
            self._print_summary()
            self._save_results()

    def _handle_result(self, extra):
        result = {
            "query": extra.get("query", ""),
            "status": extra.get("status", ""),
            "expected": extra.get("expected", ""),
            "expected_dsID": extra.get("expected_dsID", ""),
            "actual_top": extra.get("actual_top", ""),
            "actual_dsID": extra.get("actual_dsID", ""),
            "rank": extra.get("rank", ""),
            "duration_ms": extra.get("duration_ms", "0"),
            "top_n": extra.get("top_n", "3"),
            "category": extra.get("category", ""),
            "energy": extra.get("energy", ""),
            "amount": extra.get("amount", ""),
            "expected_amount": extra.get("expected_amount", ""),
            "amount_status": extra.get("amount_status", ""),
            "timestamp": datetime.now().isoformat(),
        }
        state.results.append(result)

        cat = result["category"]
        if cat != state.current_category:
            state.current_category = cat
            print(f"  {BOLD_WHITE}{cat}{RESET}")

        query = result["query"]
        status = result["status"]
        actual = result["actual_top"]
        rank = result["rank"]
        duration = result["duration_ms"]
        expected = result["expected"]

        passed = len(state.results)
        total = state.total_count

        if status == "PASS":
            icon = f"{GREEN}✓{RESET}"
            detail = f"{DIM}{actual}{RESET}"
            rank_str = f"{DIM}[{rank}]{RESET}"
            line = f"    {icon}  {query} {DIM}→{RESET} {detail} {rank_str}  {DIM}{duration}ms{RESET}"
        else:
            icon = f"{RED}✗{RESET}"
            line = f"    {icon}  {query}"
            line += f"\n       {RED}got:      {actual}{RESET}  {DIM}{duration}ms{RESET}"
            line += f"\n       {YELLOW}expected: {expected}{RESET}"
            amt_status = result.get("amount_status", "")
            if amt_status.startswith("MISMATCH"):
                amt = result.get("amount", "?")
                exp_amt = result.get("expected_amount", "?")
                line += f"\n       {RED}amount: got \"{amt}\", expected \"{exp_amt}\"{RESET}"

        # Progress counter
        progress = f"{DIM}[{passed}/{total}]{RESET}"
        print(f"{line}  {progress}")
        sys.stdout.flush()

    def _print_summary(self):
        passed = sum(1 for r in state.results if r["status"] == "PASS")
        failed = sum(1 for r in state.results if r["status"] == "FAIL")
        total = len(state.results)
        pct = (passed / total * 100) if total > 0 else 0
        total_ms = sum(float(r.get("duration_ms", 0)) for r in state.results)
        avg_ms = total_ms / total if total > 0 else 0

        print()
        print(f"  {'═' * 45}")

        if pct >= 80:
            color = BOLD_GREEN
        elif pct >= 50:
            color = BOLD_YELLOW
        else:
            color = BOLD_RED

        print(f"  {color}RESULT: {passed}/{total} passed ({pct:.0f}%){RESET}")
        print(f"  {DIM}Total: {total_ms:.0f}ms · Avg: {avg_ms:.0f}ms/query{RESET}")
        print(f"  {'═' * 45}")

        failures = [r for r in state.results if r["status"] == "FAIL"]
        if failures:
            print()
            print(f"  {BOLD_RED}Failures:{RESET}")
            for i, f in enumerate(failures, 1):
                print(f"    {i}. {f['query']}")
                print(f"       got: {f['actual_top']}")
                print(f"       expected: {f['expected']} (rank: {f['rank']})")
                amt_status = f.get('amount_status', '')
                if amt_status.startswith('MISMATCH'):
                    print(f"       {RED}amount: got \"{f.get('amount', '?')}\", expected \"{f.get('expected_amount', '?')}\"{RESET}")
        else:
            print()
            print(f"  {BOLD_GREEN}All tests passed!{RESET}")

        print()
        sys.stdout.flush()

    def _save_results(self):
        os.makedirs(RESULTS_DIR, exist_ok=True)

        # Save latest
        latest_path = os.path.join(RESULTS_DIR, "stress-test-latest.json")
        payload = {
            "timestamp": datetime.now().isoformat(),
            "total": len(state.results),
            "passed": sum(1 for r in state.results if r["status"] == "PASS"),
            "failed": sum(1 for r in state.results if r["status"] == "FAIL"),
            "total_ms": sum(float(r.get("duration_ms", 0)) for r in state.results),
            "results": state.results,
        }
        with open(latest_path, "w") as f:
            json.dump(payload, f, indent=2)

        # Also save timestamped copy
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        history_dir = os.path.join(RESULTS_DIR, "stress-test-history")
        os.makedirs(history_dir, exist_ok=True)
        history_path = os.path.join(history_dir, f"stress-test-{ts}.json")
        with open(history_path, "w") as f:
            json.dump(payload, f, indent=2)

        print(f"  {DIM}Results saved to:{RESET}")
        print(f"  {DIM}  {latest_path}{RESET}")
        print(f"  {DIM}  {history_path}{RESET}")
        print()
        sys.stdout.flush()

    def _write_regular_log(self, entry):
        """Write non-stress-test logs to the regular log file."""
        app = entry.get("app", "NutriKit")
        app_dir = os.path.join(LOG_DIR, app)
        os.makedirs(app_dir, exist_ok=True)
        log_path = os.path.join(app_dir, "remote-logs.txt")

        ts = entry.get("timestamp", "")
        level = entry.get("level", "info").upper().ljust(5)
        cat = entry.get("category", "")
        message = entry.get("message", "")

        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            time_str = dt.strftime("%H:%M:%S.%f")[:-3]
        except (ValueError, AttributeError):
            time_str = ts[:12] if ts else "??:??:??"

        cat_tag = f"[{cat}] " if cat else ""
        line = f"{time_str} {level} {cat_tag}{message}\n"

        with open(log_path, "a") as f:
            f.write(line)


def main():
    parser = argparse.ArgumentParser(description="Search Stress Test Server")
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()

    os.makedirs(RESULTS_DIR, exist_ok=True)

    server = HTTPServer(("0.0.0.0", args.port), StressTestHandler)

    print()
    print(f"  {BOLD}╔═══════════════════════════════════════╗{RESET}")
    print(f"  {BOLD}║   SEARCH STRESS TEST SERVER           ║{RESET}")
    print(f"  {BOLD}║   Listening on :{args.port}                ║{RESET}")
    print(f"  {BOLD}╚═══════════════════════════════════════╝{RESET}")
    print()
    print(f"  {DIM}Waiting for app to connect...{RESET}")
    print(f"  {DIM}Open Admin → Search Stress Test → Run All Tests{RESET}")
    print()
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n  {DIM}Server stopped.{RESET}")
        server.server_close()


if __name__ == "__main__":
    main()

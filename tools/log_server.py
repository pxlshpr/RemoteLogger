#!/usr/bin/env python3
"""
Unified Remote Log Server for iOS apps.
Receives structured JSON logs from any app, routes to per-app log files,
and displays color-coded output in the terminal.

Listens on all interfaces at port 9876 for POST /log requests.

Run:
    python3 log_server.py
    python3 log_server.py --log-dir /tmp/remote-logs
"""

import argparse
import json
import os
import sys
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

PORT = 9876

# Default log directory — per-app subdirectories created automatically
DEFAULT_LOG_DIR = os.path.expanduser("~/Developer/.remote-logs")

# ANSI colors
COLORS = {
    "debug":    "\033[90m",    # gray
    "info":     "\033[36m",    # cyan
    "warning":  "\033[33m",    # yellow
    "error":    "\033[31m",    # red
    "critical": "\033[1;31m",  # bold red
}
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"

# App colors for the [AppName] prefix
APP_COLORS = {
    "NutriKit":   "\033[1;32m",  # bold green
    "KanbanSync": "\033[1;34m",  # bold blue
    "Spare":      "\033[1;33m",  # bold yellow
}
DEFAULT_APP_COLOR = "\033[1;37m"  # bold white

# Category colors for visual grouping
CAT_COLORS = {
    "sync-pull":      "\033[35m",   # magenta
    "sync-push":      "\033[34m",   # blue
    "ui-refresh":     "\033[32m",   # green
    "data-fetch":     "\033[36m",   # cyan
    "notification":   "\033[33m",   # yellow
    "calorie-target": "\033[1;35m", # bold magenta
    "github":         "\033[1;34m", # bold blue
    "ssh":            "\033[1;36m", # bold cyan
    "parser":         "\033[32m",   # green
}


class LogHandler(BaseHTTPRequestHandler):
    log_dir = DEFAULT_LOG_DIR
    _file_handles = {}  # app_name -> file handle

    def do_POST(self):
        if self.path.startswith("/log"):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                entry = json.loads(body)
                self._handle_log(entry)
            except json.JSONDecodeError:
                print(f"  [RAW] {body.decode('utf-8', errors='replace')}")
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
        elif self.path.startswith("/logs/"):
            self._serve_logs()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # suppress default HTTP logging

    def _handle_log(self, entry):
        app = entry.get("app", "NutriKit")
        self._print_log(entry, app)
        self._write_to_file(entry, app)

    def _print_log(self, entry, app):
        ts = entry.get("timestamp", "")
        level = entry.get("level", "info").lower()
        category = entry.get("category", "")
        message = entry.get("message", "")
        extra = entry.get("extra", {})

        color = COLORS.get(level, "")
        cat_color = CAT_COLORS.get(category, DIM)
        app_color = APP_COLORS.get(app, DEFAULT_APP_COLOR)

        # Format timestamp
        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            time_str = dt.strftime("%H:%M:%S.%f")[:-3]
        except (ValueError, AttributeError):
            time_str = ts[:12] if ts else "??:??:??"

        level_tag = level.upper().ljust(5)
        cat_tag = f"[{category}]" if category else ""
        app_tag = f"[{app}]".ljust(13)

        print(
            f"{DIM}{time_str}{RESET} "
            f"{app_color}{app_tag}{RESET} "
            f"{color}{level_tag}{RESET} "
            f"{cat_color}{cat_tag}{RESET} "
            f"{message}",
            end=""
        )

        if extra:
            pairs = " ".join(f"{k}={v}" for k, v in extra.items())
            print(f"  {DIM}{pairs}{RESET}")
        else:
            print()

        sys.stdout.flush()

    def _write_to_file(self, entry, app):
        """Write a plain-text log line to the per-app log file."""
        fh = self._get_file_handle(app)
        if not fh:
            return

        ts = entry.get("timestamp", "")
        level = entry.get("level", "info").upper().ljust(5)
        category = entry.get("category", "")
        message = entry.get("message", "")
        extra = entry.get("extra", {})

        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            time_str = dt.strftime("%H:%M:%S.%f")[:-3]
        except (ValueError, AttributeError):
            time_str = ts[:12] if ts else "??:??:??"

        cat_tag = f"[{category}] " if category else ""
        extra_str = ""
        if extra:
            extra_str = "  " + " ".join(f"{k}={v}" for k, v in extra.items())

        line = f"{time_str} {level} {cat_tag}{message}{extra_str}\n"
        fh.write(line)
        fh.flush()

    def _get_file_handle(self, app):
        if app not in self._file_handles:
            app_dir = os.path.join(self.log_dir, app)
            os.makedirs(app_dir, exist_ok=True)
            log_path = os.path.join(app_dir, "remote-logs.txt")
            try:
                self._file_handles[app] = open(log_path, "a")
            except IOError as e:
                print(f"  [ERROR] Cannot open log file for {app}: {e}")
                return None
        return self._file_handles[app]

    def _serve_logs(self):
        """GET /logs/<app>?lines=100 — serve recent log lines."""
        parts = self.path.split("/")
        if len(parts) < 3:
            self.send_response(400)
            self.end_headers()
            return

        app = parts[2].split("?")[0]
        log_path = os.path.join(self.log_dir, app, "remote-logs.txt")

        if not os.path.exists(log_path):
            self.send_response(404)
            self.end_headers()
            self.wfile.write(f"No logs for {app}".encode())
            return

        # Parse ?lines=N (default 100)
        lines = 100
        if "?" in self.path:
            query = self.path.split("?")[1]
            for param in query.split("&"):
                if param.startswith("lines="):
                    try:
                        lines = int(param.split("=")[1])
                    except ValueError:
                        pass

        with open(log_path, "r") as f:
            all_lines = f.readlines()
            tail = all_lines[-lines:]

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write("".join(tail).encode())


def main():
    parser = argparse.ArgumentParser(description="Unified Remote Log Server")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--log-dir", default=DEFAULT_LOG_DIR,
                        help="Directory for per-app log files")
    args = parser.parse_args()

    LogHandler.log_dir = args.log_dir
    os.makedirs(args.log_dir, exist_ok=True)

    server = HTTPServer(("0.0.0.0", args.port), LogHandler)
    print(f"{BOLD}Unified Remote Log Server{RESET}")
    print(f"Listening on 0.0.0.0:{args.port}")
    print(f"Log directory: {args.log_dir}")
    print(f"Per-app logs: {args.log_dir}/<AppName>/remote-logs.txt")
    print(f"Read logs: GET /logs/<AppName>?lines=100")
    print(f"{'─' * 60}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n{DIM}Server stopped.{RESET}")
        # Close all file handles
        for fh in LogHandler._file_handles.values():
            fh.close()
        server.server_close()


if __name__ == "__main__":
    main()

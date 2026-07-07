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
import re
import sys
from datetime import datetime
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from threading import Lock
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
    # Guard concurrent writes / handle creation now that the server runs each
    # request on its own thread (ThreadingHTTPServer). Without this, two
    # threads can race on the file-handle dict or interleave bytes inside a
    # single log line.
    _file_lock = Lock()
    _print_lock = Lock()

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

    @staticmethod
    def _field(entry, key, default):
        """Read a routing field (device/branch) — top-level wins, then `extra`, then the default.
        Blank/whitespace values fall back to the default so missing fields never produce an empty
        path segment."""
        val = entry.get(key)
        if val is None:
            val = (entry.get("extra") or {}).get(key)
        val = str(val).strip() if val is not None else ""
        return val or default

    @staticmethod
    def _safe(segment):
        """Restrict a path segment to filename-safe characters (the device id / branch tag come
        from the client, so don't let them escape the log dir or break the bracket naming)."""
        return re.sub(r"[^A-Za-z0-9._-]", "_", segment)

    def _split_filename(self, app, device, branch):
        """Per-device + per-branch log filename: `[app][device][branch].log` — so one task's logs on
        one device are trivially isolatable from concurrent work on other branches/devices."""
        return f"[{self._safe(app)}][{self._safe(device)}][{self._safe(branch)}].log"

    def _handle_log(self, entry):
        app = entry.get("app", "NutriKit")
        device = self._field(entry, "device", "unknown")
        branch = self._field(entry, "branch", "main")
        self._print_log(entry, app, device, branch)
        self._write_to_file(entry, app, device, branch)

    def _print_log(self, entry, app, device, branch):
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
        # Only surface the device/branch segment when the client actually sent one, so legacy apps
        # that don't (KanbanSync, Spare, older builds) keep their clean single-column output.
        id_seg = ""
        if device != "unknown" or branch != "main":
            id_seg = f"{DIM}[{device}/{branch}]{RESET} "

        line = (
            f"{DIM}{time_str}{RESET} "
            f"{app_color}{app_tag}{RESET} "
            f"{id_seg}"
            f"{color}{level_tag}{RESET} "
            f"{cat_color}{cat_tag}{RESET} "
            f"{message}"
        )
        if extra:
            pairs = " ".join(f"{k}={v}" for k, v in extra.items())
            line = f"{line}  {DIM}{pairs}{RESET}"

        # Hold the lock across the print + flush so threads don't interleave
        # halves of one log line in the terminal.
        with self._print_lock:
            print(line)
            sys.stdout.flush()

    def _write_to_file(self, entry, app, device, branch):
        """Write a plain-text log line to BOTH the per-device/per-branch split file
        (`<app>/[app][device][branch].log`) and the legacy combined `<app>/remote-logs.txt`.

        The split file is the #2011 isolation feature (one task on one device, on its own). The
        combined file is kept for backward compatibility — the `search-logs`/stress-test flows and
        existing muscle memory still read `<app>/remote-logs.txt`."""
        ts = entry.get("timestamp", "")
        level = entry.get("level", "info").upper().ljust(5)
        category = entry.get("category", "")
        message = entry.get("message", "")
        extra = entry.get("extra", {})

        try:
            dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            time_str = dt.strftime("%H:%M:%S.%f")[:-3]
            day_str = dt.strftime("%Y-%m-%d")
        except (ValueError, AttributeError):
            time_str = ts[:12] if ts else "??:??:??"
            day_str = ""

        cat_tag = f"[{category}] " if category else ""
        extra_str = ""
        if extra:
            extra_str = "  " + " ".join(f"{k}={v}" for k, v in extra.items())

        line = f"{time_str} {level} {cat_tag}{message}{extra_str}\n"
        app_dir = os.path.join(self.log_dir, self._safe(app))
        combined_path = os.path.join(app_dir, "remote-logs.txt")
        split_path = os.path.join(app_dir, self._split_filename(app, device, branch))

        targets = [(split_path, line), (combined_path, line)]

        # NutriKit #2055: every CloudKit-related line (category `ck-*`) ALSO lands in one
        # persistent aggregate at the log ROOT — outside every app dir, so branch-scoped
        # flushes (/flushlogs) never clear it. All apps/devices/branches converge here
        # (that's the point: long-term evidence of residue cleanups + cache regrowth
        # across every install), so each line carries its origin and a full date.
        if category.startswith("ck-"):
            ck_line = (f"{day_str} {time_str} {level} "
                       f"[{self._safe(app)}/{device}/{branch}] {cat_tag}{message}{extra_str}\n")
            targets.append((os.path.join(self.log_dir, "cloudkit.log"), ck_line))

        # One write+flush per line under the lock so concurrent requests
        # never interleave bytes inside a single log line.
        with self._file_lock:
            for path, out in targets:
                fh = self._handle_for_path(path)
                if fh:
                    fh.write(out)
                    fh.flush()

    def _handle_for_path(self, path):
        """Return a cached append handle for `path`, opening (and creating the parent dir) on first
        use. Caller must hold `_file_lock`."""
        fh = self._file_handles.get(path)
        if fh is None:
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                fh = open(path, "a")
                self._file_handles[path] = fh
            except IOError as e:
                print(f"  [ERROR] Cannot open log file {path}: {e}")
                return None
        return fh

    def _serve_logs(self):
        """GET /logs/<app>?lines=100 — serve recent log lines from the combined file.
        GET /logs/<app>?device=<d>&branch=<b>&lines=100 — serve a specific per-device/per-branch
        split file instead (both device and branch must be given to select a split)."""
        parts = self.path.split("/")
        if len(parts) < 3:
            self.send_response(400)
            self.end_headers()
            return

        app = parts[2].split("?")[0]

        # Parse query (?lines=N, ?device=, ?branch=)
        lines = 100
        device = None
        branch = None
        if "?" in self.path:
            query = self.path.split("?", 1)[1]
            for param in query.split("&"):
                if param.startswith("lines="):
                    try:
                        lines = int(param.split("=", 1)[1])
                    except ValueError:
                        pass
                elif param.startswith("device="):
                    device = param.split("=", 1)[1] or None
                elif param.startswith("branch="):
                    branch = param.split("=", 1)[1] or None

        # device+branch selects the split file; otherwise the combined file.
        if device is not None and branch is not None:
            filename = self._split_filename(app, device, branch)
        else:
            filename = "remote-logs.txt"
        log_path = os.path.join(self.log_dir, self._safe(app), filename)

        if not os.path.exists(log_path):
            self.send_response(404)
            self.end_headers()
            self.wfile.write(f"No logs at {filename} for {app}".encode())
            return

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

    # ThreadingHTTPServer spawns a thread per request so a burst of POSTs
    # from one app (e.g. picker open: viewDidLoad → viewDidAppear → multiple
    # viewDidLayoutSubviews → updateUIViewController in a few hundred ms)
    # doesn't overflow the OS socket backlog and silently drop connections.
    server = ThreadingHTTPServer(("0.0.0.0", args.port), LogHandler)
    # Don't let a connected client block server shutdown forever.
    server.daemon_threads = True
    # Bump the listen backlog above the default 5 so a sudden spike of
    # concurrent connections (each iOS log = its own TCP connection because
    # RemoteLogger uses an ephemeral URLSession) gets queued instead of
    # refused at the SYN-ACK layer before any thread can accept it.
    server.request_queue_size = 128
    print(f"{BOLD}Unified Remote Log Server{RESET}")
    print(f"Listening on 0.0.0.0:{args.port}")
    print(f"Log directory: {args.log_dir}")
    print(f"Combined logs:  {args.log_dir}/<AppName>/remote-logs.txt")
    print(f"Per-dev/branch: {args.log_dir}/<AppName>/[<AppName>][<device>][<branch>].log")
    print(f"Read logs: GET /logs/<AppName>?lines=100  (add &device=<d>&branch=<b> for a split file)")
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

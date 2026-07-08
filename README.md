# RemoteLogger

Structured, real-time logging from iOS/macOS apps to a Mac over Tailscale. An app POSTs JSON log
lines to a tiny Python server (`tools/log_server.py`) running on your dev Mac; the server prints them
color-coded in a terminal and writes them to per-app / per-device / per-branch files you can `grep`,
`tail`, and `/logger`-manage.

**`ReliableRemoteLogger` is the canonical logger — reach for it in new code.** `RemoteLogger` (the
old fire-and-forget fast path) is **deprecated**: it still compiles and runs, but the compiler now
flags its call sites so existing usage can migrate over time. Both paths share one configuration and
POST to the same endpoint, so migration is a drop-in swap of the type name.

| | `ReliableRemoteLogger` (canonical, drop-proof) | `RemoteLogger` (deprecated fast path) |
|---|---|---|
| Delivery | serialized FIFO, **retried with backoff**, never drops a line | fire-and-forget, one POST per line, **no retry** |
| Ordering | strict (`seq=N` per line; single connection) | best-effort (ephemeral session, ~6 conns/host) |
| On-device record | **file mirror** in `Caches/` (survives total network loss) | none |
| Cost under a dense burst | buffers and drains in order | some lines time out and are silently dropped |
| Status | **use this** | deprecated — migrate over time |

Both POST to the **same** `/log` endpoint and carry the same `app` / `device` / `branch` identity, so
they interleave correctly in the server logs and route to the same files.

---

## Install (Swift Package Manager)

```swift
.package(url: "https://github.com/pxlshpr/RemoteLogger", from: "1.3.0"),
// …
.product(name: "RemoteLogger", package: "RemoteLogger"),
```

Platforms: iOS 17+, macOS 14+.

---

## Configure once at startup

```swift
ReliableRemoteLogger.configure(
    app: "MyApp",                       // server routes per-app on this
    device: String(deviceID.prefix(8)), // optional — enables per-device routing
    branch: branchTag                   // optional — enables per-branch routing (see "Branch tagging")
)
```

A single `configure(...)` wires up **both** `ReliableRemoteLogger` and the deprecated `RemoteLogger`
(they read one shared `RemoteLoggerConfig`), so the endpoint and identity can never drift between the
two paths. (`RemoteLogger.configure(...)` still exists but is deprecated alongside that type — prefer
`ReliableRemoteLogger.configure(...)`.)

| Parameter | Default | Notes |
|---|---|---|
| `app` | `"NutriKit"` (server-side fallback) | per-app log routing + terminal color |
| `host` | `100.116.221.123` | the dev Mac's Tailscale IP running `log_server.py` |
| `port` | `9876` | |
| `baseURL` | — | full base URL (e.g. `https://host.ts.net`) for Tailscale Funnel / HTTPS; overrides host/port |
| `device` | — (→ `unknown`) | stable per-device id/tag; enables per-device split files |
| `branch` | — (→ `main`) | branch/task tag; enables per-branch split files |

`device`/`branch` are sent only when set, so apps (and older builds) that don't pass them stay
byte-compatible with the server's per-app fallback.

---

## Log

```swift
// Canonical path — use this for everyday logging:
ReliableRemoteLogger.shared.info("Pulled 5 days", category: "sync-pull", extra: ["count": "5"])
ReliableRemoteLogger.shared.debug(…) / .warning(…) / .error(…)

// Same API for a trace that must NOT lose a line under a burst (it's drop-proof by construction):
ReliableRemoteLogger.shared.info("PROTECT-ADD meal=\(id)", category: "flicker-trace")

// Or a dedicated instance with its own on-device mirror file for a self-contained investigation:
let stall = ReliableRemoteLogger(mirrorFileName: "stall-2010.log")
stall.info("HEARTBEAT", category: "stall-2010")

// Deprecated fast path — still works, emits a deprecation warning, migrate to the above:
RemoteLogger.shared.info("legacy line", category: "sync-pull")
```

`category` drives terminal color grouping and is the usual `grep` key. `extra` is rendered as
`k=v` pairs.

### How `ReliableRemoteLogger` guarantees delivery

- **Monotonic `seq=N` per line** — embedded in the message text *and* in `extra`. Any residual drop
  is **detectable** as a gap, and true order is recoverable even if the network reorders.
- **Serialized single-connection FIFO sender** (`httpMaximumConnectionsPerHost = 1`), one request in
  flight at a time, **retried with backoff** on failure — the line stays queued, never dropped, so a
  burst *buffers and drains in order* instead of overflowing the connection pool. The buffer is
  bounded (50k lines); on overflow the **oldest** are dropped and the `seq` gap reveals the loss.
- **On-device file mirror** in `Caches/<mirrorFileName>` (default `reliable-remote.log`), appended
  synchronously on the logger's serial queue — a complete record even if the network drops
  everything. Truncated on construction by default so each run starts clean (`truncateOnInit: false`
  to append across runs).

This is the mechanism originally proven in the field (a NutriKit add-burst-flicker trace: 183 lines,
`seq` 1–183, zero gaps under a burst that the fast path could not capture) and then extracted here so
it's reusable across projects.

---

## The log server

```bash
python3 tools/log_server.py                 # listens on 0.0.0.0:9876
python3 tools/log_server.py --log-dir /tmp/remote-logs --port 9876
```

Multi-threaded (`ThreadingHTTPServer`) with a 128-deep listen backlog so a burst of POSTs — each iOS
log is its own TCP connection — doesn't overflow the socket backlog. Per-line write+flush under a
lock so concurrent requests never interleave bytes within a line.

### Endpoints

| Method / path | Purpose |
|---|---|
| `POST /log` | ingest one JSON log entry |
| `GET /ping` | health check → `pong` |
| `GET /logs/<App>?lines=100` | tail the combined file for an app |
| `GET /logs/<App>?device=<d>&branch=<b>&lines=100` | tail a specific per-device/per-branch split file |

### Where lines land

Every line is written to **both**:

```
~/Developer/.remote-logs/<App>/remote-logs.txt                    # combined — all devices/branches
~/Developer/.remote-logs/<App>/[<App>][<device>][<branch>].log    # split — one device, one branch
```

- The **split file** is the isolation feature: one task's logs on one device, trivially separable
  from concurrent work on other branches/devices.
- The **combined file** is kept for backward compatibility — existing `grep`-everything flows, the
  search/stress-test tooling, and muscle memory all keep working.
- Missing `device`/`branch` → `[<App>][unknown][main].log`. Client-supplied segments are sanitized to
  `[A-Za-z0-9._-]` so they can't escape the log dir.

> **Bracketed filenames + the shell:** `[`/`]` are glob metacharacters. Never feed these names to a
> bare glob — list/select them with `find … -name '*.log' | grep -F "][${branch}].log"`.

---

## Branch tagging (build-time recipe)

The runtime can't know which git clone built it, so bake the clone/branch in at build time. The
pattern used by NutriKit needs **no `.xcodeproj` or build-script surgery** — it rides the Info.plist
variable substitution Xcode already runs:

1. Add to the app target's `Info.plist`:
   ```xml
   <key>NKBuildSrcRoot</key>
   <string>$(SRCROOT)</string>
   ```
2. At startup, parse the branch/task from the clone dir and pass it to `configure`:
   ```swift
   func logBranchTag() -> String? {
       guard let src = Bundle.main.infoDictionary?["NKBuildSrcRoot"] as? String, !src.isEmpty
       else { return nil }
       let cloneDir = (src as NSString).lastPathComponent          // e.g. "MyApp-1980"
       guard let dash = cloneDir.firstIndex(of: "-") else { return nil }  // no suffix → main repo
       let tag = String(cloneDir[cloneDir.index(after: dash)...])
       return tag.isEmpty ? nil : tag
   }
   ReliableRemoteLogger.configure(app: "MyApp", device: deviceTag, branch: logBranchTag())
   ```

This matches how clones are named (`<project>-<task>`), so a clone on branch `1980` routes its logs
to `…[1980].log`. App Store / main-repo builds have no `-<task>` suffix → `branch` is nil → they
route to the `main` bucket.

---

## Managing logs (global skills)

| Skill | Purpose |
|---|---|
| `/logger` | full server lifecycle: `start` / `restart` / `stop` / `status` / `check` / `filter` / `clear` (branch-aware) |
| `/logs` | daily driver: auto-start the server, then show **this branch's** logs (`flush` to start clean, `all` for the combined feed) |
| `/flushlogs` | flush logs branch-aware: `(no args)` = current branch · `all` · `branch <X>` · `device <Y>` · `app <Z>` |

Clears **truncate** (`: > file`) rather than `rm` — the running server holds an append handle to the
inode, so `rm` would silently send subsequent writes to the unlinked inode until a restart. Branch
detection mirrors the app's: `branch = basename(clone dir) after the first '-'`, else `main`.

---

## Versioning

- **1.3.0** — **`ReliableRemoteLogger` is now canonical**; `RemoteLogger` is **deprecated**
  (`@available(*, deprecated)`, still compiles/runs — its call sites now warn so usage can migrate
  over time). Added `ReliableRemoteLogger.configure(...)` as the canonical, non-deprecated
  configuration entry point (identical signature; still wires up both paths). Docs-only migration —
  no API removed, fully backward-compatible.
- **1.2.0** — added `ReliableRemoteLogger` (drop-proof path); `configure(device:branch:)` (additive,
  backward-compatible); server routes to per-device/per-branch split files while keeping the combined
  `remote-logs.txt`.
- **1.1.x** — multi-threaded server; cached `ISO8601DateFormatter`; `baseURL` override for HTTPS.

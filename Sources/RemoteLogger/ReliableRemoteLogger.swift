import Foundation

/// The **canonical** remote logger — drop-proof delivery that must NOT lose a single line under a
/// dense burst, the exact failure mode that defeats the deprecated fire-and-forget ``RemoteLogger``
/// (its ephemeral `URLSession` caps at ~6 connections/host with a short timeout and no retry, so a
/// burst of hundreds of lines competes, times out, and silently drops some).
///
/// Configure once at startup via ``configure(app:host:port:baseURL:device:branch:enabled:)`` — that
/// single call wires up the shared ``RemoteLoggerConfig`` for both this logger and the legacy
/// ``RemoteLogger``, so new code should reach for `ReliableRemoteLogger` and existing fast-path call
/// sites can migrate over time. **Until it runs, every line is dropped at the call site**: no
/// request, no mirror file, no retry loop — and `enabled` defaults to on only in a `DEBUG` build
/// (NutriKit #3252). Check ``isEnabled`` before starting a timer or a probe whose only output is
/// a log line.
///
/// The mechanism (proven in the field on the #2009 add-burst-flicker trace, then extracted here so
/// it's reusable across projects):
///   • **Monotonic `seq=N` per line** → any residual drop is DETECTABLE as a gap, and the true
///     order is recoverable even if the network reorders. The seq is embedded in the message text
///     AND in `extra`.
///   • **Serialized single-connection FIFO sender** (`httpMaximumConnectionsPerHost = 1`), one
///     request in flight at a time, **retried** on failure (the line stays queued, never dropped)
///     — so a burst BUFFERS and drains in order instead of overflowing the connection pool. The
///     buffer is bounded; on overflow the OLDEST are dropped (the seq gap then reveals the loss)
///     so a permanently-unreachable server can't grow it without bound.
///   • **On-device file mirror**, appended synchronously on the serial queue → a complete record
///     even if the network drops everything. Opened lazily, on the first line an enabled logger
///     writes, so a disabled build never creates the file.
///
/// It shares ``RemoteLoggerConfig`` with ``RemoteLogger`` (host/port/app/device/branch/enabled),
/// so a single `configure(...)` at startup configures both, and lines POST to the SAME `/log`
/// endpoint — they show up in the usual server logs alongside the fast-path lines, routed per
/// app/device/branch like any other line.
///
/// Drop-in usage — make any existing trace drop-proof by swapping the logger:
/// ```
/// ReliableRemoteLogger.shared.info("PROTECT-ADD meal=\(id)", category: "flicker-2009")
/// ```
/// Or spin up a dedicated instance with its own mirror file for a self-contained investigation:
/// ```
/// let log = ReliableRemoteLogger(mirrorFileName: "stall-2010.log")
/// ```
public final class ReliableRemoteLogger: @unchecked Sendable {
    /// Shared instance mirroring to `Caches/reliable-remote.log`.
    public static let shared = ReliableRemoteLogger()

    /// A mirror opened with `truncateOnInit: false` is truncated on open once it has grown past
    /// this — it is the one mirror that survives launches, so nothing else bounds it.
    public static let maxMirrorBytes = 8 * 1024 * 1024

    /// All mutable state (`seq`, `pending`, `inFlight`, the mirror handle) is confined to this
    /// serial queue.
    private let queue: DispatchQueue
    private let session: URLSession
    /// Compact wall-clock for the on-device mirror; only ever touched on `queue`.
    private let time: DateFormatter

    private var seq = 0
    /// FIFO buffer of un-acked lines. Capped so a permanently-unreachable server can't grow it
    /// without bound; on overflow the OLDEST are dropped (the `seq` gap then reveals the loss).
    private var pending: [(seq: Int, body: Data)] = []
    private var inFlight = false
    private static let maxPending = 50_000

    private let mirrorFileName: String
    private let truncateOnInit: Bool
    private var mirrorOpened = false
    private var fileHandle: FileHandle?

    /// - Parameters:
    ///   - mirrorFileName: File under `Caches/` to mirror every line to. Distinct names let
    ///     concurrent investigations keep separate bulletproof local records. The file is created
    ///     on the first line written, never at construction — a disabled logger leaves no file.
    ///   - truncateOnInit: Truncate the mirror when it is first opened so each run starts clean
    ///     (the remote server keeps the accumulated history). Defaults to `true` — the common case
    ///     for a per-run diagnostic trace. `false` appends across runs, bounded by
    ///     ``maxMirrorBytes``.
    public init(mirrorFileName: String = "reliable-remote.log", truncateOnInit: Bool = true) {
        self.queue = DispatchQueue(label: "com.pxlshpr.reliable-remote-logger.\(mirrorFileName)")
        self.mirrorFileName = mirrorFileName
        self.truncateOnInit = truncateOnInit

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        // Strict FIFO: a single connection, one request at a time, so lines arrive in `seq` order.
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.time = formatter
    }

    // MARK: - Configuration

    /// Configure remote logging. Call once at app startup. Configuration is shared with the legacy
    /// ``RemoteLogger`` (both read the same ``RemoteLoggerConfig``), so this single call wires up
    /// both the drop-proof and the fast path — there is no second endpoint to drift out of sync.
    ///
    /// This is the canonical configuration entry point; `RemoteLogger.configure(...)` still exists
    /// but is deprecated alongside the rest of that type.
    ///
    /// - Parameters:
    ///   - app: App name sent with every log entry (the server routes per-app on it).
    ///   - host: Override the default Tailscale IP.
    ///   - port: Override the default port.
    ///   - baseURL: Full base URL (e.g. "https://host.ts.net"). When set, host/port are ignored.
    ///   - device: Stable per-device id/tag sent with every entry so the server can route per-device.
    ///   - branch: Branch/task tag (e.g. the clone's task number) sent with every entry so the
    ///     server can route a single task's logs into their own file, isolated from concurrent work
    ///     on other branches/devices.
    ///   - enabled: Whether any line leaves the device at all. `nil` (the default) means **on in a
    ///     `DEBUG` build of this package, off in every other build** — so an app that calls this
    ///     unconditionally still ships silent. Pass `true` to log from a build that is not `DEBUG`
    ///     (an internal TestFlight behind a switch), `false` to silence a debug build. Before this
    ///     call, logging is off.
    public static func configure(
        app: String,
        host: String? = nil,
        port: Int? = nil,
        baseURL: String? = nil,
        device: String? = nil,
        branch: String? = nil,
        enabled: Bool? = nil
    ) {
        RemoteLoggerConfig.configure(app: app, host: host, port: port, baseURL: baseURL,
                                     device: device, branch: branch, enabled: enabled)
    }

    /// True once `configure(...)` has switched logging on; false before it, and false in every
    /// build that did not opt in. Gate anything whose only purpose is to produce log lines — a
    /// heartbeat timer, a watchdog thread — on this, so a silent build does not pay for them.
    public static var isEnabled: Bool { RemoteLoggerConfig.isEnabled }

    // MARK: - Public API (mirrors RemoteLogger so any trace can be made drop-proof by swapping in)

    /// `message` is an autoclosure so a disabled logger never even builds the string.
    public func debug(_ message: @autoclosure () -> String, category: String = "", extra: [String: String] = [:]) {
        log(level: "debug", message: message, category: category, extra: extra)
    }

    public func info(_ message: @autoclosure () -> String, category: String = "", extra: [String: String] = [:]) {
        log(level: "info", message: message, category: category, extra: extra)
    }

    public func warning(_ message: @autoclosure () -> String, category: String = "", extra: [String: String] = [:]) {
        log(level: "warning", message: message, category: category, extra: extra)
    }

    public func error(_ message: @autoclosure () -> String, category: String = "", extra: [String: String] = [:]) {
        log(level: "error", message: message, category: category, extra: extra)
    }

    // MARK: - Internals

    /// Cheap at the call site — one atomic load when logging is off; otherwise dispatches the real
    /// work (seq stamp, file append, JSON encode, network enqueue) onto the serial queue.
    private func log(level: String, message: () -> String, category: String, extra: [String: String]) {
        guard Self.isEnabled else { return }
        let message = message()
        queue.async {
            self.seq += 1
            let seq = self.seq
            // Embed seq in the message text so order is recoverable even if `extra` is reordered or
            // the network drops a line (the gap is greppable in the human-readable log).
            let stamped = "seq=\(seq) \(message)"

            // 1. Mirror to the on-device file first (cannot drop).
            self.openMirrorIfNeeded()
            let cat = category.isEmpty ? "" : "[\(category)] "
            let extraStr = extra.isEmpty ? "" : "  " + extra.map { "\($0)=\($1)" }.joined(separator: " ")
            let mirrorLine = "\(self.time.string(from: Date())) \(level.uppercased()) \(cat)\(stamped)\(extraStr)\n"
            if let data = mirrorLine.data(using: .utf8) {
                try? self.fileHandle?.write(contentsOf: data)
            }

            // 2. Enqueue for the reliable remote send. `seq` is duplicated into `extra` for
            //    machine-readable gap detection (it's also embedded in the message text).
            var sendExtra = extra
            sendExtra["seq"] = "\(seq)"
            let payload = RemoteLoggerConfig.payload(level: level, message: stamped,
                                                     category: category, extra: sendExtra)
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
            self.pending.append((seq, body))
            if self.pending.count > Self.maxPending {
                self.pending.removeFirst(self.pending.count - Self.maxPending)
            }
            self.pump()
        }
    }

    /// Opens the mirror under `Caches/` on the first line written. Called on `queue`. Honours
    /// `truncateOnInit` (truncate on this first open) and, for a mirror that appends across runs,
    /// ``maxMirrorBytes``.
    private func openMirrorIfNeeded() {
        guard !mirrorOpened else { return }
        mirrorOpened = true
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent(mirrorFileName)
        let fm = FileManager.default
        var startFresh = truncateOnInit || !fm.fileExists(atPath: url.path)
        if !startFresh,
           let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > Self.maxMirrorBytes {
            startFresh = true
        }
        if startFresh {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    /// Drives the FIFO. Called on `queue`. Sends `pending.first`; on success pops it and continues,
    /// on failure leaves it queued and retries 0.5 s after the attempt fails — so nothing is ever
    /// dropped for a transient failure. The endpoint is read fresh each send so a `configure(...)`
    /// that lands after construction is honoured — including one that switches logging off, which
    /// empties the queue and ends the loop.
    private func pump() {
        guard !inFlight, let next = pending.first else { return }
        guard let url = RemoteLoggerConfig.logURL else {
            pending.removeAll()
            return
        }
        inFlight = true

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = next.body

        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.inFlight = false
                let httpOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
                if error == nil && httpOK {
                    // Pop the acked line (guard against an empty buffer) and continue the FIFO.
                    if !self.pending.isEmpty { self.pending.removeFirst() }
                    self.pump()
                } else {
                    // Keep the line queued; retry shortly. No drop.
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.pump() }
                }
            }
        }.resume()
    }
}

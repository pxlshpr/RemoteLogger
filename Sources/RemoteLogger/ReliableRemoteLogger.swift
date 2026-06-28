import Foundation

/// A **drop-proof** sibling to ``RemoteLogger`` for traces that must NOT lose a single line under a
/// dense burst — the exact failure mode that defeats the fire-and-forget fast path (its ephemeral
/// `URLSession` caps at ~6 connections/host with a short timeout and no retry, so a burst of
/// hundreds of lines competes, times out, and silently drops some).
///
/// The mechanism (proven in the field on the #2009 add-burst-flicker trace, then extracted here so
/// it's reusable across projects):
///   • **Monotonic `seq=N` per line** → any residual drop is DETECTABLE as a gap, and the true
///     order is recoverable even if the network reorders. The seq is embedded in the message text
///     AND in `extra`.
///   • **Serialized single-connection FIFO sender** (`httpMaximumConnectionsPerHost = 1`), one
///     request in flight at a time, **retried with backoff** on failure (the line stays queued,
///     never dropped) — so a burst BUFFERS and drains in order instead of overflowing the
///     connection pool. The buffer is bounded; on overflow the OLDEST are dropped (the seq gap then
///     reveals the loss) so a permanently-unreachable server can't grow it without bound.
///   • **On-device file mirror**, appended synchronously on the serial queue → a complete record
///     even if the network drops everything.
///
/// It shares ``RemoteLoggerConfig`` with ``RemoteLogger`` (host/port/app/device/branch), so a single
/// `RemoteLogger.configure(...)` at startup configures both, and lines POST to the SAME `/log`
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

    /// All mutable state (`seq`, `pending`, `inFlight`) is confined to this serial queue.
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

    private var fileHandle: FileHandle?

    /// - Parameters:
    ///   - mirrorFileName: File under `Caches/` to mirror every line to. Distinct names let
    ///     concurrent investigations keep separate bulletproof local records.
    ///   - truncateOnInit: Truncate the mirror at construction so each run starts clean (the remote
    ///     server keeps the accumulated history). Defaults to `true` — the common case for a
    ///     per-run diagnostic trace.
    public init(mirrorFileName: String = "reliable-remote.log", truncateOnInit: Bool = true) {
        self.queue = DispatchQueue(label: "com.pxlshpr.reliable-remote-logger.\(mirrorFileName)")

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

        if let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent(mirrorFileName)
            if truncateOnInit || !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            self.fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? self.fileHandle?.seekToEnd()
        }
    }

    // MARK: - Public API (mirrors RemoteLogger so any trace can be made drop-proof by swapping in)

    public func debug(_ message: String, category: String = "", extra: [String: String] = [:]) {
        log(level: "debug", message: message, category: category, extra: extra)
    }

    public func info(_ message: String, category: String = "", extra: [String: String] = [:]) {
        log(level: "info", message: message, category: category, extra: extra)
    }

    public func warning(_ message: String, category: String = "", extra: [String: String] = [:]) {
        log(level: "warning", message: message, category: category, extra: extra)
    }

    public func error(_ message: String, category: String = "", extra: [String: String] = [:]) {
        log(level: "error", message: message, category: category, extra: extra)
    }

    // MARK: - Internals

    /// Cheap at the call site — dispatches the real work (seq stamp, file append, JSON encode,
    /// network enqueue) onto the serial queue.
    private func log(level: String, message: String, category: String, extra: [String: String]) {
        queue.async {
            self.seq += 1
            let seq = self.seq
            // Embed seq in the message text so order is recoverable even if `extra` is reordered or
            // the network drops a line (the gap is greppable in the human-readable log).
            let stamped = "seq=\(seq) \(message)"

            // 1. Mirror to the on-device file first (cannot drop).
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

    /// Drives the FIFO. Called on `queue`. Sends `pending.first`; on success pops it and continues,
    /// on failure leaves it queued and retries after a short backoff — so nothing is ever dropped
    /// for a transient failure. The endpoint is read fresh each send so a `configure(...)` that
    /// lands after construction is honoured.
    private func pump() {
        guard !inFlight, let next = pending.first else { return }
        inFlight = true

        var request = URLRequest(url: RemoteLoggerConfig.logURL)
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
                    // Keep the line queued; retry after a backoff. No drop.
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.pump() }
                }
            }
        }.resume()
    }
}

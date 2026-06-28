import Foundation
import OSLog

/// Fire-and-forget remote logger that sends structured logs to a Mac over Tailscale.
///
/// Configure once at app startup:
/// ```
/// RemoteLogger.configure(app: "MyApp")
/// ```
///
/// Then use anywhere:
/// ```
/// RemoteLogger.shared.info("Pulled 5 days", category: "sync-pull", extra: ["count": "5"])
/// ```
///
/// This is the **fast path**: one fire-and-forget HTTP POST per line through an ephemeral
/// `URLSession`, no retry. It's the right default for high-volume logging where the occasional
/// dropped line under a dense burst is acceptable. When a trace must NOT drop a single line under a
/// burst (e.g. an optimistic-UI-vs-refetch race), use ``ReliableRemoteLogger`` instead — it shares
/// the same configuration (host/port/app/device/branch) but guarantees ordered, gap-detectable,
/// drop-proof delivery.
public final class RemoteLogger: Sendable {
    public static let shared = RemoteLogger()

    /// Configure the logger. Call once at app startup. Configuration is shared with
    /// ``ReliableRemoteLogger`` (both read the same ``RemoteLoggerConfig``), so a single call wires
    /// up both the fast and the reliable path.
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
    public static func configure(
        app: String,
        host: String? = nil,
        port: Int? = nil,
        baseURL: String? = nil,
        device: String? = nil,
        branch: String? = nil
    ) {
        RemoteLoggerConfig.configure(app: app, host: host, port: port, baseURL: baseURL,
                                     device: device, branch: branch)
    }

    private let session: URLSession
    private let osLog = Logger(subsystem: "com.pxlshpr.remote-logger", category: "remote-logger")

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    public func debug(_ message: String, category: String = "", extra: [String: String] = [:]) {
        send(level: "debug", message: message, category: category, extra: extra)
    }

    public func info(_ message: String, category: String = "", extra: [String: String] = [:]) {
        send(level: "info", message: message, category: category, extra: extra)
    }

    public func warning(_ message: String, category: String = "", extra: [String: String] = [:]) {
        send(level: "warning", message: message, category: category, extra: extra)
    }

    public func error(_ message: String, category: String = "", extra: [String: String] = [:]) {
        send(level: "error", message: message, category: category, extra: extra)
    }

    // MARK: - Internals

    private func send(level: String, message: String, category: String, extra: [String: String]) {
        let payload = RemoteLoggerConfig.payload(level: level, message: message,
                                                 category: category, extra: extra)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: RemoteLoggerConfig.logURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Fire and forget — don't await, don't block
        let task = session.dataTask(with: request) { _, _, error in
            if let error {
                self.osLog.debug("RemoteLogger send failed: \(error.localizedDescription)")
            }
        }
        task.resume()
    }
}

// MARK: - Shared configuration

/// The single source of truth for where logs go and what identity they carry. Both
/// ``RemoteLogger`` (fast path) and ``ReliableRemoteLogger`` (drop-proof path) read it, so they
/// always agree on host/port/app and so a single `RemoteLogger.configure(...)` configures both —
/// no second hardcoded endpoint to drift out of sync (the trap the old per-feature reliable logger
/// warned about).
enum RemoteLoggerConfig {
    /// Tailscale IP of the Mac running log_server.py (pxlhome's current Tailscale IP).
    private static let defaultHost = "100.116.221.123"
    private static let defaultPort = 9876

    private static let _app = ManagedAtomic<String?>(nil)
    private static let _host = ManagedAtomic<String?>(nil)
    private static let _port = ManagedAtomic<Int?>(nil)
    private static let _baseURL = ManagedAtomic<String?>(nil)
    private static let _device = ManagedAtomic<String?>(nil)
    private static let _branch = ManagedAtomic<String?>(nil)

    /// Cached — `ISO8601DateFormatter` is documented thread-safe for formatting and expensive to
    /// construct.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    static func configure(
        app: String,
        host: String?,
        port: Int?,
        baseURL: String?,
        device: String?,
        branch: String?
    ) {
        _app.store(app)
        if let host { _host.store(host) }
        if let port { _port.store(port) }
        if let baseURL { _baseURL.store(baseURL) }
        if let device { _device.store(device) }
        if let branch { _branch.store(branch) }
    }

    static var app: String? { _app.load() }
    static var device: String? { _device.load() }
    static var branch: String? { _branch.load() }

    /// The `/log` endpoint, honouring a full `baseURL` override or the host/port pair.
    static var logURL: URL {
        let urlString: String
        if let base = _baseURL.load() {
            urlString = "\(base)/log"
        } else {
            let host = _host.load() ?? defaultHost
            let port = _port.load() ?? defaultPort
            urlString = "http://\(host):\(port)/log"
        }
        return URL(string: urlString)!
    }

    /// Builds a `/log` payload carrying the configured app/device/branch identity. `device` and
    /// `branch` are included only when configured, so apps that never set them (and older builds)
    /// stay byte-compatible with the server's per-app fallback.
    static func payload(
        level: String,
        message: String,
        category: String,
        extra: [String: String]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "timestamp": iso8601.string(from: Date()),
            "level": level,
            "category": category,
            "message": message,
            "extra": extra
        ]
        if let app = _app.load() { payload["app"] = app }
        if let device = _device.load(), !device.isEmpty { payload["device"] = device }
        if let branch = _branch.load(), !branch.isEmpty { payload["branch"] = branch }
        return payload
    }
}

// MARK: - Lock-free atomic storage (no Foundation locks needed)

/// Minimal lock-free atomic wrapper using os_unfair_lock for Sendable compliance.
final class ManagedAtomic<T>: @unchecked Sendable {
    private var _value: T
    private var _lock = os_unfair_lock()

    init(_ value: T) {
        self._value = value
    }

    func load() -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _value
    }

    func store(_ newValue: T) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        _value = newValue
    }
}

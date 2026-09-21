import Foundation
import OSLog

/// **Deprecated — prefer ``ReliableRemoteLogger``.** Fire-and-forget remote logger that sends
/// structured logs to a Mac over Tailscale.
///
/// This is the legacy **fast path**: one fire-and-forget HTTP POST per line through an ephemeral
/// `URLSession`, no retry. Under a dense burst its ~6-connections/host cap and short timeout cause
/// some lines to compete, time out, and be **silently dropped** — the failure mode
/// ``ReliableRemoteLogger`` was built to eliminate (ordered `seq=N`, retried FIFO delivery, plus an
/// on-device mirror). New code should use `ReliableRemoteLogger`; existing call sites still compile
/// and run, and can migrate over time.
///
/// Both types share one ``RemoteLoggerConfig``, so a single
/// ``ReliableRemoteLogger/configure(app:host:port:baseURL:device:branch:enabled:)`` at startup
/// configures both paths — and until that call is made, **nothing is sent** (see the config).
@available(*, deprecated, message: "Prefer ReliableRemoteLogger: ordered, gap-detectable, drop-proof delivery with an on-device mirror. RemoteLogger is fire-and-forget and silently drops lines under a dense burst. Configure via ReliableRemoteLogger.configure(...).")
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
    ///   - enabled: Whether any line leaves the device at all. `nil` (the default) means **on in a
    ///     `DEBUG` build of this package, off in every other build**; pass `true`/`false` to decide
    ///     explicitly. See ``ReliableRemoteLogger/configure(app:host:port:baseURL:device:branch:enabled:)``.
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

    /// True once `configure(...)` has switched logging on. See ``ReliableRemoteLogger/isEnabled``.
    public static var isEnabled: Bool { RemoteLoggerConfig.isEnabled }

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

    /// `message` is an autoclosure so a disabled logger never even builds the string — the
    /// interpolations at a call site in a hot path cost nothing in a build that does not log.
    public func debug(_ message: @autoclosure () -> String, category: String = "", extra: [String: String] = [:]) {
        send(level: "debug", message: message, category: category, extra: extra)
    }

    public func info(_ message: @autoclosure () -> String, category: String = "", extra: [String: String] = [:]) {
        send(level: "info", message: message, category: category, extra: extra)
    }

    public func warning(_ message: @autoclosure () -> String, category: String = "", extra: [String: String] = [:]) {
        send(level: "warning", message: message, category: category, extra: extra)
    }

    public func error(_ message: @autoclosure () -> String, category: String = "", extra: [String: String] = [:]) {
        send(level: "error", message: message, category: category, extra: extra)
    }

    // MARK: - Internals

    private func send(level: String, message: () -> String, category: String, extra: [String: String]) {
        // Off (unconfigured, or configured off — every non-DEBUG build by default): nothing is
        // built, nothing is sent.
        guard let url = RemoteLoggerConfig.logURL else { return }

        let payload = RemoteLoggerConfig.payload(level: level, message: message(),
                                                 category: category, extra: extra)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
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

/// The single source of truth for where logs go, what identity they carry, and **whether they go
/// at all**. Both ``RemoteLogger`` (fast path) and ``ReliableRemoteLogger`` (drop-proof path) read
/// it, so they always agree on host/port/app and so a single `configure(...)` configures both — no
/// second hardcoded endpoint to drift out of sync (the trap the old per-feature reliable logger
/// warned about).
///
/// **Unconfigured means silent.** Until `configure(...)` runs, `isEnabled` is false and `logURL`
/// is nil: no request is built, no mirror file is opened, no retry loop starts. `defaultHost` is
/// a default *host* for an app that has opted in, never a default *state* — the 1.x behaviour
/// (any line from any build, configured or not, POSTed cleartext to the dev Mac's Tailscale IP)
/// meant every App Store build of every consumer ran a permanent failing-retry loop carrying
/// real content to a CGNAT address it could not route to (NutriKit #3252).
enum RemoteLoggerConfig {
    /// Tailscale IP of the Mac running log_server.py (pxlhome's current Tailscale IP). Consulted
    /// only once an app has switched logging on.
    private static let defaultHost = "100.116.221.123"
    private static let defaultPort = 9876

    /// What `configure(enabled: nil)` resolves to: on in a `DEBUG` build of this package, off in
    /// every other. A consumer whose debug configuration is not named `Debug` (Xcode defines
    /// `DEBUG` for a package only under that name) should pass `enabled:` explicitly.
    static var defaultEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static let _enabled = ManagedAtomic<Bool>(false)
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
        branch: String?,
        enabled: Bool?
    ) {
        _app.store(app)
        if let host { _host.store(host) }
        if let port { _port.store(port) }
        if let baseURL { _baseURL.store(baseURL) }
        if let device { _device.store(device) }
        if let branch { _branch.store(branch) }
        _enabled.store(enabled ?? defaultEnabled)
    }

    /// True only after a `configure(...)` that switched logging on.
    static var isEnabled: Bool { _enabled.load() }

    static var app: String? { _app.load() }
    static var device: String? { _device.load() }
    static var branch: String? { _branch.load() }

    /// The `/log` endpoint, honouring a full `baseURL` override or the host/port pair — or `nil`
    /// while logging is off, which is what every sender checks before building anything.
    static var logURL: URL? {
        guard isEnabled else { return nil }
        let urlString: String
        if let base = _baseURL.load() {
            urlString = "\(base)/log"
        } else {
            let host = _host.load() ?? defaultHost
            let port = _port.load() ?? defaultPort
            urlString = "http://\(host):\(port)/log"
        }
        return URL(string: urlString)
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

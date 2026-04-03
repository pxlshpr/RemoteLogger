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
public final class RemoteLogger: Sendable {
    public static let shared = RemoteLogger()

    // MARK: - Configuration

    /// Tailscale IP of the Mac running log_server.py
    private let serverHost = "100.116.221.123"
    private let serverPort = 9876

    private let session: URLSession
    private let osLog = Logger(subsystem: "com.pxlshpr.remote-logger", category: "remote-logger")

    /// App name sent with every log entry. Set via `configure(app:)`.
    private static let _appName = ManagedAtomic<String?>(nil)

    /// Configure the logger with an app name. Call once at app startup.
    ///
    /// - Parameters:
    ///   - app: App name sent with every log entry.
    ///   - host: Override the default Tailscale IP.
    ///   - port: Override the default port.
    ///   - baseURL: Full base URL (e.g. "https://host.ts.net"). When set, host/port are ignored.
    public static func configure(app: String, host: String? = nil, port: Int? = nil, baseURL: String? = nil) {
        _appName.store(app)
        if let baseURL { shared._overrideBaseURL.store(baseURL) }
        if let host { shared._overrideHost.store(host) }
        if let port { shared._overridePort.store(port) }
    }

    private let _overrideBaseURL = ManagedAtomic<String?>(nil)
    private let _overrideHost = ManagedAtomic<String?>(nil)
    private let _overridePort = ManagedAtomic<Int?>(nil)

    private var effectiveHost: String { _overrideHost.load() ?? serverHost }
    private var effectivePort: Int { _overridePort.load() ?? serverPort }

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
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": level,
            "category": category,
            "message": message,
            "extra": extra
        ]

        if let appName = Self._appName.load() {
            payload["app"] = appName
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let urlString: String
        if let base = _overrideBaseURL.load() {
            urlString = "\(base)/log"
        } else {
            urlString = "http://\(effectiveHost):\(effectivePort)/log"
        }
        var request = URLRequest(url: URL(string: urlString)!)
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

// MARK: - Lock-free atomic storage (no Foundation locks needed)

/// Minimal lock-free atomic wrapper using os_unfair_lock for Sendable compliance.
private final class ManagedAtomic<T>: @unchecked Sendable {
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

import Foundation
import Network

public enum LoopbackListenerError: Error, LocalizedError {
    case serverCreationFailed
    case cancelled
    case timeout
    case invalidRequest

    public var errorDescription: String? {
        switch self {
        case .serverCreationFailed: return "无法创建本地回环监听服务"
        case .cancelled: return "授权监听已取消"
        case .timeout: return "等待浏览器授权超时"
        case .invalidRequest: return "无效的回调请求"
        }
    }
}

public final class LoopbackListener: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.gmailping.loopback")

    public init() {}

    public func start() throws -> Int {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let semaphore = DispatchSemaphore(value: 0)
        var boundPort: Int = 0
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    boundPort = Int(port)
                }
                semaphore.signal()
            case .failed(let err):
                startError = err
                semaphore.signal()
            default:
                break
            }
        }

        listener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5.0)

        if let startError = startError {
            throw startError
        }
        guard boundPort > 0 else {
            throw LoopbackListenerError.serverCreationFailed
        }

        return boundPort
    }

    public func waitForCallback(timeoutSeconds: TimeInterval = 120) async throws -> [String: String] {
        guard let listener = self.listener else {
            throw LoopbackListenerError.serverCreationFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let hasResumed = ManagedAtomicBool(false)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler { [weak self] in
                if hasResumed.compareAndSwap(expected: false, desired: true) {
                    self?.stop()
                    continuation.resume(throwing: LoopbackListenerError.timeout)
                }
            }
            timer.resume()

            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    guard let data = data, let requestString = String(data: data, encoding: .utf8) else {
                        return
                    }

                    // Parse request line: e.g. GET /callback?code=...&state=... HTTP/1.1
                    let lines = requestString.components(separatedBy: "\r\n")
                    guard let requestLine = lines.first else { return }
                    let parts = requestLine.components(separatedBy: " ")
                    guard parts.count >= 2 else { return }

                    let urlString = "http://127.0.0.1" + parts[1]
                    guard let components = URLComponents(string: urlString) else { return }

                    var queryItems: [String: String] = [:]
                    for item in components.queryItems ?? [] {
                        queryItems[item.name] = item.value ?? ""
                    }

                    // Send response
                    let html = """
                    <!DOCTYPE html>
                    <html lang="zh-CN">
                    <head><meta charset="utf-8"><title>GmailPing 授权</title>
                    <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:40px;text-align:center;background:#f5f5f7;color:#1d1d1f;}
                    .card{background:white;padding:30px;border-radius:12px;box-shadow:0 4px 12px rgba(0,0,0,0.08);display:inline-block;max-width:400px;}
                    h1{font-size:20px;margin-bottom:12px;}p{font-size:14px;color:#6e6e73;}</style></head>
                    <body><div class="card"><h1>授权已完成</h1><p>请返回 GmailPing 应用，您可以关闭此网页标签。</p></div></body></html>
                    """
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    if let respData = response.data(using: .utf8) {
                        connection.send(content: respData, completion: .contentProcessed({ _ in
                            connection.cancel()
                        }))
                    } else {
                        connection.cancel()
                    }

                    timer.cancel()
                    self?.stop()

                    if hasResumed.compareAndSwap(expected: false, desired: true) {
                        continuation.resume(returning: queryItems)
                    }
                }
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class ManagedAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func compareAndSwap(expected: Bool, desired: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value == expected {
            value = desired
            return true
        }
        return false
    }
}

import Foundation
import Network

public enum LoopbackListenerError: Error, LocalizedError, Equatable {
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
    private var hasResumed = ManagedAtomicBool(false)
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var timer: DispatchSourceTimer?
    private var expectedState: String?

    public init() {}

    public func start(expectedState: String? = nil) throws -> Int {
        self.expectedState = expectedState
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
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

        // newConnectionHandler MUST be set before calling listener.start()
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            // Restrict connection strictly to loopback interface (127.0.0.1 / ::1)
            if case .hostPort(let host, _) = connection.endpoint {
                let hostStr = "\(host)"
                guard hostStr == "127.0.0.1" || hostStr == "::1" else {
                    connection.cancel()
                    return
                }
            }
            self.handleIncomingConnection(connection)
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

    public func waitForCallback(expectedState: String? = nil, timeoutSeconds: TimeInterval = 120) async throws -> [String: String] {
        guard self.listener != nil else {
            throw LoopbackListenerError.serverCreationFailed
        }
        if let expectedState = expectedState {
            self.expectedState = expectedState
        }

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                if self.hasResumed.compareAndSwap(expected: false, desired: true) {
                    self.stop()
                    cont.resume(throwing: LoopbackListenerError.timeout)
                }
            }
            timer.resume()
            self.timer = timer
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let requestString = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let lines = requestString.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                connection.cancel()
                return
            }
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }

            let pathAndQuery = parts[1]
            guard let components = URLComponents(string: "http://127.0.0.1" + pathAndQuery) else {
                connection.cancel()
                return
            }

            // Ignore favicon or non-callback paths
            if components.path == "/favicon.ico" {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: notFound.data(using: .utf8), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
                return
            }

            var queryItems: [String: String] = [:]
            for item in components.queryItems ?? [] {
                queryItems[item.name] = item.value ?? ""
            }

            // Only complete if state matches expectedState (if expectedState is set)
            if let expected = self.expectedState {
                guard let receivedState = queryItems["state"], receivedState == expected else {
                    let bad = "HTTP/1.1 400 Bad Request\r\nContent-Length: 13\r\nConnection: close\r\n\r\nState Mismatch"
                    connection.send(content: bad.data(using: .utf8), completion: .contentProcessed({ _ in
                        connection.cancel()
                    }))
                    return
                }
            }

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

            self.timer?.cancel()
            self.stop()

            if self.hasResumed.compareAndSwap(expected: false, desired: true) {
                self.continuation?.resume(returning: queryItems)
            }
        }
    }

    public func cancel() {
        if hasResumed.compareAndSwap(expected: false, desired: true) {
            timer?.cancel()
            stop()
            continuation?.resume(throwing: LoopbackListenerError.cancelled)
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

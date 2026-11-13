import Foundation

/// WebSocket 传输抽象：provider 不直接依赖 URLSessionWebSocketTask，便于 fake 测试。
protocol VolcengineWebSocketTransport: AnyObject {
    /// 建立连接（URLRequest 中带鉴权 header）。
    func connect(request: URLRequest) async throws
    func send(_ data: Data) async throws
    /// 返回下一帧二进制数据；`nil` 表示连接已正常关闭。
    func receive() async throws -> Data?
    func close()
    /// 握手响应中的 `X-Tt-Logid`（如可获得）。
    var logID: String? { get }
}

/// 基于 URLSessionWebSocketTask 的生产实现。
final class URLSessionWebSocketTransport: VolcengineWebSocketTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    var logID: String? {
        guard let response = task?.response as? HTTPURLResponse else { return nil }
        return response.value(forHTTPHeaderField: "X-Tt-Logid")
    }

    func connect(request: URLRequest) async throws {
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        // 握手失败的 HTTP 状态会在首次 send/receive 时以 URLError 抛给调用方。
    }

    func send(_ data: Data) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.data(data))
    }

    func receive() async throws -> Data? {
        guard let task else { return nil }
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return nil
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

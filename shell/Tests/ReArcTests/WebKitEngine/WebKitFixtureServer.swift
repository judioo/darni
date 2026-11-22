import Foundation
import Network

/// Loopback HTTP/1.1 server for the WebKit engine tests: 127.0.0.1 only, one
/// ephemeral port, one response per connection. Each test makes its own, so
/// routes and the request log never cross tests.
final class WebKitFixtureServer {
    struct Request: Equatable {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]

        /// The request's cookies by name.
        var cookies: [String: String] {
            var result: [String: String] = [:]
            for pair in (headers["cookie"] ?? "").split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
            return result
        }
    }

    struct Response {
        var status = 200
        var type = "text/html; charset=utf-8"
        var headers: [String: String] = [:]
        var body = Data()

        static func html(_ body: String, headers: [String: String] = [:]) -> Response {
            Response(headers: headers, body: Data(body.utf8))
        }

        static func page(title: String, body: String = "", head: String = "", headers: [String: String] = [:]) -> Response {
            html("<!doctype html><html><head><title>\(title)</title>\(head)</head><body>\(body)</body></html>", headers: headers)
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "net.rearc.tests.webkit-fixture")
    private let lock = NSLock()
    private var storedRoutes: [String: (Request) -> Response] = [:]
    private var storedRequests: [Request] = []
    private(set) var port: UInt16 = 0

    /// Every request received so far, in arrival order.
    var requests: [Request] { lock.withLock { storedRequests } }

    func requests(for path: String) -> [Request] { requests.filter { $0.path == path } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "the fixture server did not start"])
        }
        self.port = port
    }

    deinit { listener.cancel() }

    func stop() { listener.cancel() }

    /// `http://127.0.0.1:<port><path>`; `host` picks another loopback name (`localhost`) for a second site.
    func url(_ path: String, host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    func route(_ path: String, _ response: @escaping (Request) -> Response) {
        lock.withLock { storedRoutes[path] = response }
    }

    func route(_ path: String, _ response: Response) {
        route(path) { _ in response }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if isComplete || error != nil || buffer.count > 256 * 1024 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    static func parse(_ head: String) -> Request? {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let target = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(requestLine[0]), path: String(target[0]),
                       query: target.count > 1 ? String(target[1]) : "", headers: headers)
    }

    private func respond(to head: String, on connection: NWConnection) {
        guard let request = Self.parse(head) else { return connection.cancel() }
        let handler = lock.withLock { () -> ((Request) -> Response)? in
            storedRequests.append(request)
            return storedRoutes[request.path]
        }
        let response = handler?(request) ?? Response(status: 404, body: Data("not found".utf8))
        var text = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
        text += "Content-Type: \(response.type)\r\n"
        text += "Content-Length: \(response.body.count)\r\n"
        text += "Cache-Control: no-store\r\n"
        text += "Connection: close\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var payload = Data(text.utf8)
        if request.method != "HEAD" { payload.append(response.body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

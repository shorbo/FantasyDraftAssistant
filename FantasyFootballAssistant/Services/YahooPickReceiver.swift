import Foundation
import Network

// A deliberately small HTTP server for a local browser extension. Binding the
// listener to 127.0.0.1 means it is unreachable from the LAN. The companion
// developer-installed extension posts only to this fixed local endpoint, so
// there is no per-draft credential to configure.
final class YahooPickReceiver: @unchecked Sendable {
    static let port: UInt16 = 8765

    private var listener: NWListener?
    var onPick: (@Sendable (YahooDraftPickEvent) -> Void)?

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: Self.port)!
        )
        // With a required local endpoint, the listener takes its port from
        // that endpoint. Supplying it again to NWListener is rejected by the
        // Network framework at runtime.
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: DispatchQueue(label: "YahooPickReceiver"))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "YahooPickReceiver.connection"))
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var combined = buffer
            if let data { combined.append(data) }
            guard combined.count <= 65_536 else {
                self.send(self.response(413, "Request too large"), on: connection)
                return
            }
            if self.hasCompleteRequest(combined) {
                self.send(self.process(combined), on: connection)
            } else if isComplete {
                self.send(self.response(400, "Malformed request"), on: connection)
            } else {
                self.receiveRequest(on: connection, buffer: combined)
            }
        }
    }

    private func send(_ response: String, on connection: NWConnection) {
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func hasCompleteRequest(_ data: Data) -> Bool {
        guard let request = String(data: data, encoding: .utf8),
              let separator = request.range(of: "\r\n\r\n") else { return false }
        let headers = request[..<separator.lowerBound]
        let contentLength = headers.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return request[separator.upperBound...].utf8.count >= contentLength
    }

    private func process(_ data: Data) -> String {
        guard let request = String(data: data, encoding: .utf8),
              let separator = request.range(of: "\r\n\r\n") else {
            return response(400, "Malformed request")
        }
        let headerLines = request[..<separator.lowerBound].components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first, requestLine == "POST /api/draft/pick HTTP/1.1" else {
            return response(404, "Not found")
        }
        let body = String(request[separator.upperBound...])
        guard let event = try? JSONDecoder().decode(YahooDraftPickEvent.self, from: Data(body.utf8)) else {
            return response(400, "Invalid JSON")
        }
        do {
            try event.validate()
            onPick?(event)
            return response(202, "Accepted")
        } catch {
            return response(422, error.localizedDescription)
        }
    }

    private func response(_ status: Int, _ message: String) -> String {
        let payload = "{\"message\":\"\(message.replacingOccurrences(of: "\"", with: "'"))\"}"
        return "HTTP/1.1 \(status) \(message)\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
    }
}

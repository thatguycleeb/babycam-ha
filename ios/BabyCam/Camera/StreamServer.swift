import Foundation
import Network

/// Runs on the camera phone.
///  - Port 8080 (HTTP): serves viewer.html to browsers.
///  - Port 8081 (WebSocket): streams video/audio/status to viewers and accepts commands.
///    Also advertised over Bonjour so the iPhone viewer finds it automatically.
final class StreamServer {
    var onCommand: ((ClientCommand) -> Void)?
    var onViewerCountChange: ((Int) -> Void)?

    private final class Viewer {
        let connection: NWConnection
        var videoInFlight = 0
        var audioInFlight = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "babycam.server")
    private let pairingCode: String
    private let viewerPage: Data
    private var httpListener: NWListener?
    private var streamListener: NWListener?
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var latestStatus: Data?
    private var isRunning = false

    init(pairingCode: String) {
        self.pairingCode = pairingCode
        let url = Bundle.main.url(forResource: "viewer", withExtension: "html")
        viewerPage = url.flatMap { try? Data(contentsOf: $0) }
            ?? Data("viewer.html is missing from the app bundle.".utf8)
    }

    func start() {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.startHTTPListener()
            self.startStreamListener()
        }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            self.httpListener?.cancel()
            self.streamListener?.cancel()
            self.httpListener = nil
            self.streamListener = nil
            for viewer in Array(self.viewers.values) { self.drop(viewer) }
        }
    }

    // MARK: - Broadcasting

    func broadcastVideo(_ jpeg: Data) {
        queue.async {
            guard !self.viewers.isEmpty else { return }
            let packet = Self.packet(.video, jpeg)
            // Skip frames for viewers whose Wi-Fi can't keep up, instead of building a backlog.
            for viewer in self.viewers.values where viewer.videoInFlight < 2 {
                viewer.videoInFlight += 1
                self.send(packet, opcode: .binary, to: viewer) { viewer.videoInFlight -= 1 }
            }
        }
    }

    func broadcastAudio(_ pcm: Data) {
        queue.async {
            guard !self.viewers.isEmpty else { return }
            let packet = Self.packet(.audio, pcm)
            for viewer in self.viewers.values where viewer.audioInFlight < 12 {
                viewer.audioInFlight += 1
                self.send(packet, opcode: .binary, to: viewer) { viewer.audioInFlight -= 1 }
            }
        }
    }

    func broadcastStatus(_ status: CameraStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        queue.async {
            self.latestStatus = data
            for viewer in self.viewers.values {
                self.send(data, opcode: .text, to: viewer)
            }
        }
    }

    private static func packet(_ type: PacketType, _ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 1)
        data.append(type.rawValue)
        data.append(payload)
        return data
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, to viewer: Viewer,
                      completion: (() -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "babycam", metadata: [metadata])
        viewer.connection.send(content: data, contentContext: context, isComplete: true,
                               completion: .contentProcessed { _ in completion?() })
    }

    // MARK: - WebSocket stream listener

    private func startStreamListener() {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 64 * 1024
        let expected = BabyCam.subprotocol(for: pairingCode)
        wsOptions.setClientRequestHandler(queue) { subprotocols, _ in
            if subprotocols.contains(expected) {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: expected, additionalHeaders: nil)
            }
            return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil, additionalHeaders: nil)
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: BabyCam.streamPort)!)
            listener.service = NWListener.Service(name: "BabyCam", type: BabyCam.bonjourType)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    print("Stream listener failed: \(error). Retrying…")
                    self?.retry { $0.startStreamListener() }
                }
            }
            listener.start(queue: queue)
            streamListener = listener
        } catch {
            print("Could not create stream listener: \(error)")
            retry { $0.startStreamListener() }
        }
    }

    private func retry(_ restart: @escaping (StreamServer) -> Void) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isRunning else { return }
            restart(self)
        }
    }

    private func accept(_ connection: NWConnection) {
        let viewer = Viewer(connection)
        let id = ObjectIdentifier(viewer)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.viewers[id] = viewer
                self.onViewerCountChange?(self.viewers.count)
                if let status = self.latestStatus {
                    self.send(status, opcode: .text, to: viewer)
                }
                self.receive(from: viewer)
            case .failed, .cancelled:
                self.drop(viewer)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(from viewer: Viewer) {
        viewer.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                self.drop(viewer)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close || (data == nil && metadata == nil) {
                self.drop(viewer)
                return
            }
            if metadata?.opcode == .text, let data,
               let command = try? JSONDecoder().decode(ClientCommand.self, from: data) {
                self.onCommand?(command)
            }
            self.receive(from: viewer)
        }
    }

    private func drop(_ viewer: Viewer) {
        viewer.connection.stateUpdateHandler = nil
        viewer.connection.cancel()
        if viewers.removeValue(forKey: ObjectIdentifier(viewer)) != nil {
            onViewerCountChange?(viewers.count)
        }
    }

    // MARK: - HTTP listener (serves the browser viewer)

    private func startHTTPListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: BabyCam.httpPort)!)
            listener.newConnectionHandler = { [weak self] connection in self?.serveHTTP(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    print("HTTP listener failed: \(error). Retrying…")
                    self?.retry { $0.startHTTPListener() }
                }
            }
            listener.start(queue: queue)
            httpListener = listener
        } catch {
            print("Could not create HTTP listener: \(error)")
            retry { $0.startHTTPListener() }
        }
    }

    private func serveHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // "GET /path HTTP/1.1"
            let path = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"

            let response: Data
            if path == "/" || path.hasPrefix("/?") || path == "/index.html" {
                response = Self.httpResponse("200 OK", type: "text/html; charset=utf-8", body: self.viewerPage)
            } else {
                response = Self.httpResponse("404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func httpResponse(_ status: String, type: String, body: Data) -> Data {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

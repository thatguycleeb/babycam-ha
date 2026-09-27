import Foundation
import Network
import UIKit

final class ViewerModel: ObservableObject {
    enum Phase: Equatable { case choosing, connecting, live, reconnecting }

    @Published var phase: Phase = .choosing
    @Published var errorMessage: String?
    @Published var cameras: [NWEndpoint] = []
    @Published var frame: UIImage?
    @Published var status: CameraStatus?
    @Published var level: Float = AudioLevel.silence
    @Published var noiseAlert = false
    @Published var isMuted = false {
        didSet { player.isMuted = isMuted }
    }
    @Published var code: String {
        didSet { defaults.set(code, forKey: "viewer.code") }
    }
    @Published var manualAddress: String {
        didSet { defaults.set(manualAddress, forKey: "viewer.address") }
    }
    @Published var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: "viewer.alerts") }
    }
    @Published var alertThreshold: Float {
        didSet { defaults.set(alertThreshold, forKey: "viewer.threshold") }
    }

    /// Minimum time between noise notifications.
    private let alertCooldown: TimeInterval = 30

    private let defaults = UserDefaults.standard
    private let netQueue = DispatchQueue(label: "babycam.viewer")
    private let player = AudioPlayer()
    private let haptics = UINotificationFeedbackGenerator()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var target: NWEndpoint?
    private var everConnected = false
    private var loudStreak = 0
    private var lastAlert = Date.distantPast
    private var alertReset: DispatchWorkItem?

    init() {
        let saved = UserDefaults.standard
        code = saved.string(forKey: "viewer.code") ?? ""
        manualAddress = saved.string(forKey: "viewer.address") ?? ""
        alertsEnabled = saved.object(forKey: "viewer.alerts") as? Bool ?? true
        alertThreshold = saved.object(forKey: "viewer.threshold") != nil
            ? saved.float(forKey: "viewer.threshold") : -35
    }

    static func displayName(_ endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return "\(endpoint)"
    }

    // MARK: - Finding cameras (Bonjour)

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: BabyCam.bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            DispatchQueue.main.async { self?.cameras = endpoints }
        }
        browser.start(queue: netQueue)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Connecting

    func connect(to endpoint: NWEndpoint) {
        code = code.filter(\.isNumber)
        guard !code.isEmpty else {
            errorMessage = "Enter the pairing code shown on the camera phone."
            return
        }
        errorMessage = nil
        target = endpoint
        everConnected = false
        Notifier.requestPermission()
        openConnection()
    }

    func connectManually() {
        let host = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        connect(to: .hostPort(host: NWEndpoint.Host(host),
                              port: NWEndpoint.Port(rawValue: BabyCam.streamPort)!))
    }

    func disconnect() {
        target = nil
        connection?.cancel()
        connection = nil
        player.stop()
        frame = nil
        status = nil
        noiseAlert = false
        phase = .choosing
    }

    private func openConnection() {
        guard let target else { return }
        connection?.cancel()

        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 8 * 1024 * 1024
        ws.setSubprotocols([BabyCam.subprotocol(for: code)])
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let conn = NWConnection(to: target, using: params)
        connection = conn
        phase = everConnected ? .reconnecting : .connecting
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.handle(state, of: conn) }
        }
        conn.start(queue: netQueue)
    }

    private func handle(_ state: NWConnection.State, of conn: NWConnection) {
        guard conn === connection else { return }
        switch state {
        case .ready:
            everConnected = true
            errorMessage = nil
            phase = .live
            player.start()
            receive(on: conn)
        case .waiting, .failed:
            connectionLost()
        default:
            break
        }
    }

    private func connectionLost() {
        connection?.cancel()
        connection = nil
        guard target != nil else { return }

        if !everConnected {
            target = nil
            phase = .choosing
            errorMessage = "Couldn't connect. Make sure BabyCam is open in Camera mode on the other phone and the pairing code matches."
            return
        }
        if phase == .live {
            haptics.notificationOccurred(.error)
            Notifier.post(title: "BabyCam disconnected", body: "Lost connection to the camera. Reconnecting…")
        }
        phase = .reconnecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.target != nil, self.connection == nil else { return }
            self.openConnection()
        }
    }

    // MARK: - Receiving (netQueue)

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close || (data == nil && metadata == nil) {
                DispatchQueue.main.async {
                    if conn === self.connection { self.connectionLost() }
                }
                return
            }
            if let data {
                switch metadata?.opcode {
                case .binary: self.handleBinary(data)
                case .text: self.handleText(data)
                default: break
                }
            }
            self.receive(on: conn)
        }
    }

    private func handleBinary(_ data: Data) {
        guard let first = data.first, let type = PacketType(rawValue: first) else { return }
        let payload = Data(data.dropFirst())   // copy so Int16 samples are aligned
        switch type {
        case .video:
            guard let image = UIImage(data: payload)?.preparingForDisplay() else { return }
            DispatchQueue.main.async { self.frame = image }
        case .audio:
            player.enqueue(payload)
            let db = payload.withUnsafeBytes { AudioLevel.dbfs($0.bindMemory(to: Int16.self)) }
            DispatchQueue.main.async { self.updateLevel(db) }
        }
    }

    private func handleText(_ data: Data) {
        guard let status = try? JSONDecoder().decode(CameraStatus.self, from: data),
              status.type == "status" else { return }
        DispatchQueue.main.async { self.status = status }
    }

    // MARK: - Noise alerts (main)

    private func updateLevel(_ db: Float) {
        level = db
        guard alertsEnabled else { loudStreak = 0; return }

        // Require ~0.25 s of sound over the line, so a single click doesn't trigger it.
        loudStreak = db > alertThreshold ? loudStreak + 1 : 0
        guard loudStreak >= 3 else { return }

        noiseAlert = true
        alertReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.noiseAlert = false }
        alertReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: reset)

        guard Date().timeIntervalSince(lastAlert) > alertCooldown else { return }
        lastAlert = Date()
        haptics.notificationOccurred(.warning)
        if UIApplication.shared.applicationState != .active {
            Notifier.post(title: "Noise detected", body: "BabyCam heard something.")
        }
    }

    // MARK: - Commands

    func swapCamera() { send(ClientCommand(cmd: "swap")) }
    func toggleTorch() { send(ClientCommand(cmd: "torch", value: !(status?.torch ?? false))) }
    func toggleNight() { send(ClientCommand(cmd: "night", value: !(status?.night ?? false))) }
    func rotate() { send(ClientCommand(cmd: "rotate")) }

    private func send(_ command: ClientCommand) {
        guard let conn = connection, let data = try? JSONEncoder().encode(command) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "command", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

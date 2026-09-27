import AVFoundation
import UIKit

/// Glues the camera, microphone and server together for the camera-phone screen.
final class CameraModel: ObservableObject {
    @Published var viewerCount = 0
    @Published var status = CameraStatus(camera: "back", torch: false, hasTorch: false, night: false, rotation: 90)
    @Published var level: Float = AudioLevel.silence
    @Published var isDark = false
    @Published var address: String?
    @Published var permissionProblem: String?

    let pairingCode: String
    let streamer = CameraStreamer()
    private let audio = AudioCapture()
    private let server: StreamServer
    private var savedBrightness: CGFloat?
    private var running = false

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "camera.code") {
            pairingCode = saved
        } else {
            let code = String(format: "%06d", Int.random(in: 0...999_999))
            defaults.set(code, forKey: "camera.code")
            pairingCode = code
        }
        server = StreamServer(pairingCode: pairingCode)

        streamer.onJPEG = { [server] jpeg in server.broadcastVideo(jpeg) }
        streamer.onStatusChange = { [weak self, server] status in
            server.broadcastStatus(status)
            DispatchQueue.main.async { self?.status = status }
        }
        audio.onPCM = { [server] pcm in server.broadcastAudio(pcm) }
        audio.onLevel = { [weak self] db in
            DispatchQueue.main.async { self?.level = db }
        }
        server.onViewerCountChange = { [weak self, streamer] count in
            streamer.isStreaming.set(count > 0)
            DispatchQueue.main.async { self?.viewerCount = count }
        }
        server.onCommand = { [weak self] command in
            DispatchQueue.main.async { self?.handle(command) }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        UIApplication.shared.isIdleTimerDisabled = true   // never auto-lock while streaming
        address = NetworkInfo.wifiIPv4Address()

        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVAudioApplication.requestRecordPermission { audioOK in
                DispatchQueue.main.async {
                    guard self.running else { return }
                    if !videoOK || !audioOK {
                        self.permissionProblem = "BabyCam needs camera and microphone access. Turn them on in Settings › BabyCam."
                    }
                    if videoOK { self.streamer.start() }
                    if audioOK { self.audio.start() }
                    self.server.start()
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        setDark(false)
        server.stop()
        streamer.stop()
        audio.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// "Low power" screen: black, minimum backlight. The camera keeps streaming.
    func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        if dark {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0
        } else if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
        }
    }

    func swapCamera() { streamer.swapCamera() }
    func toggleTorch() { streamer.setTorch(!status.torch) }
    func toggleNight() { streamer.setNight(!status.night) }
    func rotate() { streamer.rotate() }

    private func handle(_ command: ClientCommand) {
        switch command.cmd {
        case "swap": swapCamera()
        case "torch": streamer.setTorch(command.value ?? !status.torch)
        case "night": streamer.setNight(command.value ?? !status.night)
        case "rotate": rotate()
        default: break
        }
    }
}

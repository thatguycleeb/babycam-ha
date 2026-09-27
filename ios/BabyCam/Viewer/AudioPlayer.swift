import AVFoundation

/// Plays the camera's 16 kHz PCM stream. Keeps playing with the phone locked
/// (thanks to the "audio" background mode), which also keeps the connection alive.
final class AudioPlayer {
    var isMuted = false {
        didSet { node.volume = isMuted ? 0 : 1 }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: BabyCam.audioSampleRate,
                                       channels: 1,
                                       interleaved: false)!
    private let queuedBuffers = Locked(0)
    private let isRunning = Locked(false)
    private var interruptionObserver: NSObjectProtocol?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() {
        guard !isRunning.get() else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            try engine.start()
            node.play()
            isRunning.set(true)
        } catch {
            print("Audio playback failed to start: \(error)")
        }

        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self.engine.start()
                self.node.play()
            }
        }
    }

    func stop() {
        isRunning.set(false)
        node.stop()
        engine.stop()
        queuedBuffers.set(0)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Safe to call from any queue. `pcm` must be a fresh (aligned) Data of Int16 samples.
    func enqueue(_ pcm: Data) {
        guard isRunning.get() else { return }
        // If Wi-Fi hiccups and audio piles up (> ~0.7 s), drop chunks to stay close to live.
        guard queuedBuffers.get() < 8 else { return }

        let count = pcm.count / 2
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                channel[i] = Float(Int16(littleEndian: samples[i])) / 32768
            }
        }

        queuedBuffers.withLock { $0 += 1 }
        node.scheduleBuffer(buffer) { [weak self] in
            self?.queuedBuffers.withLock { $0 = max(0, $0 - 1) }
        }
    }
}

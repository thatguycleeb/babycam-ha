import AVFoundation

/// Records the microphone and converts it to 16 kHz mono Int16 PCM chunks (~85 ms each).
final class AudioCapture {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: BabyCam.audioSampleRate,
                                          channels: 1,
                                          interleaved: true)!
    private var converter: AVAudioConverter?
    private var interruptionObserver: NSObjectProtocol?

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            converter = AVAudioConverter(from: inFormat, to: outFormat)

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
                self?.process(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            print("Audio capture failed to start: \(error)")
        }

        // Restart after a phone call or Siri interrupts us.
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                try? self.engine.start()
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }

        let samples = UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
        onLevel?(AudioLevel.dbfs(samples))
        onPCM?(Data(buffer: samples))
    }
}

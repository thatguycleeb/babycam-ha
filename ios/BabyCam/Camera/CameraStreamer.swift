import AVFoundation
import CoreImage
import ImageIO
import QuartzCore

/// Captures video and turns frames into JPEGs for the stream.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// Called on the video queue with each encoded frame.
    var onJPEG: ((Data) -> Void)?
    /// Called on the session queue whenever camera/torch/night/rotation changes.
    var onStatusChange: ((CameraStatus) -> Void)?

    /// Frames are only encoded while someone is watching, to save battery and heat.
    let isStreaming = Locked(false)

    /// Frames per second sent to viewers. 10–15 is plenty for a baby monitor.
    private let framesPerSecond: Double = 15
    /// JPEG quality, 0...1. Lower = less Wi-Fi bandwidth.
    private let jpegQuality: CGFloat = 0.5

    private let nightMode = Locked(false)
    private let sessionQueue = DispatchQueue(label: "babycam.camera.session")
    private let videoQueue = DispatchQueue(label: "babycam.camera.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var lastFrameTime: CFTimeInterval = 0

    // Only touched on sessionQueue.
    private var input: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .back
    private var torchOn = false
    private var rotation = 90   // degrees; 90 = upright when the phone stands in portrait

    func start() {
        sessionQueue.async {
            self.configure()
            self.session.startRunning()
            self.publish()
        }
    }

    func stop() {
        sessionQueue.async {
            self.applyTorch(false)
            self.session.stopRunning()
        }
    }

    func swapCamera() {
        sessionQueue.async {
            self.applyTorch(false)
            self.attachInput(for: self.position == .back ? .front : .back)
            self.publish()
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            self.applyTorch(on)
            self.publish()
        }
    }

    func setNight(_ on: Bool) {
        nightMode.set(on)
        sessionQueue.async {
            self.applyNightSettings()
            self.publish()
        }
    }

    func rotate() {
        sessionQueue.async {
            self.rotation = (self.rotation + 90) % 360
            self.applyConnectionSettings()
            self.publish()
        }
    }

    // MARK: - Session setup (sessionQueue)

    private func configure() {
        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .hd1280x720
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.outputs.isEmpty, session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
        attachInput(for: position)
    }

    private func attachInput(for newPosition: AVCaptureDevice.Position) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
            position = newPosition
        } else if let input {
            session.addInput(input)   // put the old camera back
        }
        applyConnectionSettings()
        session.commitConfiguration()
        applyNightSettings()
    }

    private func applyConnectionSettings() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        let angle = CGFloat(rotation)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (position == .front)
        }
    }

    /// iPhones have no infrared, so "night mode" lets the sensor expose longer,
    /// boosts brightness, and switches to black & white (which hides colour noise).
    private func applyNightSettings() {
        guard let device = input?.device else { return }
        let night = nightMode.get()
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = night
            }
            let bias: Float = night ? min(1.5, device.maxExposureTargetBias) : 0
            device.setExposureTargetBias(bias, completionHandler: nil)

            // Allow auto-exposure to drop to 10 fps for longer exposures.
            let canGoSlow = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 10 }
            if night && canGoSlow {
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 10)
            } else {
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
            }
        } catch {
            print("Night mode config failed: \(error)")
        }
    }

    private func applyTorch(_ on: Bool) {
        guard let device = input?.device, device.hasTorch else {
            torchOn = false
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: 0.1)   // dim — it's a nursery
            } else {
                device.torchMode = .off
            }
            torchOn = on
        } catch {
            print("Torch failed: \(error)")
        }
    }

    private func publish() {
        let status = CameraStatus(camera: position == .front ? "front" : "back",
                                  torch: torchOn,
                                  hasTorch: input?.device.hasTorch ?? false,
                                  night: nightMode.get(),
                                  rotation: rotation)
        onStatusChange?(status)
    }

    // MARK: - Frames (videoQueue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isStreaming.get() else { return }

        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 0.9 / framesPerSecond else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: pixelBuffer)

        if nightMode.get() {
            image = image
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.2])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0,
                                                                kCIInputContrastKey: 1.1])
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.04,
                                                                 "inputSharpness": 0.3])
        }

        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else { return }
        onJPEG?(jpeg)
    }
}

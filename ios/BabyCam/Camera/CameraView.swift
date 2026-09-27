import AVFoundation
import SwiftUI

struct CameraView: View {
    var onClose: () -> Void
    @StateObject private var model = CameraModel()

    var body: some View {
        ZStack {
            if model.isDark {
                darkScreen
            } else {
                liveScreen
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(model.isDark)
        .persistentSystemOverlays(model.isDark ? .hidden : .automatic)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Low power (black) screen

    private var darkScreen: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text(model.viewerCount == 1 ? "1 viewer · tap to wake" : "\(model.viewerCount) viewers · tap to wake")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.15))
                    .padding(.bottom, 24)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.setDark(false) }
    }

    // MARK: - Normal screen

    private var liveScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: model.streamer.session)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                infoCard
                Spacer()
                VStack(spacing: 12) {
                    LevelMeter(level: model.level)
                        .frame(height: 6)
                    controls
                }
                .padding(12)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
            }
            .padding()
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(model.viewerCount > 0 ? Color.red : Color.gray)
                    .frame(width: 10, height: 10)
                Text(model.viewerCount > 0 ? "Live · \(model.viewerCount) watching" : "Waiting for a viewer")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            if let problem = model.permissionProblem {
                Text(problem).font(.callout).foregroundStyle(.yellow)
            }
            LabeledContent("Pairing code") {
                Text(verbatim: model.pairingCode)
                    .font(.title3.monospacedDigit().bold())
            }
            if let address = model.address {
                LabeledContent("On a computer") {
                    Text(verbatim: "http://\(address):\(BabyCam.httpPort)")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                Text("Connect this phone to Wi-Fi to stream.")
                    .font(.callout)
                    .foregroundStyle(.yellow)
            }
            Text("Keep BabyCam open and the phone plugged in. Use Go dark to turn the screen off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ControlButton("Flip", systemImage: "arrow.triangle.2.circlepath.camera") { model.swapCamera() }
            if model.status.hasTorch {
                ControlButton("Light", systemImage: model.status.torch ? "flashlight.on.fill" : "flashlight.off.fill",
                              isOn: model.status.torch) { model.toggleTorch() }
            }
            ControlButton("Night", systemImage: "moon.stars.fill", isOn: model.status.night) { model.toggleNight() }
            ControlButton("Rotate", systemImage: "rotate.right") { model.rotate() }
            ControlButton("Go dark", systemImage: "moon.zzz.fill") { model.setDark(true) }
        }
    }
}

/// Live camera preview so you can aim the phone. Viewers get the separately-encoded stream.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

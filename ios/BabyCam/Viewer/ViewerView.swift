import Network
import SwiftUI

struct ViewerView: View {
    var onClose: () -> Void
    @StateObject private var model = ViewerModel()
    @State private var showAlertSettings = false
    @State private var showControls = true

    var body: some View {
        Group {
            switch model.phase {
            case .choosing, .connecting: picker
            case .live, .reconnecting: stream
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.startBrowsing() }
        .onDisappear {
            model.stopBrowsing()
            model.disconnect()
        }
    }

    // MARK: - Choose a camera

    private var picker: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6-digit code", text: $model.code)
                        .keyboardType(.numberPad)
                        .font(.title3.monospacedDigit())
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Shown on the camera phone.")
                }

                Section("Cameras on your Wi-Fi") {
                    if model.cameras.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.cameras, id: \.self) { endpoint in
                        Button {
                            model.connect(to: endpoint)
                        } label: {
                            Label(ViewerModel.displayName(endpoint), systemImage: "video.fill")
                        }
                    }
                }

                Section {
                    TextField("e.g. 192.168.1.20", text: $model.manualAddress)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Connect") { model.connectManually() }
                } header: {
                    Text("Or connect by address")
                } footer: {
                    Text("The address is shown on the camera phone.")
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Watch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            .overlay {
                if model.phase == .connecting {
                    ProgressView("Connecting…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    // MARK: - Live stream

    private var stream: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = model.frame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }

            if model.noiseAlert {
                Rectangle()
                    .strokeBorder(Color.red, lineWidth: 6)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if showControls {
                VStack {
                    HStack {
                        statusPill
                        Spacer()
                        Button { model.disconnect() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                    Spacer()
                    controlDock
                }
                .padding()
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { showControls.toggle() } }
        .sheet(isPresented: $showAlertSettings) {
            AlertSettingsView(model: model)
                .presentationDetents([.medium])
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.phase == .live ? Color.red : Color.yellow)
                .frame(width: 8, height: 8)
            Text(model.phase == .live ? "Live" : "Reconnecting…")
                .font(.footnote.weight(.semibold))
            if let status = model.status {
                Text(status.camera == "front" ? "· Front" : "· Back")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.55), in: Capsule())
    }

    private var controlDock: some View {
        VStack(spacing: 12) {
            LevelMeter(level: model.level, threshold: model.alertsEnabled ? model.alertThreshold : nil)
                .frame(height: 6)
            HStack(spacing: 8) {
                ControlButton(model.isMuted ? "Muted" : "Sound",
                              systemImage: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              isOn: model.isMuted) { model.isMuted.toggle() }
                ControlButton("Flip", systemImage: "arrow.triangle.2.circlepath.camera") { model.swapCamera() }
                if model.status?.hasTorch == true {
                    ControlButton("Light",
                                  systemImage: model.status?.torch == true ? "flashlight.on.fill" : "flashlight.off.fill",
                                  isOn: model.status?.torch == true) { model.toggleTorch() }
                }
                ControlButton("Night", systemImage: "moon.stars.fill",
                              isOn: model.status?.night == true) { model.toggleNight() }
                ControlButton("Rotate", systemImage: "rotate.right") { model.rotate() }
                ControlButton("Alerts", systemImage: model.alertsEnabled ? "bell.fill" : "bell.slash") {
                    showAlertSettings = true
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct AlertSettingsView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Noise alerts", isOn: $model.alertsEnabled)
                Section {
                    LevelMeter(level: model.level, threshold: model.alertThreshold)
                        .frame(height: 8)
                        .padding(.vertical, 6)
                    Slider(value: $model.alertThreshold, in: -70 ... -10) {
                        Text("Sensitivity")
                    } minimumValueLabel: {
                        Image(systemName: "ear")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3")
                    }
                } header: {
                    Text("Alert level")
                } footer: {
                    Text("You'll get a notification and a vibration when sound goes past the red line. Slide left to make it more sensitive. Current level: \(Int(model.level)) dB.")
                }
                .disabled(!model.alertsEnabled)
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

import SwiftUI
import UserNotifications

@main
struct BabyCamApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

struct HomeView: View {
    enum Mode: String, Identifiable {
        case camera, viewer
        var id: String { rawValue }
    }

    @State private var mode: Mode?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)
            Text("BabyCam")
                .font(.largeTitle.bold())
            Text("A private baby monitor.\nEverything stays on your Wi-Fi.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            ModeButton(title: "Use as Camera",
                       subtitle: "Put this phone in the nursery",
                       systemImage: "video.fill") { mode = .camera }
            ModeButton(title: "Use as Viewer",
                       subtitle: "Watch and listen from this phone",
                       systemImage: "eye.fill") { mode = .viewer }
            Spacer().frame(height: 12)
        }
        .padding()
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $mode) { mode in
            switch mode {
            case .camera: CameraView { self.mode = nil }
            case .viewer: ViewerView { self.mode = nil }
            }
        }
    }
}

private struct ModeButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

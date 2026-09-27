import Foundation
import SwiftUI
import UserNotifications

enum NetworkInfo {
    /// The phone's Wi-Fi IPv4 address, e.g. "192.168.1.23".
    static func wifiIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard let addr = iface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: iface.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Lets notifications show as banners even while the app is open.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Shared controls

struct ControlButton: View {
    let title: String
    let systemImage: String
    var isOn = false
    let action: () -> Void

    init(_ title: String, systemImage: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isOn ? Color.yellow.opacity(0.9) : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(isOn ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct LevelMeter: View {
    let level: Float
    var threshold: Float? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(isLoud ? Color.red : Color.green)
                    .frame(width: geo.size.width * AudioLevel.meter(level))
                if let threshold {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2)
                        .offset(x: geo.size.width * AudioLevel.meter(threshold) - 1)
                }
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }

    private var isLoud: Bool {
        guard let threshold else { return false }
        return level > threshold
    }
}

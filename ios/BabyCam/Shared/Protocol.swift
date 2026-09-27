import Foundation

/// Constants shared by the camera and viewer sides.
enum BabyCam {
    /// Plain HTTP: serves the browser viewer page.
    static let httpPort: UInt16 = 8080
    /// WebSocket: video, audio, status and commands.
    static let streamPort: UInt16 = 8081
    static let bonjourType = "_babycam._tcp"
    static let audioSampleRate: Double = 16_000

    /// The pairing code travels as the WebSocket subprotocol, so the camera can
    /// reject viewers that don't know it before any video is sent.
    static func subprotocol(for code: String) -> String { "code-\(code)" }
}

/// First byte of every binary WebSocket message.
enum PacketType: UInt8 {
    case video = 1   // one JPEG frame
    case audio = 2   // 16 kHz mono Int16 little-endian PCM
}

/// Camera -> viewers (text message). Sent on connect and whenever something changes.
struct CameraStatus: Codable, Equatable {
    var type = "status"
    var camera: String        // "back" | "front"
    var torch: Bool
    var hasTorch: Bool
    var night: Bool
    var rotation: Int
}

/// Viewer -> camera (text message).
struct ClientCommand: Codable {
    var cmd: String           // "swap" | "torch" | "night" | "rotate"
    var value: Bool?
}

enum AudioLevel {
    static let silence: Float = -90

    static func dbfs(_ samples: UnsafeBufferPointer<Int16>) -> Float {
        guard !samples.isEmpty else { return silence }
        var sum: Float = 0
        for s in samples {
            let v = Float(s) / 32768
            sum += v * v
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        return max(silence, 20 * log10(max(rms, 1e-9)))
    }

    /// Maps dBFS to 0...1 for meters (-70 dB -> 0, -10 dB -> 1).
    static func meter(_ db: Float) -> Double {
        Double(min(1, max(0, (db + 70) / 60)))
    }
}

/// Tiny lock-protected box for values touched from more than one queue.
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); value = newValue; lock.unlock()
    }

    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

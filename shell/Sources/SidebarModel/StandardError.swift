import Foundation

/// Writing to stderr without the risk of stopping ReArc. `FileHandle.write(_:)` raises an
/// Objective-C exception when the descriptor is closed (a launcher that went away, a closed
/// pipe), and nothing in Swift can catch it: a 968 process stopped that way at launch
/// (security AG-02, `ReArc-2026-11-18-171027.ips`). `write(contentsOf:)` throws instead,
/// and a log line that cannot be written is dropped.
public enum StandardError {
    public static func write(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }
}

import Foundation

/// Pure policy, shared by the phone runtime and the macOS regression executable.
enum DiffusionPolicy {
    static func validSize(_ width: Int, _ height: Int) -> Bool {
        (256...768).contains(width) && (256...768).contains(height) && width % 32 == 0 && height % 32 == 0
    }
}

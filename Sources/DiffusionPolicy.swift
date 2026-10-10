import Foundation

/// Pure policy, shared by the phone runtime and the macOS regression executable.
enum DiffusionPolicy {
    static func validSize(_ width: Int, _ height: Int) -> Bool { false }
}

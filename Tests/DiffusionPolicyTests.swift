import Foundation

@main struct DiffusionPolicyTests {
    static func main() throws {
        precondition(DiffusionPolicy.validSize(512, 512), "512-square first run must be supported")
        precondition(DiffusionPolicy.validSize(768, 512))
        precondition(!DiffusionPolicy.validSize(513, 512))
        precondition(!DiffusionPolicy.validSize(2048, 2048))
        precondition(!DiffusionPolicy.validSize(-32, 512))
        print("Diffusion size policy passed")
    }
}

import SwiftUI
import UIKit

// MARK: - Reference photos (@1 … @4)

struct RefImage: Identifiable {
    let id = UUID()
    let image: UIImage
    let data: Data
}

// MARK: - Haptics (cheap juice)

enum Haptics {
    static var enabled = true
    static func tap() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { guard enabled else { return }; UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { guard enabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func select() { guard enabled else { return }; UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - Queue + saved prompts

struct QueuedPrompt: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var text: String
}

struct SavedPrompt: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var text: String
    var when: Date = Date()

    var title: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(44))
    }
}

// MARK: - Bounce

/// Squishes while held, springs back on release.
struct SquishyButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.93
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// Small pop used when a new result lands.
struct PopIn: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.88)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.68)) { shown = true }
            }
    }
}

/// Sweeping highlight across a fresh image.
struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1.2
    func body(content: Content) -> some View {
        content.overlay {
            if active {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.30), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: phase * geo.size.width * 2)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(false)
            }
        }
        .onChange(of: active) { _, now in
            guard now else { return }
            phase = -1.2
            withAnimation(.easeOut(duration: 1.0)) { phase = 1.4 }
        }
    }
}

extension View {
    func squishy(_ scale: CGFloat = 0.93) -> some View { buttonStyle(SquishyButtonStyle(scale: scale)) }
    func popIn() -> some View { modifier(PopIn()) }
    func shimmer(active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

// MARK: - Reference slots (the @1 … @4 tiles)

struct RefSlotView: View {
    let index: Int
    let ref: RefImage
    var onTag: () -> Void
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: ref.image)
                .resizable()
                .scaledToFill()
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.22), lineWidth: 1))

            Button {
                onTag()
            } label: {
                Text("@\(index + 1)")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            }
            .squishy(0.86)
            .padding(3)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .squishy(0.85)
            .padding(3)
        }
        .popIn()
    }
}

extension UIImage {
    /// Keeps uploads light: longest side at most `maxSide`.
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - Recipe history (one-tap remix)

struct Recipe: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var prompt: String
    var negative: String
    var modelID: String
    var width: Int
    var height: Int
    var steps: Int
    var seed: Int64
    var styles: [String]
    var mode: String
    var when: Date = Date()

    var title: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(48))
    }

    var detail: String {
        "\(modelID) · \(width)×\(height) · \(steps) steps" + (seed > 0 ? " · seed \(seed)" : "")
    }
}

// MARK: - Before / after drag for edits

struct CompareSlider: View {
    let before: UIImage
    let after: UIImage
    var height: CGFloat = 320
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Image(uiImage: after)
                    .resizable().scaledToFill()
                    .frame(width: w, height: height).clipped()
                Image(uiImage: before)
                    .resizable().scaledToFill()
                    .frame(width: w, height: height).clipped()
                    .mask(
                        Rectangle()
                            .frame(width: max(0, w * split), alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    )
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: height)
                    .offset(x: w * split)
                Circle()
                    .fill(.white)
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption2.weight(.bold)).foregroundStyle(.black.opacity(0.6)))
                    .shadow(radius: 5)
                    .offset(x: w * split - 13, y: height / 2 - 13)
            }
            .frame(width: w, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        split = min(max(0.02, value.location.x / max(1, w)), 0.98)
                    }
            )
        }
        .frame(height: height)
    }
}

// MARK: - Style chips (prompt seasoning, no model needed)

struct StyleChip: Identifiable, Hashable {
    let id: String
    let label: String
    let suffix: String

    static let all: [StyleChip] = [
        StyleChip(id: "photo", label: "Photoreal",
                  suffix: "photorealistic, 50mm lens, natural light, fine detail"),
        StyleChip(id: "anime", label: "Anime",
                  suffix: "anime style, clean line art, vibrant cel shading"),
        StyleChip(id: "cine", label: "Cinematic",
                  suffix: "cinematic lighting, shallow depth of field, film grain"),
        StyleChip(id: "neon", label: "Neon",
                  suffix: "neon cyberpunk lighting, wet reflections, glowing highlights"),
        StyleChip(id: "clay", label: "Clay",
                  suffix: "claymation, soft studio light, matte texture"),
        StyleChip(id: "render3d", label: "3D",
                  suffix: "3D render, subsurface scattering, soft studio lighting"),
        StyleChip(id: "oil", label: "Oil paint",
                  suffix: "oil painting, visible brush strokes, canvas texture"),
        StyleChip(id: "retro", label: "Retro film",
                  suffix: "1980s film photograph, faded colors, soft grain"),
    ]
}

// MARK: - Prompt improviser (no model needed: hand-written grammar)

enum Improviser {
    static let subjects = ["a lighthouse keeper reading by lantern light",
                           "a snow leopard on a mossy rock at dawn",
                           "a tiny robot watering a houseplant",
                           "a 1970s diner on an empty highway at night",
                           "an astronaut floating in a coral reef",
                           "a fox curled up in a pile of autumn leaves",
                           "a street food cart in the rain, steam rising",
                           "an old library with a spiral staircase"]
    static let seasonings = ["warm rim light, 35mm, shallow depth of field",
                             "dramatic side lighting, deep shadows, rich color",
                             "soft overcast light, muted palette, wide shot",
                             "golden hour glow, lens flare, high detail"]

    static func roll() -> String {
        let subject = subjects.randomElement() ?? "a quiet street at night"
        return "\(subject), \(seasonings.randomElement() ?? "")"
    }

    /// Cheap, model-free expansion: adds light, lens, mood and detail words the engines like.
    static func enhance(_ prompt: String) -> String {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return roll() }
        let extras = ["sharp focus", "high detail", "natural lighting",
                      "well composed", "rich colors"]
        let already = base.lowercased()
        let add = extras.filter { !already.contains($0.split(separator: " ").last.map(String.init) ?? $0) }
        return ([base] + add.prefix(3)).joined(separator: ", ")
    }
}

import Foundation

/// Starting points only: no network call, hidden style, or model switch.
struct PromptPreset: Identifiable {
    let title: String
    let icon: String
    let prompt: String
    var id: String { title }

    static let all: [PromptPreset] = [
        PromptPreset(title: "Cinema", icon: "film", prompt: "A lone traveler beside a rain-soaked neon diner at midnight, reflections across the asphalt, warm light spilling through the windows, cinematic wide shot, subtle film grain."),
        PromptPreset(title: "Portrait", icon: "person.crop.square", prompt: "An editorial portrait of a person in a cream linen jacket, soft window light, natural skin texture, muted olive backdrop, shallow depth of field, intimate photographic composition."),
        PromptPreset(title: "Product", icon: "cube", prompt: "A sculptural cobalt-blue perfume bottle on pale travertine, crisp studio lighting, delicate shadows, minimalist luxury product photography, generous negative space."),
        PromptPreset(title: "World", icon: "mountain.2", prompt: "A tiny observatory above a sea of clouds at sunrise, copper dome and moss-covered stone, distant mountain silhouettes, intricate atmospheric illustration, soft golden light."),
        PromptPreset(title: "Poster", icon: "textformat", prompt: "A bold graphic travel poster with the exact title 'NIGHT TRAIN', a silver train winding through indigo mountains, geometric shapes, warm orange moon, clean readable typography.")
    ]
}

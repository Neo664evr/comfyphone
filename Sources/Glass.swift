import SwiftUI
import UIKit

// MARK: - Liquid Glass helpers (iOS 26) with graceful fallbacks

extension View {
    /// Card surface. Real Liquid Glass on iOS 26, ultra-thin material below that.
    @ViewBuilder
    func glassCard(corner: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: corner))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner))
        }
    }

    /// Selectable chip (model picker, size presets).
    @ViewBuilder
    func glassChip(selected: Bool, corner: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            if selected {
                self.glassEffect(.regular.tint(Color.accentColor.opacity(0.6)).interactive(),
                                 in: .rect(cornerRadius: corner))
            } else {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: corner))
            }
        } else {
            self.background(selected ? Color.accentColor : Color(white: 0.16),
                            in: RoundedRectangle(cornerRadius: corner))
        }
    }

    /// Interactive glass button, falling back to the bordered style.
    func glassButton() -> some View { modifier(GlassButtonModifier()) }

    /// Tray behind a stack of controls, so neighbours melt into each other.
    @ViewBuilder
    func glassTray(corner: CGFloat = 18, spacing: CGFloat = 8) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self.glassEffect(.regular, in: .rect(cornerRadius: corner))
            }
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner))
        }
    }
}

struct GlassButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Page background: a dark base with a soft teal bloom so the glass has something to refract.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.08)
            RadialGradient(colors: [Color.accentColor.opacity(0.22), .clear],
                           center: .topLeading, startRadius: 8, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.10, green: 0.28, blue: 0.42).opacity(0.35), .clear],
                           center: .bottomTrailing, startRadius: 8, endRadius: 560)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Keyboard

extension UIApplication {
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// The "Done" row that sits above the keyboard, plus a tap-to-dismiss helper.
struct KeyboardDoneToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button {
                UIApplication.shared.dismissKeyboard()
            } label: {
                Label("Done", systemImage: "keyboard.chevron.compact.down")
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

import SwiftUI
import UIKit

@main
struct ComfyPhoneApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            CreateView()
                .tabItem { Label("Create", systemImage: "wand.and.stars") }
                .tag(0)
            GalleryView()
                .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
            LocalChatView()
                .tabItem { Label("Local", systemImage: "circle.hexagongrid.fill") }
                .tag(3)
        }
        .task { await app.refresh() }
        .onChange(of: app.showCreate) { _, jump in
            if jump {
                tab = 0
                app.showCreate = false
            }
        }
        .tabBarMinimizeBehaviorCompat()
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                Text(toast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassToast()
                    .padding(.bottom, 60)
                    .transition(.opacity)
                    .onTapGesture { app.toast = nil }
            }
        }
    }
}

extension View {
    /// Tab bar shrinks on scroll on iOS 26; no-op earlier.
    @ViewBuilder
    func tabBarMinimizeBehaviorCompat() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    @ViewBuilder
    func glassToast(corner: CGFloat = 24) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - Shared bits

struct StatusBanner: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(app.reachable ? (app.health?.comfy == "up" ? .green : .orange) : .red)
                .frame(width: 9, height: 9)
            Text(app.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassCard(corner: 13)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                app.toast = "Checking the PC…"
                await app.refresh()
                app.toast = app.reachable ? "PC reachable" : nil
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

func humanSize(_ bytes: Int) -> String {
    let mb = Double(bytes) / 1_048_576
    return mb >= 1 ? String(format: "%.1f MB", mb) : "\(bytes / 1024) KB"
}

func elapsedText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

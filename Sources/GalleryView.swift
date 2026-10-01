import SwiftUI

struct GalleryView: View {
    @EnvironmentObject private var app: AppState
    @State private var selected: GalleryItem?
    @State private var preview: UIImage?
    @State private var shareItems: [Any] = []
    @State private var sharing = false
    @State private var starredOnly = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    private var items: [GalleryItem] {
        starredOnly ? app.gallery.filter { app.isStarred($0) } : app.gallery
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: starredOnly ? "star" : "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(starredOnly ? "Nothing starred yet. Tap the star on an image you like."
                                         : "Nothing yet. Images you make on the PC land here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(items) { item in
                            GalleryCell(item: item)
                                .onTapGesture {
                                    selected = item
                                    preview = nil
                                    Task { preview = await app.thumbnail(for: item) }
                                }
                        }
                    }
                    .padding(10)
                    .animation(.snappy, value: items.count)
                }
            }
            .navigationTitle("On the PC")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        starredOnly.toggle()
                        Haptics.select()
                    } label: {
                        Image(systemName: starredOnly ? "star.fill" : "star")
                    }
                }
            }
            .background(AppBackground())
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await app.loadGallery() }
            .task { await app.loadGallery() }
            .sheet(item: $selected) { item in
                VStack(spacing: 14) {
                    if let image = preview {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        ProgressView().frame(height: 240)
                    }
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button {
                            if let image = preview { app.useAsReference(image) }
                            selected = nil
                        } label: {
                            Label("Use as reference", systemImage: "photo.badge.plus")
                        }
                        .glassButton()
                        .squishy()
                        Button {
                            if let image = preview { app.save(image) }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        .glassButton()
                        .squishy()
                        Button {
                            app.toggleStar(item)
                        } label: {
                            Label(app.isStarred(item) ? "Starred" : "Star",
                                  systemImage: app.isStarred(item) ? "star.fill" : "star")
                        }
                        .glassButton()
                        .squishy()
                        Button {
                            if let image = preview {
                                shareItems = [image]
                                sharing = true
                            }
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .glassButton()
                    }
                    .font(.footnote)
                }
                .padding(18)
                .presentationDetents([.medium, .large])
                .sheet(isPresented: $sharing) { ShareSheet(items: shareItems) }
            }
        }
    }
}

struct GalleryCell: View {
    @EnvironmentObject private var app: AppState
    let item: GalleryItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                app.toggleStar(item)
            } label: {
                Image(systemName: app.isStarred(item) ? "star.fill" : "star")
                    .font(.caption)
                    .padding(5)
                    .foregroundStyle(app.isStarred(item) ? .yellow : .white.opacity(0.85))
                    .background(.black.opacity(0.35), in: Circle())
            }
            .squishy(0.85)
            .padding(5)
        }
        .frame(height: 132)
        .clipped()
        .task {
            if image == nil { image = await app.thumbnail(for: item) }
        }
    }
}

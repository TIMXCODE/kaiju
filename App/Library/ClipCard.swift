import SwiftUI
import KaijuKit

struct ClipThumbnail: View {
    @EnvironmentObject private var library: ClipLibrary
    @Environment(\.theme) private var theme
    var clip: Clip

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.kaijuSeparator.opacity(0.25))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: clip.id) {
            image = library.cachedThumbnail(for: clip)
            if image == nil { image = await library.thumbnail(for: clip) }
        }
    }
}

struct ClipCard: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: ClipLibrary
    @Environment(\.theme) private var theme

    var clip: Clip
    var isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ClipThumbnail(clip: clip)
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: theme.cardRadius,
                                                      bottomLeadingRadius: 0,
                                                      bottomTrailingRadius: 0,
                                                      topTrailingRadius: theme.cardRadius,
                                                      style: .continuous))

                HStack(spacing: 5) {
                    if clip.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                }
                .padding(7)

                VStack {
                    Spacer()
                    HStack {
                        Label(clip.kind.displayName, systemImage: clip.kind.symbolName)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.5)))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(clip.durationLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.5)))
                            .foregroundStyle(.white)
                    }
                    .padding(7)
                }

                if isHovering {
                    hoverActions
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(clip.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let game = clip.gameName {
                        Text(game).lineLimit(1)
                        Text("·")
                    }
                    Text(clip.relativeDateLabel)
                    Text("·")
                    Text(clip.sizeLabel)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background {
            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .fill(Color.kaijuSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? theme.accent : Color.kaijuSeparator.opacity(0.55),
                              lineWidth: isSelected ? 1.6 : 0.5)
        }
        .scaleEffect(isHovering ? 1.008 : 1)
        .animation(theme.animation(.easeOut(duration: 0.16)), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu { ClipContextMenu(clip: clip) }
    }

    private var hoverActions: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Spacer()
                circleButton("heart\(clip.isFavorite ? ".fill" : "")") {
                    library.toggleFavorite(clip)
                }
                circleButton("scissors") { app.edit(clip) }
                circleButton("folder") { library.reveal(clip) }
                Spacer()
            }
            Spacer()
        }
        .background(.black.opacity(0.22))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: theme.cardRadius,
                                          bottomLeadingRadius: 0,
                                          bottomTrailingRadius: 0,
                                          topTrailingRadius: theme.cardRadius,
                                          style: .continuous))
        .transition(.opacity)
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
    }
}

struct ClipContextMenu: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var share: ShareManager
    var clip: Clip

    var body: some View {
        Button(clip.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
            library.toggleFavorite(clip)
        }
        Button("Edit…") { app.edit(clip) }
        Button("Reveal in Finder") { library.reveal(clip) }
        Button("Copy File") { share.copyToPasteboard([clip.url(in: library.directory)]) }
        Divider()
        Button("Delete", role: .destructive) {
            library.delete([clip])
            app.selectedClipIDs.remove(clip.id)
        }
    }
}

import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// Images fetched from Instagram's CDN, kept in memory while the app runs so
/// scrolling back doesn't fetch them again. Nothing goes to disk.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    init() { cache.totalCostLimit = 200 * 1024 * 1024 }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let task = inFlight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,  // data: URLs aren't HTTP
                  let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return await task.value
    }

    /// Where files opened in another app go. It is emptied the first time
    /// it is used in each run, so DM media doesn't pile up in temp.
    static func openedDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dmbar-opened")
        if !clearedOpened {
            clearedOpened = true
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var clearedOpened = false

    /// The image's bytes as the CDN sent them, for saving or opening.
    func data(for url: URL) async throws -> (Data, String) {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Instagram answered \(http.statusCode); the link may have expired. Reopen the conversation for a fresh one."])
        }
        let ext = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? url.pathExtension
        return (data, ext.isEmpty ? "jpg" : ext)
    }
}

/// An image from a URL, filling its frame, with a quiet placeholder while
/// it loads or if it can't.
struct RemoteImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image, image.isAnimated {
                // SwiftUI's Image draws only the first frame of a GIF or
                // animated WebP; NSImageView plays it, fitted.
                AnimatedImage(image: image)
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.primary.opacity(0.06))
                if failed {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: url) {
            failed = false
            guard let url else { failed = true; return }
            image = ImageCache.shared.cached(url)
            if image == nil {
                image = await ImageCache.shared.image(for: url)
                failed = image == nil
            }
        }
    }
}

/// A message's media in the conversation: one picture at its own shape, or
/// several in a grid. Clicking one opens the viewer.
struct MediaGrid: View {
    var media: [Media]
    var open: (Int) -> Void

    private static let width: CGFloat = 220
    private let corner = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        if media.count == 1, let m = media.first {
            if m.isSticker {
                tile(m, at: 0).frame(width: 120, height: 120)
            } else {
                let aspect = m.aspect ?? 4 / 5
                let height = min(max(Self.width / aspect, 110), 290)
                tile(m, at: 0)
                    .frame(width: Self.width, height: height)
                    .clipShape(corner)
            }
        } else {
            let side = (Self.width - 4) / 2
            let shown = Array(media.prefix(4).enumerated())
            LazyVGrid(columns: [GridItem(.fixed(side), spacing: 4), GridItem(.fixed(side), spacing: 4)], spacing: 4) {
                ForEach(shown, id: \.offset) { i, m in
                    tile(m, at: i)
                        .frame(width: side, height: side)
                        .clipped()
                        .overlay {
                            if i == 3, media.count > 4 {
                                Rectangle().fill(.black.opacity(0.45))
                                Text("+\(media.count - 4)").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            }
                        }
                }
            }
            .frame(width: Self.width)
            .clipShape(corner)
        }
    }

    private func tile(_ m: Media, at i: Int) -> some View {
        Button { open(i) } label: {
            RemoteImage(url: m.thumbnail, contentMode: m.isSticker || m.kind == "gif" ? .fit : .fill)
                .overlay {
                    if m.plays {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.35))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(m.plays ? "Video" : m.isSticker ? "Sticker" : "Photo")
        .help("Open")
    }
}

/// The viewer: a message's photos over the whole popover, one at a time.
/// Arrow keys or the chevrons step through them, Escape closes.
struct MediaViewer: View {
    @Environment(AppModel.self) private var model
    var viewing: Viewing
    @FocusState private var focused: Bool

    private var current: Media { viewing.media[viewing.index] }

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.94)).ignoresSafeArea()
            Group {
                if current.plays, let url = current.full {
                    PlayerView(url: url)
                } else {
                    RemoteImage(url: current.full, contentMode: .fit)
                        .background(.clear)
                }
            }
            .id(viewing.index)
            .padding(.vertical, 52)
            .contextMenu { actions }
            .accessibilityLabel(current.plays ? "Video" : "Photo")
        }
        .overlay(alignment: .top) {
            HStack(spacing: 8) {
                GlassIconButton(symbol: "xmark", label: "Close") { model.viewing = nil }
                Spacer()
                if viewing.media.count > 1 {
                    Text("\(viewing.index + 1) of \(viewing.media.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                }
                Menu { actions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .glassEffect(.regular.interactive(), in: .circle)
                .fixedSize()
                .accessibilityLabel("More")
            }
            .padding(12)
        }
        .overlay {
            if viewing.media.count > 1 {
                HStack {
                    GlassIconButton(symbol: "chevron.left", label: "Previous") { step(-1) }
                        .opacity(viewing.index > 0 ? 1 : 0)
                    Spacer()
                    GlassIconButton(symbol: "chevron.right", label: "Next") { step(1) }
                        .opacity(viewing.index < viewing.media.count - 1 ? 1 : 0)
                }
                .padding(.horizontal, 10)
            }
        }
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            // Take the keys from the composer, whose text view holds them.
            NSApp.keyWindow?.makeFirstResponder(nil)
            focused = true
        }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
    }

    @ViewBuilder private var actions: some View {
        Button(current.plays ? "Open" : "Open in Preview", systemImage: "arrow.up.forward.app") { export(open: true) }
        Button("Save to Downloads", systemImage: "square.and.arrow.down") { export(open: false) }
        if !current.plays {
            Button("Copy", systemImage: "doc.on.doc") {
                guard let url = current.full, let image = ImageCache.shared.cached(url) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
    }

    private func step(_ by: Int) {
        let next = viewing.index + by
        guard viewing.media.indices.contains(next) else { return }
        model.viewing?.index = next
    }

    /// Fetches the full file and opens it, or saves it to Downloads and
    /// shows it in Finder.
    private func export(open: Bool) {
        guard let url = current.full else { return }
        Task {
            do {
                let (data, ext) = try await ImageCache.shared.data(for: url)
                let name = "Instagram \(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).\(ext)"
                let dir = open ? try ImageCache.openedDirectory()
                    : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                var file = dir.appending(path: name)
                var n = 2
                while FileManager.default.fileExists(atPath: file.path) {
                    file = dir.appending(path: "\(name.dropLast(ext.count + 1)) \(n).\(ext)")
                    n += 1
                }
                try data.write(to: file)
                if open { NSWorkspace.shared.open(file) } else { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            } catch {
                model.toast = "Couldn't get the file: \(error.localizedDescription)"
            }
        }
    }
}

/// A video that starts playing when shown and stops when closed.
private struct PlayerView: View {
    var url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: url) {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
    }
}

extension NSImage {
    /// Whether it has more than one frame: a GIF or animated WebP.
    var isAnimated: Bool {
        representations.contains { (($0 as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int ?? 1) > 1 }
    }
}

/// An animated image, playing, scaled to fit.
private struct AnimatedImage: NSViewRepresentable {
    var image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

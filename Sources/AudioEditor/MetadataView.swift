import AppKit
import EditorCore
import SwiftUI
import UniformTypeIdentifiers

/// Episode details written into the MP3's ID3 tags.
struct MetadataView: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PodcastMetadata()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Episode Info").font(.title2.bold())

            HStack(alignment: .top, spacing: 18) {
                CoverArtWell(path: $draft.artworkPath)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    row("Episode title") { TextField("", text: $draft.title) }
                    row("Subtitle") { TextField("", text: $draft.subtitle) }
                    row("Show") { TextField("", text: $draft.album) }
                    row("Episode no.") {
                        HStack {
                            TextField("", text: $draft.trackNumber).frame(width: 70)
                            Text("Date").foregroundStyle(.secondary)
                            TextField("", text: $draft.date)
                        }
                    }
                    row("Author") { TextField("", text: $draft.author) }
                    row("Owner") { TextField("", text: $draft.owner) }
                    row("Keywords") { TextField("", text: $draft.keywords) }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").foregroundStyle(.secondary)
                TextEditor(text: $draft.description)
                    .font(.body)
                    .frame(minHeight: 110)
                    .border(Color.secondary.opacity(0.3))
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                row("Genre") {
                    HStack {
                        TextField("", text: $draft.genre)
                        Toggle("Explicit", isOn: $draft.explicit).labelsHidden()
                        Text("Explicit")
                    }
                }
                row("Copyright") { TextField("", text: $draft.copyright) }
                row("Email") { TextField("", text: $draft.email) }
                row("Feed URL") { TextField("", text: $draft.link) }
            }
            .labelsHidden()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let d = draft
                    model.updateMetadata { $0 = d }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660)
        .onAppear { draft = model.project.metadata }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content()
        }
    }
}

/// Cover art preview: choose, replace, remove, or drop a JPEG or PNG onto it.
private struct CoverArtWell: View {
    @Binding var path: String
    @State private var isTargeted = false

    private static let side: CGFloat = 110

    private var image: NSImage? { path.isEmpty ? nil : NSImage(contentsOfFile: path) }

    /// Pixel size and file size, e.g. "900 × 900 PNG, 912 KB".
    private var details: String? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let image, let source = CGImageSourceCreateWithURL(url, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return image == nil ? nil : "Unknown size"
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let kind = (path as NSString).pathExtension.uppercased()
        return "\(w) × \(h) \(kind), " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: path.isEmpty ? "photo" : "exclamationmark.triangle").font(.title)
                        Text(path.isEmpty ? "Drop cover art here" : "Image not found").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isTargeted ? 2 : 1)
            }
            .frame(width: Self.side, height: Self.side)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: Self.isImage) else { return false }
                path = url.path
                return true
            } isTargeted: { isTargeted = $0 }

            HStack(spacing: 6) {
                Button(path.isEmpty ? "Choose…" : "Replace…") { choose() }
                if !path.isEmpty {
                    Button("Remove") { path = "" }
                }
            }
            .controlSize(.small)

            if let details {
                Text(details).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.side)
    }

    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .jpeg) || type.conforms(to: .png)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

import AppKit
import EditorCore
import SwiftUI

/// Episode details written into the MP3's ID3 tags.
struct MetadataView: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PodcastMetadata()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Episode Info").font(.title2.bold())
            Form {
                TextField("Episode title", text: $draft.title)
                TextField("Show (album)", text: $draft.album)
                TextField("Author", text: $draft.author)
                HStack {
                    TextField("Episode number", text: $draft.trackNumber)
                    TextField("Date", text: $draft.date)
                }
                TextField("Genre", text: $draft.genre)
                TextField("Copyright", text: $draft.copyright)
                TextField("Feed link", text: $draft.link)
                TextField("Email", text: $draft.email)
                TextField("Keywords", text: $draft.keywords)
                Toggle("Explicit", isOn: $draft.explicit)
                HStack {
                    TextField("Cover art", text: $draft.artworkPath)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.jpeg, .png]
                        if panel.runModal() == .OK, let url = panel.url { draft.artworkPath = url.path }
                    }
                }
                VStack(alignment: .leading) {
                    Text("Description")
                    TextEditor(text: $draft.description)
                        .font(.body)
                        .frame(minHeight: 140)
                        .border(Color.secondary.opacity(0.3))
                }
            }
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
        .frame(width: 560)
        .onAppear { draft = model.project.metadata }
    }
}

import AppKit
import EditorCore
import SwiftUI
import UniformTypeIdentifiers

/// MP3 export settings and progress.
struct ExportView: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.bitrate") private var bitrate = 128
    @AppStorage("export.mono") private var mono = false
    @AppStorage("export.normalize") private var normalize = true
    @AppStorage("export.target") private var target = -16.0
    @AppStorage("export.chapters") private var chapters = false

    @State private var progress: Double?
    @State private var result: String?
    @State private var cancel = CancelFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export MP3").font(.title2.bold())
            Form {
                Picker("Bitrate", selection: $bitrate) {
                    ForEach([64, 96, 128, 160, 192, 256], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Picker("Channels", selection: $mono) {
                    Text("Stereo").tag(false)
                    Text("Mono").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Normalize loudness", isOn: $normalize)
                if normalize {
                    Picker("Target", selection: $target) {
                        Text("-14 LUFS").tag(-14.0)
                        Text("-16 LUFS (Apple Podcasts, stereo)").tag(-16.0)
                        Text("-19 LUFS (mono)").tag(-19.0)
                        Text("-23 LUFS (broadcast)").tag(-23.0)
                    }
                    Text("Peaks are limited to -1 dBFS.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Write markers as chapters", isOn: $chapters)
                    .disabled(model.project.markers.isEmpty)
            }

            if !model.allSourcesReady {
                Label("Some audio is still loading or missing; those regions will be silent.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if model.project.metadata.title.isEmpty {
                Label("No episode title yet. Add it under Episode Info.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: progress) { Text(progress < 0.4 ? "Measuring loudness…" : "Encoding…") }
            }
            if let result {
                Text(result).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if progress != nil {
                    Button("Cancel") { cancel.set() }
                } else {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Export…") { start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func start() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3]
        let base = model.project.metadata.title.isEmpty
            ? (model.fileURL?.deletingPathExtension().lastPathComponent ?? "Episode")
            : model.project.metadata.title
        panel.nameFieldStringValue = base.replacingOccurrences(of: "/", with: "-") + ".mp3"
        if let dir = model.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var options = ExportOptions()
        options.bitrateKbps = bitrate
        options.mono = mono
        options.loudnessTarget = normalize ? target : nil
        options.includeChapters = chapters
        let project = model.project
        let sources = model.pcm
        let flag = CancelFlag()
        cancel = flag
        progress = 0
        result = nil

        Task.detached(priority: .userInitiated) {
            let outcome = Result {
                try MP3Exporter.export(project: project, sources: sources, options: options, to: url) { p in
                    Task { @MainActor in progress = p }
                    return !flag.isSet
                }
            }
            await MainActor.run {
                progress = nil
                switch outcome {
                case .success(let report):
                    var lines = ["Exported \(url.lastPathComponent) (\(Timecode.format(report.duration, showMillis: false)), \(ByteCountFormatter.string(fromByteCount: Int64(report.bytes), countStyle: .file)))."]
                    if let m = report.measuredLoudness {
                        lines.append(String(format: "Mix measured %.1f LUFS; applied %+.1f dB.", m, report.appliedGainDB))
                    }
                    result = lines.joined(separator: " ")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let error):
                    try? FileManager.default.removeItem(at: url)
                    result = error is CancellationError ? "Export cancelled." : "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

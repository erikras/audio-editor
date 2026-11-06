import EditorCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()
            Divider()
            if let notice = model.notice {
                NoticeBar(text: notice) { model.notice = nil }
                Divider()
            }
            if model.project.tracks.isEmpty {
                EmptyState()
            } else {
                ScrollView(.vertical) {
                    HStack(spacing: 0) {
                        TrackHeaders()
                            .frame(width: 190)
                        Divider()
                        TimelineView(snapshot: snapshot, callbacks: callbacks)
                            .frame(height: TimelineMetrics.rulerHeight + TimelineMetrics.trackHeight * CGFloat(model.project.tracks.count))
                    }
                }
            }
            Divider()
            Inspector()
                .frame(height: 150)
        }
        .frame(minWidth: 900, minHeight: 520)
        .navigationTitle(model.windowTitle)
        .sheet(isPresented: $model.showMetadata) { MetadataView().environmentObject(model) }
        .sheet(isPresented: $model.showExport) { ExportView().environmentObject(model) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var snapshot: TimelineSnapshot {
        var s = TimelineSnapshot()
        s.project = model.project
        s.peaks = model.peaks
        s.sourceDurations = model.pcm.mapValues(\.duration)
        s.unavailable = Set(model.failed.keys)
        s.pixelsPerSecond = model.pixelsPerSecond
        s.playhead = model.playhead
        s.isPlaying = model.isPlaying
        s.selectedRegionID = model.selectedRegionID
        return s
    }

    private var callbacks: TimelineCallbacks {
        TimelineCallbacks(
            select: { region, track in
                model.selectedRegionID = region
                if let track { model.selectedTrackID = track }
            },
            seek: { model.seek(to: $0) },
            beginGesture: { model.beginGesture() },
            updateGesture: { model.updateGesture($0) },
            endGesture: { model.endGesture() },
            nudge: { model.nudgeSelectedRegion(by: $0) },
            deleteSelection: { model.deleteSelectedRegion() },
            togglePlay: { model.togglePlay() },
            zoom: { model.zoom(by: $0) })
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    let ext = url.pathExtension.lowercased()
                    if ext == "nhsx" || ext == ProjectFile.fileExtension {
                        if model.confirmDiscardChanges() { model.open(url: url) }
                    } else {
                        model.importAudio(urls: [url])
                    }
                }
            }
        }
    }
}

struct TransportBar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.goToStart() } label: { Image(systemName: "backward.end.fill") }
                .help("Go to start")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Play / pause (Space when the timeline is focused)")
            Text(Timecode.format(model.playhead))
                .font(.system(.title3, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text("/ " + Timecode.format(model.project.duration, showMillis: false))
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))

            Spacer()

            if !model.loading.isEmpty {
                ProgressView().controlSize(.small)
                Text("Loading audio…").foregroundStyle(.secondary)
            }

            Image(systemName: "minus.magnifyingglass")
            Slider(value: Binding(get: { log(model.pixelsPerSecond) }, set: { model.pixelsPerSecond = exp($0) }),
                   in: log(0.5)...log(2000))
                .frame(width: 160)
            Image(systemName: "plus.magnifyingglass")

            Button("Episode Info") { model.showMetadata = true }
            Button("Export MP3") { model.showExport = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.project.tracks.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct NoticeBar: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "info.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15))
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Open a project or a Hindenburg session, or drop audio files here.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open…") { model.openWithPanel() }
                Button("Import Audio…") { model.importAudioWithPanel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrackHeaders: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.addTrack() } label: { Label("Add Track", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: TimelineMetrics.rulerHeight)
            ForEach(model.project.tracks) { track in
                TrackHeader(track: track)
                    .frame(height: TimelineMetrics.trackHeight)
                    .background(model.selectedTrackID == track.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedTrackID = track.id }
                Divider()
            }
            Spacer(minLength: 0)
        }
    }
}

struct TrackHeader: View {
    @EnvironmentObject var model: EditorModel
    var track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: Binding(get: { track.name }, set: { name in model.updateTrack(track.id) { $0.name = name } }))
                    .textFieldStyle(.plain)
                    .font(.headline)
                Toggle(isOn: Binding(get: { track.muted }, set: { m in model.updateTrack(track.id) { $0.muted = m } })) {
                    Text("M").font(.caption.bold())
                }
                .toggleStyle(.button)
                .help("Mute")
                Menu {
                    Button("Delete Track", role: .destructive) { model.deleteTrack(track.id) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
            }
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2").font(.caption)
                Slider(value: Binding(get: { track.volumeDB }, set: { v in
                    model.liveEdit { p in
                        if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].volumeDB = (v * 2).rounded() / 2 }
                    }
                }), in: -40...12, onEditingChanged: { editing in editing ? model.beginGesture() : model.endGesture() })
                Text(String(format: "%+.1f dB", track.volumeDB))
                    .font(.caption.monospacedDigit())
                    .frame(width: 54, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
    }
}

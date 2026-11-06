import AppKit
import AVFoundation
import EditorCore
import Foundation
import UniformTypeIdentifiers

/// App state for the one open project: the project itself, selection, undo history, decoded audio and playback.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var project = Project()
    @Published var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published var selectedRegionID: UUID?
    @Published var selectedTrackID: UUID?
    @Published var pixelsPerSecond: Double = 20
    @Published var playhead: Double = 0
    /// Bumped to ask the timeline to zoom so the whole episode fits its current width.
    @Published private(set) var fitRequest = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var pcm: [UUID: PCMData] = [:]
    @Published private(set) var peaks: [UUID: [Float]] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published private(set) var failed: [UUID: String] = [:]
    @Published var notice: String?
    @Published var showMetadata = false
    @Published var showExport = false

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var gestureSnapshot: Project?
    private(set) var player = PlaybackEngine(sampleRate: 44_100)
    private var timer: Timer?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var windowTitle: String {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return isDirty ? "\(name) — Edited" : name
    }

    var selectedRegion: Region? {
        guard let id = selectedRegionID, let loc = project.locate(region: id) else { return nil }
        return project.tracks[loc.track].regions[loc.region]
    }

    var allSourcesReady: Bool {
        project.tracks.flatMap(\.regions).allSatisfy { pcm[$0.sourceID] != nil }
    }

    // MARK: Editing

    /// Applies one undoable change.
    func edit(_ change: (inout Project) -> Void) {
        let before = project
        change(&project)
        guard project != before else { return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        didChange()
    }

    /// Drags call begin once, update many times, then end; the whole drag is one undo step.
    func beginGesture() { gestureSnapshot = project }

    func updateGesture(_ change: (inout Project) -> Void) {
        change(&project)
        didChange(markDirty: false)
    }

    func endGesture() {
        guard let snapshot = gestureSnapshot else { return }
        gestureSnapshot = nil
        if snapshot != project {
            undoStack.append(snapshot)
            redoStack.removeAll()
            didChange()
        }
    }

    /// For sliders: one undo step per drag when wrapped in begin/endGesture, otherwise a normal edit.
    func liveEdit(_ change: (inout Project) -> Void) {
        if gestureSnapshot != nil { updateGesture(change) } else { edit(change) }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        didChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        didChange()
    }

    private func didChange(markDirty: Bool = true) {
        if markDirty { isDirty = true }
        if let id = selectedRegionID, project.locate(region: id) == nil { selectedRegionID = nil }
        player.update(project: project, sources: pcm)
    }

    func updateRegion(_ id: UUID, _ change: (inout Region) -> Void) {
        edit { p in
            guard let loc = p.locate(region: id) else { return }
            change(&p.tracks[loc.track].regions[loc.region])
        }
    }

    func updateTrack(_ id: UUID, _ change: (inout Track) -> Void) {
        edit { p in
            guard let i = p.tracks.firstIndex(where: { $0.id == id }) else { return }
            change(&p.tracks[i])
        }
    }

    func deleteSelectedRegion() {
        guard let id = selectedRegionID else { return }
        edit { p in
            guard let loc = p.locate(region: id) else { return }
            p.tracks[loc.track].regions.remove(at: loc.region)
        }
        selectedRegionID = nil
    }

    func nudgeSelectedRegion(by seconds: Double) {
        guard let id = selectedRegionID else { return }
        updateRegion(id) { $0.start = max(0, $0.start + seconds) }
    }

    func alignSelectedRegionToPlayhead() {
        guard let id = selectedRegionID else { return }
        let t = playhead
        updateRegion(id) { $0.start = t }
    }

    /// Splits the selected region at the playhead into two regions with the same settings.
    func splitSelectedRegionAtPlayhead() {
        guard let id = selectedRegionID, let region = selectedRegion else { return }
        let cut = playhead - region.start
        guard cut > 0.01, cut < region.length - 0.01 else {
            notice = "Move the playhead inside the selected region to split it."
            return
        }
        edit { p in
            guard let loc = p.locate(region: id) else { return }
            var first = p.tracks[loc.track].regions[loc.region]
            var second = first
            second.id = UUID()
            first.length = cut
            first.fadeOut = 0
            second.start = first.start + cut
            second.offset += cut
            second.length -= cut
            second.fadeIn = 0
            first.gainRamps = region.gainRamps.filter { $0.start < cut }
            second.gainRamps = region.gainRamps.filter { $0.start + $0.length > cut }.map { ramp in
                var r = ramp
                r.start -= cut
                return r
            }
            // Carry the level in effect at the cut into the second half.
            second.gainDB = RegionEnvelope(region).levelDB(at: cut)
            second.gainRamps.removeAll { $0.start + $0.length <= 0 }
            p.tracks[loc.track].regions[loc.region] = first
            p.tracks[loc.track].regions.insert(second, at: loc.region + 1)
        }
    }

    func addTrack() {
        edit { $0.tracks.append(Track(name: "Track \($0.tracks.count + 1)")) }
        selectedTrackID = project.tracks.last?.id
    }

    func deleteTrack(_ id: UUID) {
        edit { $0.tracks.removeAll { $0.id == id } }
        if selectedTrackID == id { selectedTrackID = nil }
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        // Starting at (or past) the end replays from the top.
        if playhead >= project.duration - 0.05 { seek(to: 0) }
        player.update(project: project, sources: pcm)
        player.play(from: playhead)
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        player.pause()
        playhead = min(player.currentTime, max(project.duration, 0))
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(to seconds: Double) {
        playhead = max(0, seconds)
        player.seek(to: playhead)
    }

    func goToStart() { seek(to: 0) }

    private func tick() {
        playhead = min(player.currentTime, max(project.duration, 0))
        if !player.isPlaying { pause() }
    }

    // MARK: Files

    func newProject() {
        guard confirmDiscardChanges() else { return }
        load(Project(), url: nil)
    }

    func openWithPanel() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectFile.fileExtension), UTType(filenameExtension: "nhsx")].compactMap { $0 }
        panel.allowsOtherFileTypes = false
        panel.message = "Open a project or a Hindenburg session (.nhsx)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        do {
            if url.pathExtension.lowercased() == "nhsx" {
                let result = try SessionImporter.importSession(at: url)
                load(result.project, url: nil)
                // Suggest saving next to the session in our own format.
                pendingSaveName = url.deletingPathExtension().lastPathComponent
                pendingSaveDirectory = url.deletingLastPathComponent()
                isDirty = true
                var notes: [String] = []
                if !result.missingSources.isEmpty {
                    notes.append("Missing audio: " + result.missingSources.map(\.name).joined(separator: ", ") + ". Select a region and use Relink.")
                }
                if !result.ignoredPlugins.isEmpty {
                    notes.append("Effects not applied: " + result.ignoredPlugins.joined(separator: ", ") + ".")
                }
                notice = notes.isEmpty ? nil : notes.joined(separator: " ")
            } else {
                load(try ProjectFile.read(from: url), url: url)
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private var pendingSaveName: String?
    private var pendingSaveDirectory: URL?

    private func load(_ newProject: Project, url: URL?) {
        pause()
        player.shutdown()
        player = PlaybackEngine(sampleRate: newProject.sampleRate)
        project = newProject
        fileURL = url
        isDirty = false
        undoStack.removeAll()
        redoStack.removeAll()
        selectedRegionID = nil
        selectedTrackID = newProject.tracks.first?.id
        playhead = 0
        pcm = [:]
        peaks = [:]
        failed = [:]
        loading = []
        pendingSaveName = nil
        pendingSaveDirectory = nil
        notice = nil
        let duration = max(newProject.duration, 60)
        pixelsPerSecond = max(0.1, min(200, 800 / duration))
        zoomToFit()
        loadAudio()
    }

    /// Decodes every source that isn't loaded yet, in the background.
    func loadAudio() {
        let sampleRate = project.sampleRate
        for source in project.sources where pcm[source.id] == nil && !loading.contains(source.id) {
            guard FileManager.default.fileExists(atPath: source.path) else {
                failed[source.id] = "File not found"
                continue
            }
            loading.insert(source.id)
            failed[source.id] = nil
            let id = source.id
            let url = source.url
            Task.detached(priority: .userInitiated) {
                let result = Result { try AudioDecoder.load(url: url, sampleRate: sampleRate) }
                await MainActor.run {
                    self.loading.remove(id)
                    switch result {
                    case .success(let decoded):
                        self.pcm[id] = decoded.pcm
                        self.peaks[id] = decoded.peaks
                        if let i = self.project.sources.firstIndex(where: { $0.id == id }) {
                            // Record the real duration without making an undo step.
                            self.project.sources[i].duration = decoded.pcm.duration
                            self.project.sources[i].channels = decoded.pcm.channelCount
                        }
                        self.player.update(project: self.project, sources: self.pcm)
                    case .failure(let error):
                        self.failed[id] = error.localizedDescription
                    }
                }
            }
        }
    }

    func relink(sourceID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Find the audio file for this region"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit { p in
            guard let i = p.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            p.sources[i].path = url.path
            p.sources[i].name = url.lastPathComponent
        }
        pcm[sourceID] = nil
        peaks[sourceID] = nil
        loadAudio()
    }

    /// Adds audio files as new regions at the playhead, on the selected track (or a new one).
    func importAudioWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importAudio(urls: panel.urls)
    }

    func importAudio(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let at = playhead
        edit { p in
            var trackIndex: Int
            if let id = selectedTrackID, let i = p.tracks.firstIndex(where: { $0.id == id }) {
                trackIndex = i
            } else {
                p.tracks.append(Track(name: "Track \(p.tracks.count + 1)"))
                trackIndex = p.tracks.count - 1
            }
            var cursor = at
            for url in urls {
                let duration = Self.probeDuration(url) ?? 0
                let source = AudioSource(name: url.lastPathComponent, path: url.path, duration: duration, channels: 2)
                p.sources.append(source)
                p.tracks[trackIndex].regions.append(Region(sourceID: source.id, name: url.deletingPathExtension().lastPathComponent,
                                                           start: cursor, offset: 0, length: max(duration, 1)))
                cursor += duration
            }
            p.tracks[trackIndex].regions.sort { $0.start < $1.start }
        }
        loadAudio()
    }

    /// Reads a file's duration without decoding it.
    static func probeDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return write(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ProjectFile.fileExtension) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? pendingSaveName ?? "Untitled") + "." + ProjectFile.fileExtension
        if let dir = fileURL?.deletingLastPathComponent() ?? pendingSaveDirectory { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            try ProjectFile.write(project, to: url)
            fileURL = url
            isDirty = false
            pendingSaveName = nil
            return true
        } catch {
            notice = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    /// Returns true when it is OK to replace the current project.
    func confirmDiscardChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(fileURL?.lastPathComponent ?? "this project")?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func updateMetadata(_ change: (inout PodcastMetadata) -> Void) {
        edit { change(&$0.metadata) }
    }

    func zoomToFit() {
        guard project.duration > 0 else { return }
        fitRequest += 1
    }

    func zoom(by factor: Double) {
        pixelsPerSecond = max(0.1, min(2000, pixelsPerSecond * factor))
    }
}


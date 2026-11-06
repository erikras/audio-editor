import AppKit
import EditorCore
import SwiftUI

@main
struct AudioEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("Audio Editor", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.newProject() }
                    .keyboardShortcut("n")
                Button("Open…") { model.openWithPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("Import Audio…") { model.importAudioWithPanel() }
                    .keyboardShortcut("i")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export MP3…") { model.showExport = true }
                    .keyboardShortcut("e")
                    .disabled(model.project.tracks.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandMenu("Edit Region") {
                Button("Split at Playhead") { model.splitSelectedRegionAtPlayhead() }
                    .keyboardShortcut("b")
                Button("Move Start to Playhead") { model.alignSelectedRegionToPlayhead() }
                    .keyboardShortcut("l")
                Button("Delete Region") { model.deleteSelectedRegion() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                Divider()
                Button("Add Track") { model.addTrack() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandMenu("Episode") {
                Button("Episode Info…") { model.showMetadata = true }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
                Button("Play / Pause") { model.togglePlay() }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("Go to Start") { model.goToStart() }
                    .keyboardShortcut(.home, modifiers: [])
                Divider()
                Button("Zoom In") { model.zoom(by: 1.5) }
                    .keyboardShortcut("=")
                Button("Zoom Out") { model.zoom(by: 1 / 1.5) }
                    .keyboardShortcut("-")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare SwiftPM binary needs this to get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return MainActor.assumeIsolated { model.confirmDiscardChanges() } ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let model else { return }
        MainActor.assumeIsolated {
            if model.confirmDiscardChanges() { model.open(url: url) }
        }
    }
}

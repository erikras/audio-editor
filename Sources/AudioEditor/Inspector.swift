import EditorCore
import SwiftUI

/// Bottom panel: precise numbers for the selected region.
struct Inspector: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        if let region = model.selectedRegion {
            RegionInspector(region: region)
        } else {
            Text("Select a region to adjust its position, fades and gain. Drag regions to align them; hold ⌥ to turn off snapping. Arrow keys nudge by 10 ms (⇧ for 100 ms).")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        }
    }
}

struct RegionInspector: View {
    @EnvironmentObject var model: EditorModel
    var region: Region

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: Binding(get: { region.name }, set: { n in model.updateRegion(region.id) { $0.name = n } }))
                    .font(.headline)
                    .frame(width: 220)
                if let source = model.project.source(region.sourceID) {
                    Text(source.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(width: 220, alignment: .leading)
                    if let failure = model.failed[source.id] {
                        HStack {
                            Text(failure).font(.caption).foregroundStyle(.red)
                            Button("Relink…") { model.relink(sourceID: source.id) }
                        }
                    }
                }
                HStack {
                    Button("Start at Playhead") { model.alignSelectedRegionToPlayhead() }
                    Button("Split") { model.splitSelectedRegionAtPlayhead() }
                    Button("Delete", role: .destructive) { model.deleteSelectedRegion() }
                }
                .controlSize(.small)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("Start")
                    TimeField(value: region.start) { v in model.updateRegion(region.id) { $0.start = max(0, v) } }
                    label("Fade in")
                    TimeField(value: region.fadeIn) { v in model.updateRegion(region.id) { $0.fadeIn = max(0, min(v, $0.length)) } }
                }
                GridRow {
                    label("Length")
                    TimeField(value: region.length) { v in model.updateRegion(region.id) { $0.length = max(0.05, v) } }
                    label("Fade out")
                    TimeField(value: region.fadeOut) { v in model.updateRegion(region.id) { $0.fadeOut = max(0, min(v, $0.length)) } }
                }
                GridRow {
                    label("Source offset")
                    TimeField(value: region.offset) { v in model.updateRegion(region.id) { $0.offset = max(0, v) } }
                    label("End")
                    Text(Timecode.format(region.end)).font(.body.monospacedDigit())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    label("Gain")
                    Slider(value: Binding(get: { region.gainDB }, set: { v in
                        model.liveEdit { p in
                            guard let loc = p.locate(region: region.id) else { return }
                            var r = p.tracks[loc.track].regions[loc.region]
                            let delta = (v * 2).rounded() / 2 - r.gainDB
                            r.gainDB += delta
                            // Keep inner volume changes relative to the base level.
                            for i in r.gainRamps.indices { r.gainRamps[i].gainDB += delta }
                            p.tracks[loc.track].regions[loc.region] = r
                        }
                    }), in: -40...12, onEditingChanged: { editing in editing ? model.beginGesture() : model.endGesture() })
                    .frame(width: 160)
                    Text(String(format: "%+.1f dB", region.gainDB)).font(.body.monospacedDigit()).frame(width: 64)
                }
                if !region.gainRamps.isEmpty {
                    HStack {
                        Text("\(region.gainRamps.count) volume change\(region.gainRamps.count == 1 ? "" : "s") inside this region (yellow line)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Remove") { model.updateRegion(region.id) { $0.gainRamps.removeAll() } }
                            .controlSize(.small)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

/// Text field for a time value in "h:mm:ss.mmm"; commits on Return or when focus leaves.
struct TimeField: View {
    var value: Double
    var commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0:00.000", text: $text)
            .font(.body.monospacedDigit())
            .frame(width: 110)
            .focused($focused)
            .onAppear { text = Timecode.format(value) }
            .onChange(of: value) { _, v in if !focused { text = Timecode.format(v) } }
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
            .onSubmit(apply)
    }

    private func apply() {
        if let v = Timecode.parse(text) { commit(v) }
        text = Timecode.format(Timecode.parse(text) ?? value)
    }
}

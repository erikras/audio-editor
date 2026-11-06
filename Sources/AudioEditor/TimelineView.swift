import AppKit
import EditorCore
import SwiftUI

enum TimelineMetrics {
    static let rulerHeight: CGFloat = 26
    static let trackHeight: CGFloat = 96
    static let handleSize: CGFloat = 9
    static let edgeGrab: CGFloat = 6
    static let snapDistance: CGFloat = 8
}

/// Everything the timeline needs to draw, handed over from SwiftUI on each update.
struct TimelineSnapshot {
    var project = Project()
    var peaks: [UUID: [Float]] = [:]
    var sourceDurations: [UUID: Double] = [:]
    var unavailable: Set<UUID> = []
    var pixelsPerSecond: Double = 20
    var playhead: Double = 0
    var isPlaying = false
    var selectedRegionID: UUID?
    /// Changes whenever the model asks the timeline to zoom so the whole episode fits.
    var fitRequest = 0
}

struct TimelineCallbacks {
    var select: (_ region: UUID?, _ track: UUID?) -> Void
    var seek: (Double) -> Void
    var beginGesture: () -> Void
    var updateGesture: ((inout Project) -> Void) -> Void
    var endGesture: () -> Void
    var nudge: (Double) -> Void
    var deleteSelection: () -> Void
    var togglePlay: () -> Void
    var zoom: (Double) -> Void
    var setPixelsPerSecond: (Double) -> Void
    /// A one-step undoable change (add or delete a marker or volume point).
    var edit: ((inout Project) -> Void) -> Void
    var renameMarker: (UUID) -> Void
}

/// SwiftUI wrapper: a horizontally scrolling AppKit timeline.
struct TimelineView: NSViewRepresentable {
    var snapshot: TimelineSnapshot
    var callbacks: TimelineCallbacks

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let canvas = TimelineCanvas(frame: .zero)
        scroll.documentView = canvas
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? TimelineCanvas else { return }
        if canvas.appliedFitRequest != snapshot.fitRequest {
            canvas.appliedFitRequest = snapshot.fitRequest
            let available = scroll.contentSize.width
            let duration = max(snapshot.project.duration, 1)
            if available > 100 {
                let pps = Double(available - 20) / duration
                DispatchQueue.main.async {
                    canvas.skipRecenter = true
                    callbacks.setPixelsPerSecond(pps)
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            } else {
                canvas.appliedFitRequest = -1   // not laid out yet; retry on the next update
            }
        }
        let oldPPS = canvas.snapshot.pixelsPerSecond
        let visible = scroll.contentView.bounds
        let centerTime = oldPPS > 0 ? Double(visible.midX) / oldPPS : 0

        canvas.snapshot = snapshot
        canvas.callbacks = callbacks
        let height = TimelineMetrics.rulerHeight + TimelineMetrics.trackHeight * CGFloat(max(snapshot.project.tracks.count, 1))
        let contentSeconds = max(snapshot.project.duration + 60, 120)
        let width = max(CGFloat(contentSeconds * snapshot.pixelsPerSecond), scroll.contentSize.width)
        if canvas.frame.size != CGSize(width: width, height: height) {
            canvas.setFrameSize(CGSize(width: width, height: height))
        }

        // Keep the same moment centered when zooming.
        if canvas.skipRecenter {
            canvas.skipRecenter = false
        } else if oldPPS != snapshot.pixelsPerSecond, oldPPS > 0 {
            let x = CGFloat(centerTime * snapshot.pixelsPerSecond) - visible.width / 2
            scroll.contentView.scroll(to: NSPoint(x: max(0, min(x, width - visible.width)), y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // Follow the playhead while playing.
        if snapshot.isPlaying {
            let px = CGFloat(snapshot.playhead * snapshot.pixelsPerSecond)
            let bounds = scroll.contentView.bounds
            if px < bounds.minX || px > bounds.maxX - 40 {
                scroll.contentView.scroll(to: NSPoint(x: max(0, px - bounds.width * 0.1), y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        canvas.needsDisplay = true
    }
}

final class TimelineCanvas: NSView {
    var snapshot = TimelineSnapshot()
    var callbacks: TimelineCallbacks?
    var appliedFitRequest = 0
    var skipRecenter = false

    private enum Drag {
        case move(regionID: UUID, grabOffset: Double, originalTrack: Int)
        case trimStart(regionID: UUID, original: Region)
        case trimEnd(regionID: UUID, original: Region)
        case fadeIn(regionID: UUID)
        case fadeOut(regionID: UUID)
        case rampStart(regionID: UUID, rampID: UUID)
        case rampEnd(regionID: UUID, rampID: UUID)
        case volumeLine(original: Region, rect: NSRect, startDB: Double)
        case marker(id: UUID)
        case scrub
    }

    /// What a context-menu item acts on.
    private struct MenuContext {
        var time: Double
        var regionID: UUID?
        var rampID: UUID?
        var markerID: UUID?
    }
    private var menuContext: MenuContext?
    private var drag: Drag?
    private var snapGuide: Double?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var pps: Double { snapshot.pixelsPerSecond }
    private func x(_ t: Double) -> CGFloat { CGFloat(t * pps) }
    private func time(_ x: CGFloat) -> Double { Double(x) / pps }
    private func trackTop(_ i: Int) -> CGFloat { TimelineMetrics.rulerHeight + CGFloat(i) * TimelineMetrics.trackHeight }
    private func trackIndex(atY y: CGFloat) -> Int? {
        guard y >= TimelineMetrics.rulerHeight else { return nil }
        let i = Int((y - TimelineMetrics.rulerHeight) / TimelineMetrics.trackHeight)
        return i < snapshot.project.tracks.count ? i : nil
    }
    // MARK: Volume line geometry (absolute dB, +12 at the top to -40 at the bottom)

    private static let volumeTopDB = 12.0, volumeBottomDB = -40.0

    private func volumeY(_ db: Double, in rect: NSRect) -> CGFloat {
        let top = rect.minY + 14, bottom = rect.maxY - 4
        let c = max(Self.volumeBottomDB, min(Self.volumeTopDB, db))
        return top + (bottom - top) * CGFloat((Self.volumeTopDB - c) / (Self.volumeTopDB - Self.volumeBottomDB))
    }

    private func volumeDB(atY y: CGFloat, in rect: NSRect) -> Double {
        let top = rect.minY + 14, bottom = rect.maxY - 4
        let f = Double((y - top) / max(bottom - top, 1))
        let db = Self.volumeTopDB - f * (Self.volumeTopDB - Self.volumeBottomDB)
        return (max(Self.volumeBottomDB, min(Self.volumeTopDB, db)) * 2).rounded() / 2
    }

    /// Corner points of the volume line: each volume change has a start (old level) and an end (new level).
    private func volumePoints(_ region: Region, in rect: NSRect) -> [(point: NSPoint, rampID: UUID, isEnd: Bool)] {
        var out: [(NSPoint, UUID, Bool)] = []
        var level = region.gainDB
        for ramp in region.gainRamps.sorted(by: { $0.start < $1.start }) {
            out.append((NSPoint(x: rect.minX + x(ramp.start), y: volumeY(level, in: rect)), ramp.id, false))
            out.append((NSPoint(x: rect.minX + x(ramp.start + ramp.length), y: volumeY(ramp.gainDB, in: rect)), ramp.id, true))
            level = ramp.gainDB
        }
        return out.map { (point: $0.0, rampID: $0.1, isEnd: $0.2) }
    }

    private func volumeHandle(at point: NSPoint, region: Region, rect: NSRect) -> (rampID: UUID, isEnd: Bool)? {
        // Prefer ends, which are what you usually drag.
        let hits = volumePoints(region, in: rect).filter { abs($0.point.x - point.x) <= 6 && abs($0.point.y - point.y) <= 6 }
        guard let best = hits.min(by: { ($0.isEnd ? 0 : 1, abs($0.point.x - point.x)) < ($1.isEnd ? 0 : 1, abs($1.point.x - point.x)) }) else { return nil }
        return (best.rampID, best.isEnd)
    }

    private func isNearVolumeLine(_ point: NSPoint, region: Region, rect: NSRect) -> Bool {
        let rt = time(point.x) - region.start
        return abs(volumeY(RegionEnvelope(region).levelDB(at: rt), in: rect) - point.y) <= 4
    }

    private func markerHit(_ point: NSPoint) -> Marker? {
        guard point.y < TimelineMetrics.rulerHeight + 14 else { return nil }
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        return snapshot.project.markers.last { m in
            let mx = x(m.time)
            let labelWidth = (m.name as NSString).size(withAttributes: [.font: font]).width + 6
            return point.x >= mx - 5 && point.x <= mx + max(labelWidth, 5)
        }
    }

    private func addVolumeChange(regionID: UUID, at t: Double) -> UUID? {
        guard let region = locate(regionID)?.region else { return nil }
        let rt = max(0, min(t - region.start, region.length - 0.02))
        let ramp = GainRamp(start: rt, length: min(0.3, region.length - rt), gainDB: RegionEnvelope(region).levelDB(at: rt))
        callbacks?.updateGesture { p in
            guard let loc = p.locate(region: regionID) else { return }
            p.tracks[loc.track].regions[loc.region].gainRamps.append(ramp)
            p.tracks[loc.track].regions[loc.region].gainRamps.sort { $0.start < $1.start }
        }
        return ramp.id
    }

    private func regionRect(track: Int, region: Region) -> NSRect {
        NSRect(x: x(region.start), y: trackTop(track) + 3, width: max(x(region.end) - x(region.start), 1), height: TimelineMetrics.trackHeight - 6)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let p = snapshot.project

        for (i, _) in p.tracks.enumerated() {
            let row = NSRect(x: dirtyRect.minX, y: trackTop(i), width: dirtyRect.width, height: TimelineMetrics.trackHeight)
            (i % 2 == 0 ? NSColor.controlBackgroundColor : NSColor.underPageBackgroundColor.withAlphaComponent(0.35)).setFill()
            row.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: dirtyRect.minX, y: row.maxY - 1, width: dirtyRect.width, height: 1).fill()
        }

        for (t, track) in p.tracks.enumerated() {
            for region in track.regions {
                let rect = regionRect(track: t, region: region)
                guard rect.intersects(dirtyRect) else { continue }
                drawRegion(region, in: rect, clip: dirtyRect, muted: track.muted)
            }
        }

        drawRuler(dirtyRect)

        for marker in p.markers {
            let mx = x(marker.time)
            guard mx >= dirtyRect.minX - 100, mx <= dirtyRect.maxX else { continue }
            NSColor.systemOrange.setFill()
            NSRect(x: mx, y: 0, width: 1, height: bounds.height).fill()
            (marker.name as NSString).draw(at: NSPoint(x: mx + 3, y: TimelineMetrics.rulerHeight + 1), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.systemOrange,
            ])
        }

        if let guide = snapGuide {
            NSColor.systemYellow.setFill()
            NSRect(x: x(guide), y: TimelineMetrics.rulerHeight, width: 1, height: bounds.height).fill()
        }

        let px = x(snapshot.playhead)
        NSColor.systemRed.setFill()
        NSRect(x: px - 0.5, y: 0, width: 1.5, height: bounds.height).fill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: px - 6, y: 0))
        head.line(to: NSPoint(x: px + 6, y: 0))
        head.line(to: NSPoint(x: px, y: 8))
        head.close()
        head.fill()
    }

    private func drawRuler(_ dirty: NSRect) {
        let ruler = NSRect(x: dirty.minX, y: 0, width: dirty.width, height: TimelineMetrics.rulerHeight)
        NSColor.windowBackgroundColor.setFill()
        ruler.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: dirty.minX, y: TimelineMetrics.rulerHeight - 1, width: dirty.width, height: 1).fill()

        // Pick a label spacing of at least ~80 px.
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let step = steps.first { $0 * pps >= 80 } ?? 3600
        let minor = step / 5
        var t = floor(time(dirty.minX) / minor) * minor
        let end = time(dirty.maxX)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while t <= end {
            let tx = x(t)
            let isMajor = abs((t / step).rounded() * step - t) < minor / 2
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: tx, y: isMajor ? 12 : 19, width: 1, height: isMajor ? 14 : 7).fill()
            if isMajor {
                (Timecode.format(t, showMillis: step < 1) as NSString).draw(at: NSPoint(x: tx + 3, y: 1), withAttributes: attrs)
            }
            t += minor
        }
    }

    private func drawRegion(_ region: Region, in rect: NSRect, clip: NSRect, muted: Bool) {
        let selected = region.id == snapshot.selectedRegionID
        let unavailable = snapshot.unavailable.contains(region.sourceID)
        let base: NSColor = unavailable ? .systemRed : (muted ? .systemGray : .controlAccentColor)
        let body = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        base.withAlphaComponent(selected ? 0.32 : 0.18).setFill()
        body.fill()
        base.withAlphaComponent(selected ? 1 : 0.55).setStroke()
        body.lineWidth = selected ? 2 : 1
        body.stroke()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()

        let envelope = RegionEnvelope(region)
        let baseLinear = dbToLinear(region.gainDB)
        // Waveform: one vertical line per pixel, scaled by fades and volume changes relative to the base gain.
        if let peaks = snapshot.peaks[region.sourceID], !peaks.isEmpty {
            let framesPerPeak = Double(AudioDecoder.framesPerPeak)
            let sampleRate = snapshot.project.sampleRate
            let mid = rect.midY + 6
            let halfHeight = (rect.height - 18) / 2
            let x0 = max(rect.minX, clip.minX), x1 = min(rect.maxX, clip.maxX)
            let path = NSBezierPath()
            var px = floor(x0)
            while px < x1 {
                let rt0 = time(px) - region.start
                let rt1 = time(px + 1) - region.start
                let s0 = Int(((region.offset + rt0) * sampleRate / framesPerPeak).rounded(.down))
                let s1 = max(Int(((region.offset + rt1) * sampleRate / framesPerPeak).rounded(.up)), s0 + 1)
                var peak: Float = 0
                if s1 > 0, s0 < peaks.count {
                    for i in max(s0, 0)..<min(s1, peaks.count) { peak = max(peak, peaks[i]) }
                }
                let g = envelope.gain(at: rt0) / baseLinear
                let h = max(CGFloat(Double(peak) * g) * halfHeight, 0.5)
                path.move(to: NSPoint(x: px + 0.5, y: mid - h))
                path.line(to: NSPoint(x: px + 0.5, y: mid + h))
                px += 1
            }
            base.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // Fade curves.
        NSColor.labelColor.withAlphaComponent(0.6).setStroke()
        if region.fadeIn > 0 {
            let w = x(min(region.fadeIn, region.length))
            let curve = NSBezierPath()
            curve.move(to: NSPoint(x: rect.minX, y: rect.maxY))
            for i in 1...24 {
                let f = Double(i) / 24
                curve.line(to: NSPoint(x: rect.minX + w * CGFloat(f), y: rect.maxY - rect.height * CGFloat(RegionEnvelope.fadeCurve(f))))
            }
            curve.lineWidth = 1.2
            curve.stroke()
        }
        if region.fadeOut > 0 {
            let w = x(min(region.fadeOut, region.length))
            let curve = NSBezierPath()
            curve.move(to: NSPoint(x: rect.maxX - w, y: rect.minY))
            for i in 1...24 {
                let f = Double(i) / 24
                curve.line(to: NSPoint(x: rect.maxX - w + w * CGFloat(f), y: rect.maxY - rect.height * CGFloat(RegionEnvelope.fadeCurve(1 - f))))
            }
            curve.lineWidth = 1.2
            curve.stroke()
        }

        // Volume line: region gain plus volume changes. Editable when the region is selected.
        if !region.gainRamps.isEmpty || selected {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: volumeY(region.gainDB, in: rect)))
            for p in volumePoints(region, in: rect) { line.line(to: p.point) }
            line.line(to: NSPoint(x: rect.maxX, y: volumeY(RegionEnvelope(region).levelDB(at: region.length), in: rect)))
            NSColor.systemYellow.withAlphaComponent(selected ? 1 : 0.8).setStroke()
            line.lineWidth = selected ? 2 : 1.5
            line.stroke()
            if selected {
                for p in volumePoints(region, in: rect) {
                    let r = NSRect(x: p.point.x - 3.5, y: p.point.y - 3.5, width: 7, height: 7)
                    NSColor.systemYellow.setFill()
                    r.fill()
                    NSColor.black.withAlphaComponent(0.6).setStroke()
                    NSBezierPath(rect: r).stroke()
                }
            }
        }

        // Title.
        let title = unavailable ? "\(region.name) (audio missing)" : region.name
        (title as NSString).draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        NSGraphicsContext.restoreGraphicsState()

        // Fade handles on the top edge.
        if selected || rect.width > 40 {
            for hx in [rect.minX + x(region.fadeIn), rect.maxX - x(region.fadeOut)] {
                let handle = NSRect(x: hx - TimelineMetrics.handleSize / 2, y: rect.minY, width: TimelineMetrics.handleSize, height: TimelineMetrics.handleSize)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: handle).fill()
                base.setStroke()
                NSBezierPath(ovalIn: handle).stroke()
            }
        }
    }

    // MARK: Mouse

    private func hitRegion(at point: NSPoint) -> (track: Int, region: Region, rect: NSRect)? {
        guard let t = trackIndex(atY: point.y) else { return nil }
        // Topmost (last drawn) first.
        for region in snapshot.project.tracks[t].regions.reversed() {
            let rect = regionRect(track: t, region: region)
            if rect.insetBy(dx: -TimelineMetrics.edgeGrab / 2, dy: 0).contains(point) { return (t, region, rect) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let callbacks else { return }

        if let marker = markerHit(point) {
            if event.clickCount == 2 {
                callbacks.renameMarker(marker.id)
                drag = nil
            } else {
                callbacks.beginGesture()
                drag = .marker(id: marker.id)
            }
            return
        }

        if point.y < TimelineMetrics.rulerHeight {
            drag = .scrub
            callbacks.seek(max(0, time(point.x)))
            return
        }

        guard let hit = hitRegion(at: point) else {
            let track = trackIndex(atY: point.y).map { snapshot.project.tracks[$0].id }
            callbacks.select(nil, track)
            callbacks.seek(max(0, time(point.x)))
            drag = nil
            return
        }

        let region = hit.region, rect = hit.rect
        callbacks.select(region.id, snapshot.project.tracks[hit.track].id)
        if event.clickCount == 2 {
            callbacks.seek(time(point.x))
            return
        }
        let wasSelected = region.id == snapshot.selectedRegionID
        callbacks.beginGesture()

        // ⌘-click adds a volume change and lets you drag it straight away.
        if event.modifierFlags.contains(.command) {
            if let rampID = addVolumeChange(regionID: region.id, at: time(point.x)) {
                drag = .rampEnd(regionID: region.id, rampID: rampID)
            }
            return
        }
        if wasSelected, let handle = volumeHandle(at: point, region: region, rect: rect) {
            drag = handle.isEnd ? .rampEnd(regionID: region.id, rampID: handle.rampID) : .rampStart(regionID: region.id, rampID: handle.rampID)
            return
        }

        let fadeInX = rect.minX + x(region.fadeIn)
        let fadeOutX = rect.maxX - x(region.fadeOut)
        let nearTop = point.y <= rect.minY + TimelineMetrics.handleSize + 3
        if nearTop && abs(point.x - fadeInX) <= TimelineMetrics.handleSize {
            drag = .fadeIn(regionID: region.id)
        } else if nearTop && abs(point.x - fadeOutX) <= TimelineMetrics.handleSize {
            drag = .fadeOut(regionID: region.id)
        } else if wasSelected && !nearTop && isNearVolumeLine(point, region: region, rect: rect) {
            drag = .volumeLine(original: region, rect: rect, startDB: volumeDB(atY: point.y, in: rect))
        } else if abs(point.x - rect.minX) <= TimelineMetrics.edgeGrab {
            drag = .trimStart(regionID: region.id, original: region)
        } else if abs(point.x - rect.maxX) <= TimelineMetrics.edgeGrab {
            drag = .trimEnd(regionID: region.id, original: region)
        } else {
            drag = .move(regionID: region.id, grabOffset: time(point.x) - region.start, originalTrack: hit.track)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let callbacks else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let t = time(point.x)
        let snapping = !event.modifierFlags.contains(.option)

        switch drag {
        case .scrub:
            callbacks.seek(max(0, t))
        case .marker(let id):
            var mt = max(0, t)
            snapGuide = nil
            if snapping {
                let tolerance = Double(TimelineMetrics.snapDistance) / pps
                var targets = [snapshot.playhead]
                for track in snapshot.project.tracks { for r in track.regions { targets += [r.start, r.end] } }
                if let best = targets.min(by: { abs($0 - mt) < abs($1 - mt) }), abs(best - mt) <= tolerance { mt = best; snapGuide = best }
            }
            callbacks.updateGesture { p in
                guard let i = p.markers.firstIndex(where: { $0.id == id }) else { return }
                p.markers[i].time = mt
                p.markers.sort { $0.time < $1.time }
            }
        case .rampEnd(let regionID, let rampID):
            guard let (trackIndex, region) = locate(regionID) else { return }
            let rect = regionRect(track: trackIndex, region: region)
            let db = volumeDB(atY: point.y, in: rect)
            let rt = max(0, min(t - region.start, region.length))
            callbacks.updateGesture { p in
                guard let loc = p.locate(region: regionID),
                      let k = p.tracks[loc.track].regions[loc.region].gainRamps.firstIndex(where: { $0.id == rampID }) else { return }
                var ramp = p.tracks[loc.track].regions[loc.region].gainRamps[k]
                ramp.length = max(0.01, rt - ramp.start)
                ramp.gainDB = db
                p.tracks[loc.track].regions[loc.region].gainRamps[k] = ramp
            }
        case .rampStart(let regionID, let rampID):
            guard let region = locate(regionID)?.region else { return }
            let rt = max(0, min(t - region.start, region.length))
            callbacks.updateGesture { p in
                guard let loc = p.locate(region: regionID),
                      let k = p.tracks[loc.track].regions[loc.region].gainRamps.firstIndex(where: { $0.id == rampID }) else { return }
                var ramp = p.tracks[loc.track].regions[loc.region].gainRamps[k]
                let end = ramp.start + ramp.length
                ramp.start = min(rt, end - 0.01)
                ramp.length = end - ramp.start
                p.tracks[loc.track].regions[loc.region].gainRamps[k] = ramp
                p.tracks[loc.track].regions[loc.region].gainRamps.sort { $0.start < $1.start }
            }
        case .volumeLine(let original, let rect, let startDB):
            let delta = volumeDB(atY: point.y, in: rect) - startDB
            callbacks.updateGesture { p in
                guard let loc = p.locate(region: original.id) else { return }
                var r = original
                r.gainDB = original.gainDB + delta
                for i in r.gainRamps.indices { r.gainRamps[i].gainDB += delta }
                p.tracks[loc.track].regions[loc.region] = r
            }
        case .move(let id, let grab, _):
            var newStart = max(0, t - grab)
            snapGuide = nil
            if snapping, let region = locate(id)?.region {
                let candidates = snapTargets(excluding: id)
                let tolerance = Double(TimelineMetrics.snapDistance) / pps
                var best: (delta: Double, guide: Double)?
                for c in candidates {
                    for edge in [newStart, newStart + region.length] {
                        let d = c - edge
                        if abs(d) <= tolerance, abs(d) < abs(best?.delta ?? .infinity) { best = (d, c) }
                    }
                }
                if let best { newStart = max(0, newStart + best.delta); snapGuide = best.guide }
            }
            let targetTrack = trackIndex(atY: point.y)
            callbacks.updateGesture { p in
                guard let loc = p.locate(region: id) else { return }
                var r = p.tracks[loc.track].regions[loc.region]
                r.start = newStart
                if let tt = targetTrack, tt != loc.track {
                    p.tracks[loc.track].regions.remove(at: loc.region)
                    p.tracks[tt].regions.append(r)
                    p.tracks[tt].regions.sort { $0.start < $1.start }
                } else {
                    p.tracks[loc.track].regions[loc.region] = r
                    p.tracks[loc.track].regions.sort { $0.start < $1.start }
                }
            }
        case .trimStart(let id, let original):
            // Moving the left edge keeps the audio in place: start and offset move together.
            var delta = t - original.start
            delta = max(delta, -original.offset)               // can't go before the file's beginning
            delta = max(delta, -original.start)                // or before zero on the timeline
            delta = min(delta, original.length - 0.05)
            callbacks.updateGesture { p in
                guard let loc = p.locate(region: id) else { return }
                var r = original
                r.start += delta
                r.offset += delta
                r.length -= delta
                r.gainRamps = original.gainRamps.map { var g = $0; g.start -= delta; return g }
                r.fadeIn = min(r.fadeIn, r.length)
                p.tracks[loc.track].regions[loc.region] = r
            }
        case .trimEnd(let id, let original):
            var length = max(0.05, t - original.start)
            if let sourceDuration = snapshot.sourceDurations[original.sourceID], sourceDuration > 0 {
                length = min(length, sourceDuration - original.offset)
            }
            callbacks.updateGesture { p in
                guard let loc = p.locate(region: id) else { return }
                p.tracks[loc.track].regions[loc.region].length = length
                p.tracks[loc.track].regions[loc.region].fadeOut = min(original.fadeOut, length)
            }
        case .fadeIn(let id):
            callbacks.updateGesture { p in
                guard let loc = p.locate(region: id) else { return }
                let r = p.tracks[loc.track].regions[loc.region]
                p.tracks[loc.track].regions[loc.region].fadeIn = max(0, min(t - r.start, r.length - r.fadeOut))
            }
        case .fadeOut(let id):
            callbacks.updateGesture { p in
                guard let loc = p.locate(region: id) else { return }
                let r = p.tracks[loc.track].regions[loc.region]
                p.tracks[loc.track].regions[loc.region].fadeOut = max(0, min(r.end - t, r.length - r.fadeIn))
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let drag, case .scrub = drag {} else if drag != nil { callbacks?.endGesture() }
        drag = nil
        snapGuide = nil
        needsDisplay = true
    }

    private func locate(_ id: UUID) -> (track: Int, region: Region)? {
        guard let loc = snapshot.project.locate(region: id) else { return nil }
        return (loc.track, snapshot.project.tracks[loc.track].regions[loc.region])
    }

    /// Edges of other regions, markers and the playhead.
    private func snapTargets(excluding id: UUID) -> [Double] {
        var out = [0, snapshot.playhead]
        for track in snapshot.project.tracks {
            for r in track.regions where r.id != id { out.append(r.start); out.append(r.end) }
        }
        out.append(contentsOf: snapshot.project.markers.map(\.time))
        return out
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        var context = MenuContext(time: max(0, time(point.x)))
        let menu = NSMenu()
        if let marker = markerHit(point) {
            context.markerID = marker.id
            menu.addItem(withTitle: "Rename Marker…", action: #selector(menuRenameMarker), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Delete Marker", action: #selector(menuDeleteMarker), keyEquivalent: "").target = self
        } else if let hit = hitRegion(at: point) {
            context.regionID = hit.region.id
            if let handle = volumeHandle(at: point, region: hit.region, rect: hit.rect) {
                context.rampID = handle.rampID
                menu.addItem(withTitle: "Delete Volume Change", action: #selector(menuDeleteRamp), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "Add Volume Change Here", action: #selector(menuAddRamp), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Add Marker Here", action: #selector(menuAddMarker), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Add Marker Here", action: #selector(menuAddMarker), keyEquivalent: "").target = self
        }
        menuContext = context
        return menu
    }

    @objc private func menuAddMarker() {
        guard let c = menuContext else { return }
        callbacks?.edit { p in
            p.markers.append(Marker(name: "Marker \(p.markers.count + 1)", time: c.time))
            p.markers.sort { $0.time < $1.time }
        }
    }

    @objc private func menuRenameMarker() {
        guard let id = menuContext?.markerID else { return }
        callbacks?.renameMarker(id)
    }

    @objc private func menuDeleteMarker() {
        guard let id = menuContext?.markerID else { return }
        callbacks?.edit { $0.markers.removeAll { $0.id == id } }
    }

    @objc private func menuAddRamp() {
        guard let c = menuContext, let regionID = c.regionID else { return }
        callbacks?.select(regionID, nil)
        callbacks?.beginGesture()
        _ = addVolumeChange(regionID: regionID, at: c.time)
        callbacks?.endGesture()
    }

    @objc private func menuDeleteRamp() {
        guard let c = menuContext, let regionID = c.regionID, let rampID = c.rampID else { return }
        callbacks?.edit { p in
            guard let loc = p.locate(region: regionID) else { return }
            p.tracks[loc.track].regions[loc.region].gainRamps.removeAll { $0.id == rampID }
        }
    }

    // MARK: Keyboard & gestures

    override func keyDown(with event: NSEvent) {
        guard let callbacks else { return super.keyDown(with: event) }
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        switch event.keyCode {
        case 49: callbacks.togglePlay()                      // space
        case 123: callbacks.nudge(-step)                     // left arrow
        case 124: callbacks.nudge(step)                      // right arrow
        case 51, 117: callbacks.deleteSelection()            // delete, forward delete
        case 46 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:   // M: marker at playhead
            let at = snapshot.playhead
            callbacks.edit { p in
                p.markers.append(Marker(name: "Marker \(p.markers.count + 1)", time: at))
                p.markers.sort { $0.time < $1.time }
            }
        default: super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        callbacks?.zoom(1 + Double(event.magnification))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            callbacks?.zoom(event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: TimelineMetrics.rulerHeight), cursor: .pointingHand)
    }
}

import AVFoundation
import EditorCore
import Foundation

/// Plays the live mix through AVAudioEngine. The render callback pulls from the same `Mixer` the exporter uses,
/// so what you hear is what gets exported (before loudness normalization).
final class PlaybackEngine {
    let sampleRate: Double
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private let lock = NSLock()
    private var mixer: Mixer?
    private var position = 0
    private var playing = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        sourceNode = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.playing, let mixer = self.mixer {
                mixer.render(startFrame: self.position, frameCount: n, left: l, right: r)
                self.position += n
                if self.position >= mixer.durationFrames { self.position = mixer.durationFrames; self.playing = false }
            } else {
                l.update(repeating: 0, count: n)
                r.update(repeating: 0, count: n)
            }
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func update(project: Project, sources: [UUID: PCMData]) {
        let next = Mixer(project: project, sources: sources)
        lock.lock()
        mixer = next
        lock.unlock()
    }

    func play(from seconds: Double) {
        lock.lock()
        position = max(0, Int(seconds * sampleRate))
        playing = true
        lock.unlock()
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("Audio engine failed to start: \(error)") }
        }
    }

    func pause() {
        lock.lock()
        playing = false
        lock.unlock()
        engine.pause()
    }

    func seek(to seconds: Double) {
        lock.lock()
        position = max(0, Int(seconds * sampleRate))
        lock.unlock()
    }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    var currentTime: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(position) / sampleRate
    }

    func shutdown() {
        pause()
        engine.stop()
    }
}

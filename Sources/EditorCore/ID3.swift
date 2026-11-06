import Foundation

/// Builds an ID3v2.3 tag with the fields podcast apps and hosts read.
public enum ID3Tag {
    public struct Chapter {
        public var title: String
        public var start: Double
        public var end: Double
        public init(title: String, start: Double, end: Double) {
            self.title = title
            self.start = start
            self.end = end
        }
    }

    public static func build(metadata m: PodcastMetadata, artwork: Data? = nil, chapters: [Chapter] = []) -> Data {
        var frames = Data()
        func text(_ id: String, _ value: String) {
            guard !value.isEmpty else { return }
            frames.append(frame(id, textPayload(value)))
        }
        text("TIT2", m.title)
        text("TPE1", m.author)
        text("TALB", m.album)
        text("TRCK", m.trackNumber)
        if let year = m.year { text("TYER", year) }
        text("TCON", m.genre)
        text("TCOP", m.copyright)
        if !m.description.isEmpty {
            frames.append(frame("COMM", commentPayload(m.description)))
            text("TDES", m.description)          // iTunes podcast description
        }
        text("TKWD", m.keywords)                 // iTunes podcast keywords
        if !m.link.isEmpty {
            text("WFED", m.link)                 // iTunes feed URL (text frame despite the W prefix)
            frames.append(frame("WXXX", userURLPayload(description: "", url: m.link)))
        }
        if !m.email.isEmpty { frames.append(frame("TXXX", userTextPayload(description: "Email", value: m.email))) }
        if m.explicit { frames.append(frame("TXXX", userTextPayload(description: "ITUNESADVISORY", value: "1"))) }
        if !m.title.isEmpty || !m.album.isEmpty {
            frames.append(frame("PCST", Data([0, 0, 0, 0])))  // marks the file as a podcast episode
        }
        if let artwork, !artwork.isEmpty {
            frames.append(frame("APIC", picturePayload(artwork)))
        }
        if !chapters.isEmpty {
            frames.append(chapterFrames(chapters))
        }

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [3, 0, 0])            // v2.3.0, no flags
        tag.append(syncsafe(frames.count))
        tag.append(frames)
        return tag
    }

    // MARK: Frames

    static func frame(_ id: String, _ payload: Data) -> Data {
        var d = Data(id.utf8)
        d.append(bigEndian32(payload.count))
        d.append(contentsOf: [0, 0])                 // flags
        d.append(payload)
        return d
    }

    /// UTF-16 with BOM, which every ID3v2.3 reader handles for non-ASCII text.
    static func utf16(_ s: String, terminated: Bool) -> Data {
        var d = Data([0xFF, 0xFE])
        for unit in s.utf16 { d.append(UInt8(unit & 0xFF)); d.append(UInt8(unit >> 8)) }
        if terminated { d.append(contentsOf: [0, 0]) }
        return d
    }

    static func textPayload(_ value: String) -> Data {
        var d = Data([1])
        d.append(utf16(value, terminated: false))
        return d
    }

    static func commentPayload(_ value: String) -> Data {
        var d = Data([1])
        d.append(Data("eng".utf8))
        d.append(utf16("", terminated: true))
        d.append(utf16(value, terminated: false))
        return d
    }

    static func userTextPayload(description: String, value: String) -> Data {
        var d = Data([1])
        d.append(utf16(description, terminated: true))
        d.append(utf16(value, terminated: false))
        return d
    }

    static func userURLPayload(description: String, url: String) -> Data {
        var d = Data([0])
        d.append(Data(description.utf8)); d.append(0)
        d.append(Data(url.utf8))
        return d
    }

    static func picturePayload(_ image: Data) -> Data {
        let isPNG = image.starts(with: [0x89, 0x50, 0x4E, 0x47])
        var d = Data([0])
        d.append(Data((isPNG ? "image/png" : "image/jpeg").utf8)); d.append(0)
        d.append(3)                                  // front cover
        d.append(0)                                  // empty description
        d.append(image)
        return d
    }

    static func chapterFrames(_ chapters: [Chapter]) -> Data {
        var out = Data()
        var ids: [String] = []
        for (i, ch) in chapters.enumerated() {
            let id = "ch\(i)"
            ids.append(id)
            var p = Data(id.utf8); p.append(0)
            p.append(bigEndian32(Int((ch.start * 1000).rounded())))
            p.append(bigEndian32(Int((ch.end * 1000).rounded())))
            p.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])  // byte offsets unused
            p.append(frame("TIT2", textPayload(ch.title)))
            out.append(frame("CHAP", p))
        }
        var toc = Data("toc".utf8); toc.append(0)
        toc.append(0x03)                             // top-level, ordered
        toc.append(UInt8(min(ids.count, 255)))
        for id in ids.prefix(255) { toc.append(Data(id.utf8)); toc.append(0) }
        return frame("CTOC", toc) + out
    }

    // MARK: Integers

    static func bigEndian32(_ v: Int) -> Data {
        let u = UInt32(truncatingIfNeeded: v)
        return Data([UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)])
    }

    static func syncsafe(_ v: Int) -> Data {
        Data([UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)])
    }
}

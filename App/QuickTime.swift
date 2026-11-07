import Foundation

struct WallpaperError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { self.errorDescription = message }
    static let format = WallpaperError("Die erzeugte Videostruktur entspricht nicht dem Sperrbildschirmprofil.")
}

private struct Atom {
    let name: Data
    let payload: Data
    let start: Int
    let header: Int
    var tag: String { String(decoding: name, as: UTF8.self) }
    var end: Int { start + header + payload.count }
    var contentStart: Int { start + header }

    static func scan(_ data: Data) throws -> [Atom] {
        var out: [Atom] = []
        var cursor = 0
        while cursor < data.count {
            let size32 = try data.u32(cursor)
            let header = size32 == 1 ? 16 : 8
            let size: Int
            if size32 == 1 {
                let high = try data.u32(cursor + 8)
                guard high == 0 else { throw WallpaperError.format }
                size = Int(try data.u32(cursor + 12))
            } else {
                size = size32 == 0 ? data.count - cursor : Int(size32)
            }
            guard size >= header, size <= data.count - cursor else { throw WallpaperError.format }
            out.append(Atom(name: data.subdata(in: cursor+4 ..< cursor+8),
                            payload: data.subdata(in: cursor+header ..< cursor+size),
                            start: cursor, header: header))
            cursor += size
        }
        return out
    }

    static func one(_ tag: String, in data: Data) throws -> Atom {
        let found = try scan(data).filter { $0.tag == tag }
        guard found.count == 1 else { throw WallpaperError.format }
        return found[0]
    }

    static func get(_ data: Data, _ path: [String]) throws -> Data {
        try path.reduce(data) { bytes, tag in try one(tag, in: bytes).payload }
    }

    static func patch(_ data: Data, at path: ArraySlice<String>,
                      _ change: (Data) throws -> Data) throws -> Data {
        guard let tag = path.first else { return try change(data) }
        let match = try one(tag, in: data)
        let body = try patch(match.payload, at: path.dropFirst(), change)
        var copy = data
        copy.replaceSubrange(match.start ..< match.end, with: try make(match.name, body))
        return copy
    }

    static func make(_ name: Data, _ payload: Data) throws -> Data {
        guard name.count == 4, let size = UInt32(exactly: payload.count + 8) else {
            throw WallpaperError.format
        }
        return size.be + name + payload
    }

    static func make(_ tag: String, _ payload: Data) throws -> Data {
        try make(Data(tag.utf8), payload)
    }
}

private extension Data {
    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw WallpaperError.format }
        return self[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func set32(_ offset: Int, _ number: UInt32) throws {
        guard offset >= 0, offset <= count - 4 else { throw WallpaperError.format }
        replaceSubrange(offset..<offset+4, with: number.be)
    }
}

private extension UInt32 {
    var be: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

enum QuickTime {
    private static let media = ["mdia", "minf", "stbl"]
    private static func metadata(_ uuid: String) throws -> Data {
        let key = try Atom.make("mdta", Data("com.apple.quicktime.content.identifier".utf8))
        let keys = try Atom.make("keys", UInt32(0).be + UInt32(1).be + key)
        let data = try Atom.make("data", UInt32(1).be + UInt32(0).be + Data(uuid.utf8))
        let item = try Atom.make(UInt32(1).be, data)
        let list = try Atom.make("ilst", item)
        let handler = try Atom.make("hdlr", Data(repeating: 0, count: 8) +
                                    Data("mdta".utf8) + Data(repeating: 0, count: 14))
        return try Atom.make("meta", handler + keys + list)
    }

    static func pair(video: URL, template: URL, output: URL, uuid: String) throws {
        let input = try Data(contentsOf: video)
        let donor = try Data(contentsOf: template)
        let top = try Atom.scan(input)
        guard top.map(\.tag) == ["ftyp", "wide", "mdat", "moov"],
              top[2].header == 8 else { throw WallpaperError.format }
        let mv = top[3].payload
        let child = try Atom.scan(mv)
        let videos = child.filter { $0.tag == "trak" }
        guard videos.count == 1,
              try Atom.get(videos[0].payload, ["mdia", "hdlr"]).subdata(in: 8..<12) == Data("vide".utf8),
              try Atom.get(videos[0].payload, ["tkhd"]).u32(12) == 1 else {
            throw WallpaperError.format
        }
        let videoTable = try Atom.get(videos[0].payload, media)
        let desc = try Atom.get(videoTable, ["stsd"])
        let timings = try Atom.get(videoTable, ["stts"])
        guard desc.count > 20, desc.subdata(in: 12..<16) == Data("hvc1".utf8),
              try timings.u32(4) == 1, try timings.u32(8) == 90, try timings.u32(12) == 20 else {
            throw WallpaperError.format
        }
        var mvhd = try Atom.get(mv, ["mvhd"])
        guard mvhd.first == 0, try mvhd.u32(12) == 600, try mvhd.u32(16) == 1800 else {
            throw WallpaperError.format
        }
        try mvhd.set32(mvhd.count - 4, 5)

        let donorMedia = try Atom.one("mdat", in: donor)
        let tracks = try Atom.scan(Atom.get(donor, ["moov"])).filter { $0.tag == "trak" }
        guard tracks.count == 3 else { throw WallpaperError.format }
        let offsetDelta = top[2].end - donorMedia.contentStart
        var newTracks = Data()
        for (index, track) in tracks.enumerated() {
            let h = try Atom.get(track.payload, ["mdia", "hdlr"])
            guard h.count >= 12, h.subdata(in: 8..<12) == Data("meta".utf8),
                  try Atom.get(track.payload, ["tkhd"]).u32(12) == UInt32(index+2) else {
                throw WallpaperError.format
            }
            let data = try Atom.patch(track.payload, at: (media + ["stco"])[...]) { body in
                var copy = body
                let count = Int(try body.u32(4))
                guard body.count == 8 + 4 * count else { throw WallpaperError.format }
                for i in 0..<count {
                    let old = Int(try body.u32(8 + i * 4))
                    guard donorMedia.contentStart <= old, old < donorMedia.end,
                          let new = UInt32(exactly: old + offsetDelta) else { throw WallpaperError.format }
                    try copy.set32(8 + i * 4, new)
                }
                return copy
            }
            newTracks.append(try Atom.make("trak", data))
        }
        let moov = try Atom.make("moov", Atom.make("mvhd", mvhd) +
                                 Atom.make("trak", videos[0].payload) + newTracks + metadata(uuid))
        var result = input.prefix(top[2].start)
        result.append(try Atom.make("mdat", top[2].payload + donorMedia.payload))
        result.append(moov)
        try result.write(to: output, options: [.withoutOverwriting])
    }
}

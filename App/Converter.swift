import Foundation
import AppKit
import AVFoundation
import ImageIO
import Photos
import UniformTypeIdentifiers

struct WallpaperPair: Sendable {
    let folder: URL
    let name: String
    var image: URL { folder.appendingPathComponent(name).appendingPathExtension("heic") }
    var movie: URL { folder.appendingPathComponent(name).appendingPathExtension("mov") }

    func export(to destination: URL) throws -> URL {
        let fm = FileManager.default
        for i in 1...999 {
            let base = i == 1 ? "\(name) – Live Photo" : "\(name) – Live Photo \(i)"
            let target = destination.appendingPathComponent(base, isDirectory: true)
            do {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError {
                continue
            }
            do {
                try fm.copyItem(at: image, to: target.appendingPathComponent(image.lastPathComponent))
                try fm.copyItem(at: movie, to: target.appendingPathComponent(movie.lastPathComponent))
                return target
            } catch {
                try? fm.removeItem(at: target)
                throw error
            }
        }
        throw WallpaperError("Es gibt bereits zu viele gleichnamige Exporte. Wähle einen anderen Ordner.")
    }
}

enum Converter {
    private struct Timeline {
        let count: Int
        let duration: Double
        let color: String?
    }

    private static func process(_ binary: URL, _ args: [String], log: URL,
                                collectLog: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["-nostdin", "-hide_banner", "-nostats", "-n"] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try Data().write(to: log)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        p.standardError = logHandle
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: log)
            defer { try? reader.close() }
            let length = try reader.seekToEnd()
            try reader.seek(toOffset: length > 3000 ? length - 3000 : 0)
            let diagnostic = (try reader.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw WallpaperError(diagnostic.isEmpty ? "Das Video konnte nicht verarbeitet werden." : diagnostic)
        }
        return collectLog ? try String(contentsOf: log, encoding: .utf8) : ""
    }

    private static func timeline(_ report: String) throws -> Timeline {
        var first: Double?
        var last: Double?
        var index = -1
        var color: String?
        for line in report.split(separator: "\n") where line.contains("Parsed_showinfo") {
            if let mark = line.range(of: "] n:"),
               let time = line.range(of: " pts_time:"),
               let start = line.range(of: " pts:"),
               let n = Int(line[mark.upperBound..<start.lowerBound].trimmingCharacters(in: .whitespaces)),
               let value = line[time.upperBound...].split(whereSeparator: \.isWhitespace).first,
               let pts = Double(value), pts.isFinite {
                guard n == index+1 else { throw WallpaperError("Das Video wechselt während der Wiedergabe sein Bildformat.") }
                index = n
                if first == nil { first = pts }
                last = pts
            }
            if color == nil, let m = line.range(of: "color_trc:") {
                color = line[m.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
            }
        }
        guard index > 0, let first, let last, last > first else {
            throw WallpaperError("Wähle ein Video mit mindestens zwei Bildern.")
        }
        return Timeline(count: index+1, duration: last-first, color: color)
    }

    static func build(video input: URL, ffmpeg: URL, template: URL) throws -> WallpaperPair {
        guard input.isFileURL, (try input.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw WallpaperError("Wähle eine lokale Videodatei.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("de.livewallpaper.app", isDirectory: true)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = input.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(stem.prefix(120))
        let pair = WallpaperPair(folder: dir, name: name.isEmpty ? "Hintergrundbild" : name)
        let work = dir.appendingPathComponent(".Render", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            let log = work.appendingPathComponent("ffmpeg.log")
            let source = ["-protocol_whitelist", "file,pipe", "-threads", "2", "-i", input.path]
            let meta = try process(ffmpeg, ["-loglevel", "info"] + source + [
                "-map", "0:V:0", "-vf", "showinfo=checksum=0", "-an", "-fps_mode", "passthrough",
                "-f", "null", "-"
            ], log: log, collectLog: true)
            let info = try timeline(meta)
            let rate = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), 0.3 / info.duration)
            let hdr = info.color == "arib-std-b67" || info.color == "smpte2084"
            let hdrToSDR = hdr
                ? "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=1.5,zscale=t=bt709:m=bt709:r=limited,format=yuv420p,"
                : ""
            // Cover and motion are cropped the same way; standard landscape is
            // centered, portrait is preserved. Always honor rotation metadata.
            let fit = "scale=886:1920:force_original_aspect_ratio=increase:force_divisible_by=2:flags=lanczos:out_color_matrix=bt709:out_range=tv,crop=886:1920,setsar=1"
            let coverFit = "scale=1320:2868:force_original_aspect_ratio=increase:force_divisible_by=2:flags=lanczos:in_color_matrix=auto,crop=1320:2868,setsar=1"
            let videoFilter = "settb=AVTB,setpts=(PTS-STARTPTS)*\(rate),tpad=stop_mode=clone:stop_duration=3,fps=fps=30:start_time=0:round=near,tpad=start_mode=clone:start=37"
            let graph = "[0:V:0]split=2[motion][frame];" +
                "[motion]\(videoFilter),\(hdrToSDR)\(fit),format=yuv420p[v];" +
                "[frame]select=eq(n\\,\(info.count-1)),\(hdrToSDR)\(coverFit),format=rgb24[still]"
            let normalized = work.appendingPathComponent("Normalized.mov")
            let cover = work.appendingPathComponent("Still.png")
            _ = try process(ffmpeg, ["-loglevel", "error"] + source + [
                "-filter_complex_threads", "2", "-filter_complex", graph,
                "-map", "[v]", "-an", "-map_metadata", "-1", "-frames:v", "90",
                "-c:v", "libx265", "-preset", "medium", "-crf", "16", "-profile:v", "main",
                "-x265-params", "pools=2:frame-threads=2:log-level=error:level-idc=5.1",
                "-color_range", "tv", "-color_primaries", "bt709", "-color_trc", "bt709",
                "-colorspace", "bt709", "-tag:v", "hvc1", "-use_editlist", "1",
                "-movie_timescale", "600", "-video_track_timescale", "600",
                "-movflags", "+negative_cts_offsets", normalized.path,
                "-map", "[still]", "-map_metadata", "-1", "-frames:v", "1", "-threads", "1",
                "-update", "1", cover.path
            ], log: log)
            let id = UUID().uuidString
            try writeCover(cover, output: pair.image, uuid: id)
            try QuickTime.pair(video: normalized, template: template, output: pair.movie, uuid: id)
            try FileManager.default.removeItem(at: work)
            return pair
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private static func writeCover(_ input: URL, output: URL, uuid: String) throws {
        let maker = kCGImagePropertyMakerAppleDictionary as String
        guard let s = CGImageSourceCreateWithURL(input as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(s, 0, nil),
              let d = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else { throw WallpaperError("Das letzte Videobild konnte nicht gespeichert werden.") }
        CGImageDestinationAddImage(d, cg, [
            maker: ["17": uuid],
            kCGImagePropertyOrientation as String: 1,
            kCGImageDestinationLossyCompressionQuality as String: 1.0
        ] as CFDictionary)
        guard CGImageDestinationFinalize(d),
              let read = CGImageSourceCreateWithURL(output as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(read, 0, nil) as? [String: Any],
              (properties[maker] as? [String: Any])?["17"] as? String == uuid else {
            throw WallpaperError("Das Standbild konnte nicht mit dem Video verknüpft werden.")
        }
    }
}

enum PhotosBridge {
    @MainActor
    static func validate(_ pair: WallpaperPair) async throws {
        let ok: Bool = await withCheckedContinuation { c in
            PHLivePhoto.request(withResourceFileURLs: [pair.image, pair.movie], placeholderImage: nil,
                                targetSize: .zero, contentMode: .aspectFit) { live, info in
                guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true else { return }
                c.resume(returning: live != nil)
            }
        }
        guard ok else { throw WallpaperError("Fotos konnte das Ergebnis nicht als Live Photo lesen.") }
    }

    static func add(_ pair: WallpaperPair) async throws {
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            throw WallpaperError("Fotos-Zugriff fehlt. Erlaube ihn in den Systemeinstellungen oder sichere das Dateipaar.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: pair.image, options: nil)
            request.addResource(with: .pairedVideo, fileURL: pair.movie, options: nil)
        }
    }
}

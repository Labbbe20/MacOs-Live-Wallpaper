import Foundation
import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import Photos
import UniformTypeIdentifiers

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

func file(_ path: String) -> URL { URL(fileURLWithPath: path) }
func imageSource(_ url: URL) throws -> CGImageSource {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw Failure("Bildquelle nicht lesbar: \(url.path)")
    }
    return src
}
func properties(_ source: CGImageSource) throws -> [String: Any] {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
        throw Failure("Bildmetadaten nicht lesbar")
    }
    return props
}
let makerApple = kCGImagePropertyMakerAppleDictionary as String
func writeImage(_ image: CGImage, _ url: URL, _ type: UTType, _ options: [String: Any]) throws {
    guard !FileManager.default.fileExists(atPath: url.path),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw Failure("Ausgabebild existiert oder lässt sich nicht anlegen: \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, options as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw Failure("Bild konnte nicht geschrieben werden") }
}
func makeCover(_ src: URL, _ dst: URL, _ id: String) throws {
    let source = try imageSource(src)
    let props = try properties(source)
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("Bilddekodierung fehlgeschlagen") }
    let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
    guard orientation == 1 else { throw Failure("Standbild zuerst ohne EXIF-Drehung exportieren (Orientation 1)") }
    try writeImage(image, dst, .heic, [
        kCGImageDestinationLossyCompressionQuality as String: 1.0,
        kCGImagePropertyOrientation as String: 1,
        makerApple: ["17": id]
    ])
    let out = try properties(imageSource(dst))
    guard (out[makerApple] as? [String: Any])?["17"] as? String == id else {
        throw Failure("ImageIO hat den MakerApple-Identifikator nicht übernommen")
    }
}

func fourCC(_ n: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: n >> $0) }, encoding: .ascii) ?? String(n)
}
func inspectMovie(_ url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let dur = try await asset.load(.duration)
    print("AVFoundation: Dauer \(dur.value)/\(dur.timescale)s (\(dur.seconds)); playable \(try await asset.load(.isPlayable))")
    for item in try await asset.loadMetadata(for: .quickTimeMetadata) {
        print("  Movie item \(item.identifier?.rawValue ?? "?") = \(String(describing: try await item.load(.value)))")
    }
    for track in try await asset.load(.tracks) {
        let range = try await track.load(.timeRange)
        let fmt = try await track.load(.formatDescriptions)
        let tr = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        print("  Spur \(track.trackID) \(track.mediaType.rawValue) [\(range.start.seconds), \(range.end.seconds)) fps \(fps), transform \(tr)")
        for desc in fmt {
            print("    Format \(fourCC(CMFormatDescriptionGetMediaSubType(desc)))")
            if track.mediaType == .video {
                print("    Videoformat \(CMVideoFormatDescriptionGetDimensions(desc)); \(String(describing: CMFormatDescriptionGetExtensions(desc)))")
            } else if track.mediaType == .metadata {
                print("    Identifikatoren \(String(describing: CMMetadataFormatDescriptionGetIdentifiers(desc)))")
            }
        }
        if track.mediaType == .metadata {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(out) else { throw Failure("Metadatenleser nicht verfügbar") }
            reader.add(out)
            guard reader.startReading() else { throw reader.error ?? Failure("Metadatenleser startet nicht") }
            var count = 0
            var showedGroup = false
            while let sb = out.copyNextSampleBuffer() {
                count += 1
                if let group = AVTimedMetadataGroup(sampleBuffer: sb),
                   !group.items.isEmpty, !showedGroup {
                    showedGroup = true
                    print("    Sample \(count) \(group.timeRange.start.seconds)s +\(group.timeRange.duration.seconds)s")
                    for item in group.items {
                        let val = try await item.load(.value)
                        print("      \(item.identifier?.rawValue ?? "?") [\(item.dataType ?? "?")] \(String(describing: val))")
                    }
                }
            }
            if reader.status == .failed { throw reader.error ?? Failure("Metadatenlesefehler") }
            print("    Lesbare Samples: \(count)")
        }
    }
}

func frame(_ input: URL, _ out: URL, _ time: CMTime) async throws {
    let asset = AVURLAsset(url: input)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let result = try await gen.image(at: time)
    try writeImage(result.image, out, .png, [:])
    print("\(result.actualTime.seconds)")
}

func verifyLive(_ photo: URL, _ video: URL) async throws {
    let result: Result<CGSize, Failure> = await withCheckedContinuation { continuation in
        // The Photos callback arrives on the main queue. Ignore partial results.
        PHLivePhoto.request(withResourceFileURLs: [photo, video], placeholderImage: nil, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit) { live, info in
            if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
            if let live = live {
                continuation.resume(returning: .success(live.size))
            } else {
                continuation.resume(returning: .failure(Failure("PHLivePhoto: \(info)")))
            }
        }
    }
    print("PHLivePhoto-Objekt erhalten (ohne Mediathekimport); gemeldete Größe: \(try result.get())")
}

@main
struct Main {
    static func main() async {
        let a = Array(CommandLine.arguments.dropFirst())
        do {
            switch (a.first, a.count) {
            case ("image", 2):
                let src = try imageSource(file(a[1]))
                print("ImageIO: \(CGImageSourceGetType(src) as String? ?? "?"), count \(CGImageSourceGetCount(src))")
                print(try properties(src) as NSDictionary)
            case ("movie", 2): try await inspectMovie(file(a[1]))
            case ("cover", 4): try makeCover(file(a[1]), file(a[2]), a[3])
            case ("frame", 4):
                let parts = a[3].split(separator: "/", omittingEmptySubsequences: false)
                if parts.count == 2, let n = Int64(parts[0]), let d = Int32(parts[1]), n >= 0, d > 0 {
                    try await frame(file(a[1]), file(a[2]), CMTime(value: n, timescale: d))
                } else if let t = Double(a[3]), t.isFinite, t >= 0 {
                    try await frame(file(a[1]), file(a[2]), CMTime(seconds: t, preferredTimescale: 600_000))
                } else { throw Failure("Ungültige Zeit") }
            case ("check-live", 3): try await verifyLive(file(a[1]), file(a[2]))
            default: throw Failure("image BILD | movie MOV | cover BILD NEU.HEIC UUID | frame MOV NEU.PNG SEK | check-live BILD MOV")
            }
        } catch {
            FileHandle.standardError.write(Data(("Fehler: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }
}

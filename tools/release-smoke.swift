import Foundation
import AVFoundation
import ImageIO

@main
enum Smoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw WallpaperError("Usage: smoke VIDEO APP") }
        let app = URL(fileURLWithPath: args[2])
        let pair = try Converter.build(
            video: URL(fileURLWithPath: args[1]),
            ffmpeg: app.appendingPathComponent("Contents/MacOS/ffmpeg"),
            template: app.appendingPathComponent("Contents/Resources/Wallpaper-Profil.mov")
        )
        defer { try? FileManager.default.removeItem(at: pair.folder) }
        let asset = AVURLAsset(url: pair.movie)
        let tracks = try await asset.load(.tracks)
        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.metadata)
        let key = AVMetadataIdentifier.quickTimeMetadataContentIdentifier
        let movieID = try await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: key)
            .first?.load(.stringValue)
        let image = CGImageSourceCreateWithURL(pair.image as CFURL, nil)
        let props = image.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        let imageID = (props?[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"] as? String
        guard duration.seconds == 3, tracks.map(\.mediaType) == [.video, .metadata, .metadata],
              let movieID, UUID(uuidString: movieID) != nil, movieID == imageID else {
            throw WallpaperError("Expected a three-second movie, two timed metadata tracks, and a matching HEIC identifier")
        }
        print("Built and validated a Live Photo from a generated test video.")
    }
}

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Portable stickers are small PNG thumbnails embedded in the graph.
nonisolated enum StudioStickerAsset {
    private static let maximumInputBytes = 12_000_000
    private static let maximumPixelSize = 128
    private static let maximumPNGBytes = 85_000

    static func importImage(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: maximumInputBytes + 1), data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary)
        else { throw StudioEffectsGraph.GraphError.sticker }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw StudioEffectsGraph.GraphError.sticker }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumPNGBytes
        else { throw StudioEffectsGraph.GraphError.sticker }
        return output as Data
    }

    static func decode(_ data: Data) -> CGImage? {
        guard data.count <= maximumPNGBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, (1...maximumPixelSize).contains(width),
              let height = props[kCGImagePropertyPixelHeight] as? Int, (1...maximumPixelSize).contains(height)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

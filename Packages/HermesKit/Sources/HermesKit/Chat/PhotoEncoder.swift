import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes the upload form of a photo (issue #8): long edge 2048 px or less, JPEG, orientation applied.
/// HEIC, PNG and other ImageIO types go in. The GPS data goes out unless `includeLocation` is `true`
/// (Settings, "Include photo location", default off).
public enum PhotoEncoder {
    public struct Encoded: Sendable, Equatable {
        public var data: Data
        public var width: Int
        public var height: Int
    }

    public enum Failure: Error, Equatable {
        case unreadable
        case encodeFailed
    }

    public static let quality = 0.85

    public static func encode(_ source: Data, longEdge: Int = AttachmentLimits.photoLongEdge,
                              includeLocation: Bool = false) throws -> Encoded {
        guard let image = CGImageSourceCreateWithData(source as CFData, nil),
              CGImageSourceGetCount(image) > 0 else { throw Failure.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // The thumbnail call scales and applies the EXIF orientation in one step.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, max(width, height, 1)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        var output: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        // The pixels are upright now, so no orientation tag goes out.
        output[kCGImagePropertyOrientation] = 1
        if includeLocation, let gps = properties[kCGImagePropertyGPSDictionary] {
            output[kCGImagePropertyGPSDictionary] = gps
        }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            // Capture date and camera settings only. No maker notes and no user comments.
            let keep: [CFString] = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                                    kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber,
                                    kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength]
            output[kCGImagePropertyExifDictionary] = exif.filter { keep.contains($0.key) }
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.encodeFailed }
        CGImageDestinationAddImage(destination, scaled, output as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }
        return Encoded(data: data as Data, width: scaled.width, height: scaled.height)
    }

    /// `true` if the image data has a GPS dictionary (tests).
    public static func hasLocation(_ data: Data) -> Bool {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] else {
            return false
        }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }
}

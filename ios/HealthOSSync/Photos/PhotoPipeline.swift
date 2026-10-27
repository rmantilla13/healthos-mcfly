import ImageIO
import UIKit
import UniformTypeIdentifiers

// Photos the app sends (a portrait reference, a paper lab report, a meal photo): drawn upright first, then shrunk to
// the server's limit and re-encoded as a plain JPEG. The server never turns a photo: it reads the JPEG's own pixels
// (server/portraits.ts jpegSize), so the camera's orientation tag is applied before it's dropped with the rest of
// the metadata (where and when it was taken, the camera). Nothing is written to disk.

/// A photo ready to upload: an upright JPEG with no metadata, and its size in pixels.
struct PreparedPhoto: Equatable {
    let jpeg: Data
    let width: Int
    let height: Int

    /// For a JSON body ({image, width, height}): base64 without a data: prefix.
    var base64: String { jpeg.base64EncodedString() }
    /// How long `base64` is, without making it.
    var base64Count: Int { (jpeg.count + 2) / 3 * 4 }
}

enum PhotoPipeline {
    /// The JPEG quality the web uses for a reference photo (src/portraits.ts).
    static let quality: CGFloat = 0.86

    /// From a file's bytes (PhotosPicker's Data, a HEIC, a PNG): its orientation tag applied as it's read, longest side
    /// `longEdge` or less (never enlarged). nil when the bytes aren't an image.
    static func prepare(_ data: Data, longEdge: Int, quality: CGFloat = quality) -> PreparedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // A thumbnail with the transform: ImageIO shrinks it as it decodes and turns it upright. Reading the full image
        // and wrapping it in a UIImage would lose the orientation tag.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image, quality: quality)
    }

    /// From an image already decoded (the camera's): drawn as UIKit shows it, which applies its orientation, longest
    /// side `longEdge` or less (never enlarged).
    static func prepare(_ image: UIImage, longEdge: Int, quality: CGFloat = quality) -> PreparedPhoto? {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, CGFloat(longEdge) / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        // Pixels, not points: the screen's scale would make 1,600 into 4,800.
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            // A JPEG has no transparency: what's see-through goes on white, not black.
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cg = drawn.cgImage else { return nil }
        return encode(cg, quality: quality)
    }

    /// A portrait reference (src/portraits.ts shrinkReference): longest side 1,600 at most, and a quarter smaller each
    /// time, down to 400, until its base64 fits the server's limit. nil when it never fits, or isn't an image.
    static func reference(_ data: Data, maxEdge: Int = PortraitLimits.maxReferenceEdge, maxBase64: Int = PortraitLimits.maxReferenceBase64) -> PreparedPhoto? {
        shrunk(maxEdge: maxEdge, maxBase64: maxBase64) { prepare(data, longEdge: $0) }
    }

    static func reference(_ image: UIImage, maxEdge: Int = PortraitLimits.maxReferenceEdge, maxBase64: Int = PortraitLimits.maxReferenceBase64) -> PreparedPhoto? {
        shrunk(maxEdge: maxEdge, maxBase64: maxBase64) { prepare(image, longEdge: $0) }
    }

    /// The longest sides the shrink tries, as the web's loop does: 1600, 1200, 900, 675, 506.
    static func edges(from maxEdge: Int, down to: Int = 400) -> [Int] {
        var out: [Int] = []
        var edge = maxEdge
        while edge >= to {
            out.append(edge)
            edge = Int((Double(edge) * 0.75).rounded())
        }
        return out
    }

    private static func shrunk(maxEdge: Int, maxBase64: Int, make: (Int) -> PreparedPhoto?) -> PreparedPhoto? {
        for edge in edges(from: maxEdge) {
            guard let photo = make(edge) else { return nil }
            if photo.base64Count <= maxBase64 { return photo }
        }
        return nil
    }

    /// A JPEG of these pixels and nothing else: no location, time, camera or orientation tag.
    static func jpeg(_ image: CGImage, quality: CGFloat = quality) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, opaque(image), [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func encode(_ image: CGImage, quality: CGFloat) -> PreparedPhoto? {
        jpeg(image, quality: quality).map { PreparedPhoto(jpeg: $0, width: image.width, height: image.height) }
    }

    /// The image on white when it has see-through parts (a PNG, a screenshot), since a JPEG keeps none.
    private static func opaque(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }
}

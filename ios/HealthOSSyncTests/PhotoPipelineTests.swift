import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import HealthOSSync

/// Photos the app sends (Photos/PhotoPipeline.swift): turned upright before the metadata goes, since the server never
/// turns one; shrunk to its limit; nothing of where, when or with what camera it was taken left in the file.
final class PhotoPipelineTests: XCTestCase {
    /// Stored pixels 200 × 100, left half red and right half blue, as a camera writes a portrait shot held sideways.
    private func pixels(width: Int = 200, height: Int = 100) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(UIColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(UIColor.blue.cgColor)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return ctx.makeImage()!
    }

    /// A camera's JPEG: tagged to be shown turned (EXIF orientation 6, a quarter turn clockwise), with where, when and
    /// on what it was taken.
    private func cameraJPEG(_ image: CGImage, orientation: Int = 6) throws -> Data {
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 40.7128, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 74.006, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:20 08:15:00"],
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func properties(_ jpeg: Data) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    /// The colour at (x, y) from the top left, as the file's own pixels have it (no orientation applied when read).
    private func color(_ jpeg: Data, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    private func assertNoMetadata(_ jpeg: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let p = try properties(jpeg)
        XCTAssertNil(p[kCGImagePropertyGPSDictionary as String], "no location", file: file, line: line)
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake as String], "no camera", file: file, line: line)
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel as String], file: file, line: line)
        let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String], "no time taken", file: file, line: line)
        let orientation = p[kCGImagePropertyOrientation as String] as? Int
        XCTAssertTrue(orientation == nil || orientation == 1, "upright in its own pixels, so no orientation tag", file: file, line: line)
    }

    func testAPhotosOrientationIsAppliedBeforeItsMetadataGoes() throws {
        let photo = try XCTUnwrap(PhotoPipeline.prepare(try cameraJPEG(pixels()), longEdge: 1600))
        // Turned a quarter clockwise: tall, the stored left half (red) now on top.
        XCTAssertEqual(photo.width, 100)
        XCTAssertEqual(photo.height, 200)
        let p = try properties(photo.jpeg)
        XCTAssertEqual(p[kCGImagePropertyPixelWidth as String] as? Int, 100, "the server measures the JPEG's own pixels")
        XCTAssertEqual(p[kCGImagePropertyPixelHeight as String] as? Int, 200)
        let top = try color(photo.jpeg, x: 50, y: 20)
        let bottom = try color(photo.jpeg, x: 50, y: 180)
        XCTAssertGreaterThan(top.r, 200)
        XCTAssertLessThan(top.b, 60)
        XCTAssertGreaterThan(bottom.b, 200)
        XCTAssertLessThan(bottom.r, 60)
        try assertNoMetadata(photo.jpeg)
    }

    func testTheCamerasImageIsDrawnAsItsShown() throws {
        // The camera hands over a UIImage that's turned (.right is EXIF 6).
        let turned = UIImage(cgImage: pixels(), scale: 1, orientation: .right)
        let photo = try XCTUnwrap(PhotoPipeline.prepare(turned, longEdge: 1600))
        XCTAssertEqual(photo.width, 100)
        XCTAssertEqual(photo.height, 200)
        XCTAssertGreaterThan(try color(photo.jpeg, x: 50, y: 20).r, 200)
        XCTAssertGreaterThan(try color(photo.jpeg, x: 50, y: 180).b, 200)
        try assertNoMetadata(photo.jpeg)
    }

    func testShrunkToTheLongestSideAndNeverEnlarged() throws {
        let big = try cameraJPEG(pixels(width: 4032, height: 3024), orientation: 1)
        let photo = try XCTUnwrap(PhotoPipeline.prepare(big, longEdge: 1600))
        XCTAssertEqual(photo.width, 1600)
        XCTAssertEqual(photo.height, 1200)
        let small = try XCTUnwrap(PhotoPipeline.prepare(try cameraJPEG(pixels(), orientation: 1), longEdge: 1600))
        XCTAssertEqual(small.width, 200, "never enlarged")
        XCTAssertNil(PhotoPipeline.prepare(Data("not a photo".utf8), longEdge: 1600))
    }

    func testAReferenceShrinksUntilItFits() throws {
        // The web's loop (src/portraits.ts shrinkReference): a quarter smaller each time, from 1,600 down to 400.
        XCTAssertEqual(PhotoPipeline.edges(from: 1600), [1600, 1200, 900, 675, 506])
        XCTAssertEqual(PortraitLimits.maxReferenceEdge, 1600)
        XCTAssertEqual(PortraitLimits.maxReferenceBase64, 4_400_000)

        let big = try cameraJPEG(pixels(width: 4032, height: 3024))
        let fits = try XCTUnwrap(PhotoPipeline.reference(big))
        XCTAssertEqual(max(fits.width, fits.height), 1600, "a plain photo fits at once")
        XCTAssertEqual(fits.width, 1200, "upright: orientation 6 makes it tall")
        XCTAssertLessThanOrEqual(fits.base64Count, PortraitLimits.maxReferenceBase64)
        XCTAssertEqual(fits.base64Count, fits.base64.count)

        // Under a tighter limit it steps down until it fits.
        let at1600 = try XCTUnwrap(PhotoPipeline.prepare(big, longEdge: 1600)).base64Count
        let stepped = try XCTUnwrap(PhotoPipeline.reference(big, maxBase64: at1600 - 1))
        XCTAssertEqual(max(stepped.width, stepped.height), 1200)
        XCTAssertNil(PhotoPipeline.reference(big, maxBase64: 100), "never small enough: refused, not sent")

        let fromCamera = try XCTUnwrap(PhotoPipeline.reference(UIImage(cgImage: pixels(width: 3000, height: 2000), scale: 1, orientation: .up)))
        XCTAssertEqual(fromCamera.width, 1600)
    }

    func testSeeThroughPartsGoOnWhite() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).pngData { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        }
        let photo = try XCTUnwrap(PhotoPipeline.prepare(png, longEdge: 1600))
        let clear = try color(photo.jpeg, x: 30, y: 20)
        XCTAssertGreaterThan(clear.r + clear.g + clear.b, 700, "white, not black")
        XCTAssertLessThan(try color(photo.jpeg, x: 5, y: 20).r, 40)
    }

    func testMealPhotosStillGoThroughIt() throws {
        let turned = UIImage(cgImage: pixels(width: 2560, height: 1280), scale: 1, orientation: .right)
        let data = try XCTUnwrap(FoodPhoto.jpeg(from: turned))
        let p = try properties(data)
        XCTAssertEqual(p[kCGImagePropertyPixelWidth as String] as? Int, 640)
        XCTAssertEqual(p[kCGImagePropertyPixelHeight as String] as? Int, 1280)
        try assertNoMetadata(data)
    }
}

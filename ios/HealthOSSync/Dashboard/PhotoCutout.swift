import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Vision

/// The profile photo, processed on the iPhone with Apple Vision: the person cut out of the background, a square
/// face avatar, and where to pin the vitals callouts. A port of server/photo/cutout.swift (the Mac tool), so iPhone
/// photos get the same result; only the finished PNGs and layout go to the server.
struct PhotoCutout {
    let cutout: CGImage
    let avatar: CGImage
    /// POST /api/profile/photo/upload `meta`: every layout value 0–1 within the cut-out.
    let meta: [String: Any]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Processing cap: the upload sends the cut-out at most 1,200 px on its long side.
    static let maxSide: CGFloat = 1200

    static func process(_ data: Data) throws -> PhotoCutout {
        func fail(_ message: String) -> Failure { Failure(message: message) }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw fail("Couldn't read that image. Choose a photo.") }

        // Apply EXIF orientation and cap the size so processing stays quick.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = Int32((props?[kCGImagePropertyOrientation] as? UInt32) ?? 1)
        var ci = CIImage(cgImage: raw).oriented(forExifOrientation: orientation)
        let scale = min(1, maxSide / max(ci.extent.width, ci.extent.height))
        if scale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        // Transparent PNGs (already cut out) go onto a neutral backdrop, which Vision handles like a studio wall.
        ci = ci.composited(over: CIImage(color: CIColor(red: 0.6, green: 0.59, blue: 0.59)).cropped(to: ci.extent))
        let context = CIContext()
        guard let image = context.createCGImage(ci, from: ci.extent) else { throw fail("Couldn't decode the image.") }
        let W = CGFloat(image.width), H = CGFloat(image.height)

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        let pose = VNDetectHumanBodyPoseRequest()
        let faces = VNDetectFaceLandmarksRequest()
        do { try handler.perform([foreground, pose, faces]) } catch { throw fail("Vision couldn't process the photo: \(error.localizedDescription)") }

        guard let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox else {
            throw fail("No face found. Choose a photo where your face is clearly visible.")
        }
        guard let instances = foreground.results?.first else { throw fail("Couldn't separate you from the background.") }

        // Vision uses normalized coordinates with the origin at the bottom left; convert to pixels, top-left origin.
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: (1 - p.y) * H) }
        let faceRect = CGRect(x: face.minX * W, y: (1 - face.maxY) * H, width: face.width * W, height: face.height * H)

        let mask: CVPixelBuffer
        do { mask = try instances.generateScaledMaskForImage(forInstances: instances.allInstances, from: handler) } catch {
            throw fail("Couldn't build the cut-out mask.")
        }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask) else { throw fail("Couldn't read the cut-out mask.") }
        func maskRow(_ y: Int) -> UnsafeMutablePointer<Float32> {
            base.advanced(by: min(mh - 1, max(0, y)) * rowBytes).assumingMemoryBound(to: Float32.self)
        }

        // Bounding box of the subject, from the mask.
        var minX = mw, minY = mh, maxX = 0, maxY = 0
        for y in 0..<mh {
            let row = maskRow(y)
            for x in 0..<mw where row[x] > 0.5 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { throw fail("Couldn't find a person in the photo.") }
        let sx = W / CGFloat(mw), sy = H / CGFloat(mh)
        let padX = W * 0.03, padTop = H * 0.03
        let x0 = max(0, CGFloat(minX) * sx - padX), y0 = max(0, CGFloat(minY) * sy - padTop)
        let x1 = min(W, CGFloat(maxX) * sx + padX), y1 = min(H, CGFloat(maxY) * sy)
        let crop = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))

        // Body points (when visible) for the throat and heart.
        let joints = (try? pose.results?.first?.recognizedPoints(.all)) ?? [:]
        func joint(_ name: VNHumanBodyPoseObservation.JointName, minConfidence: Float = 0.3) -> CGPoint? {
            guard let p = joints[name], p.confidence > minConfidence else { return nil }
            return px(p.location)
        }
        let neck = joint(.neck)
        let lShoulder = joint(.leftShoulder) // the subject's left: the viewer's right
        let rShoulder = joint(.rightShoulder)

        // Vision's face box starts around the brows; the forehead is just above it.
        let forehead = CGPoint(x: faceRect.midX, y: faceRect.minY - faceRect.height * 0.08)
        let chin = CGPoint(x: faceRect.midX, y: faceRect.maxY)
        let neckPoint = neck ?? CGPoint(x: chin.x, y: chin.y + faceRect.height * 0.45)
        // The neck joint sits low, between the shoulders; the visible throat is just below the chin.
        let throat = CGPoint(x: chin.x + (neckPoint.x - chin.x) * 0.2, y: chin.y + (neckPoint.y - chin.y) * 0.2)
        // Heart: the subject's left chest, a little inside the shoulder and below it.
        let halfSpan: CGFloat = lShoulder.map { $0.x - neckPoint.x } ?? rShoulder.map { neckPoint.x - $0.x } ?? faceRect.width * 1.3
        let heart = CGPoint(x: neckPoint.x + halfSpan * 0.42, y: neckPoint.y + abs(halfSpan) * 0.5)
        let shoulderTop = [lShoulder?.y, rShoulder?.y].compactMap { $0 }.min() ?? (neckPoint.y + faceRect.height * 0.1)
        // Wrist (Apple Watch, WHOOP): of two, the higher one, since the dashboard fades the photo toward the bottom.
        let wrist = [joint(.leftWrist, minConfidence: 0.1), joint(.rightWrist, minConfidence: 0.1)].compactMap { $0 }.min { $0.y < $1.y }

        func unit(_ v: CGFloat) -> Double { Double(min(1, max(0, v))) }
        func norm(_ p: CGPoint) -> [Double] { [unit((p.x - crop.minX) / crop.width), unit((p.y - crop.minY) / crop.height)] }

        // Cut-out. Soft edge pixels mix the person and the old backdrop (a pale rim), so their color is replaced by
        // the nearest solid interior color, and the alpha edge is pulled in slightly.
        let iw = Int(W), ih = Int(H)
        var full = [UInt8](repeating: 0, count: iw * ih * 4)
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(ci, toBitmap: &full, rowBytes: iw * 4, bounds: CGRect(x: 0, y: 0, width: iw, height: ih), format: .RGBA8, colorSpace: rgb)
        var coverage = [Float](repeating: 0, count: iw * ih)
        for y in 0..<ih {
            let row = maskRow(Int(CGFloat(y) / sy))
            for x in 0..<iw { coverage[y * iw + x] = row[min(mw - 1, Int(CGFloat(x) / sx))] }
        }
        var known = coverage.map { $0 >= 0.97 }
        for _ in 0..<10 {
            var grown = known
            for y in 1..<(ih - 1) {
                for x in 1..<(iw - 1) where !known[y * iw + x] && coverage[y * iw + x] > 0.02 {
                    var r = 0, g = 0, b = 0, n = 0
                    for oy in -1...1 {
                        for ox in -1...1 where known[(y + oy) * iw + x + ox] {
                            let j = ((y + oy) * iw + x + ox) * 4
                            r += Int(full[j]); g += Int(full[j + 1]); b += Int(full[j + 2]); n += 1
                        }
                    }
                    if n > 0 {
                        let i = (y * iw + x) * 4
                        full[i] = UInt8(r / n); full[i + 1] = UInt8(g / n); full[i + 2] = UInt8(b / n)
                        grown[y * iw + x] = true
                    }
                }
            }
            known = grown
        }
        for i in 0..<(iw * ih) {
            // smoothstep(0.4, 0.97): a slightly tighter, still soft edge.
            let t = max(0, min(1, (coverage[i] - 0.4) / 0.57))
            let a = t * t * (3 - 2 * t)
            let j = i * 4
            full[j] = UInt8(Float(full[j]) * a); full[j + 1] = UInt8(Float(full[j + 1]) * a); full[j + 2] = UInt8(Float(full[j + 2]) * a)
            full[j + 3] = UInt8(a * 255)
        }
        guard let provider = CGDataProvider(data: Data(full) as CFData),
              let fullImage = CGImage(width: iw, height: ih, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: iw * 4, space: rgb,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                      decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let cut = fullImage.cropping(to: crop)
        else { throw fail("Couldn't crop the cut-out.") }

        // Silhouette outline, 100 rows: where the person starts and ends across each row (0–1 of the cut-out width).
        var outline: [[Double]] = []
        for i in 0..<100 {
            let row = maskRow(Int((crop.minY + (CGFloat(i) + 0.5) / 100 * crop.height) / sy))
            var lo = -1, hi = -1
            for x in 0..<mw where row[x] > 0.5 {
                if lo < 0 { lo = x }
                hi = x
            }
            outline.append(lo < 0 ? [1, 0] : [unit((CGFloat(lo) * sx - crop.minX) / crop.width), unit((CGFloat(hi) * sx - crop.minX) / crop.width)])
        }

        // Square avatar around the face, from the original photo, 320 px.
        let side = min(min(W, H), faceRect.height * 2.1)
        var square = CGRect(x: faceRect.midX - side / 2, y: faceRect.midY - side * 0.46, width: side, height: side)
        square.origin.x = min(max(0, square.minX), W - side)
        square.origin.y = min(max(0, square.minY), H - side)
        let ciSquare = CGRect(x: square.minX, y: H - square.maxY, width: side, height: side)
        let avatarScale = 320 / side
        let avatarCI = ci.cropped(to: ciSquare)
            .transformed(by: CGAffineTransform(translationX: -ciSquare.minX, y: -ciSquare.minY))
            .transformed(by: CGAffineTransform(scaleX: avatarScale, y: avatarScale))
        guard let avatar = context.createCGImage(avatarCI, from: avatarCI.extent) else { throw fail("Couldn't build the avatar.") }

        var dots: [String: [Double]] = ["temp": norm(forehead), "breathing": norm(throat), "heart": norm(heart)]
        if let wrist { dots["wrist"] = norm(wrist) }
        let meta: [String: Any] = [
            // The PNG's own size: the server checks they match.
            "width": cut.width,
            "height": cut.height,
            "face": [
                unit((faceRect.minX - crop.minX) / crop.width), unit((faceRect.minY - crop.minY) / crop.height),
                unit(faceRect.width / crop.width), unit(faceRect.height / crop.height),
            ],
            "shoulderY": unit((shoulderTop - crop.minY) / crop.height),
            "outline": outline,
            "dots": dots,
        ]
        guard cut.width >= 64, cut.height >= 64 else { throw fail("The person in that photo is too small. Choose a closer photo.") }
        return PhotoCutout(cutout: cut, avatar: avatar, meta: meta)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The upload body: {cutout, avatar, meta}, the PNGs base64.
    func uploadBody() throws -> Data {
        guard let c = Self.png(cutout), let a = Self.png(avatar) else { throw Failure(message: "Couldn't encode the photo.") }
        guard c.count <= 4_000_000, a.count <= 4_000_000, c.count + a.count < 3_200_000 else {
            throw Failure(message: "That photo is too large to upload. Try another one.")
        }
        return try JSONSerialization.data(withJSONObject: ["cutout": c.base64EncodedString(), "avatar": a.base64EncodedString(), "meta": meta])
    }
}

extension APIClient {
    /// POST /api/profile/photo/upload: stores a photo processed on this phone.
    func uploadPhoto(_ photo: PhotoCutout) async throws {
        _ = try await post("/profile/photo/upload", body: try photo.uploadBody())
    }
}

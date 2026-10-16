// Cuts the person out of a portrait and finds where to pin the vitals callouts.
// Runs entirely on this Mac with Apple's Vision framework; nothing is uploaded.
//
// Usage: cutout <input image> <output dir>
// Writes: cutout.png (person on transparent background, cropped to them), avatar.png (square face crop),
//         original.jpg (downscaled source, for reprocessing), meta.json (layout points, 0–1 within cutout.png).
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

func fail(_ message: String) -> Never {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: cutout <input> <output dir>") }
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
  let raw = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("Could not read that image. Use a JPEG, PNG or HEIC photo.") }

// Apply EXIF orientation and cap the size so processing stays quick.
let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
let orientation = Int32((props?[kCGImagePropertyOrientation] as? UInt32) ?? 1)
var ci = CIImage(cgImage: raw).oriented(forExifOrientation: orientation)
let scale = min(1, 1800 / max(ci.extent.width, ci.extent.height))
if scale < 1 { ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
// Transparent PNGs (already cut out) go onto a neutral backdrop, which Vision handles like a studio wall.
ci = ci.composited(over: CIImage(color: CIColor(red: 0.6, green: 0.59, blue: 0.59)).cropped(to: ci.extent))
let context = CIContext()
guard let image = context.createCGImage(ci, from: ci.extent) else { fail("Could not decode the image.") }
let W = CGFloat(image.width)
let H = CGFloat(image.height)

let handler = VNImageRequestHandler(cgImage: image, options: [:])
let foreground = VNGenerateForegroundInstanceMaskRequest()
let pose = VNDetectHumanBodyPoseRequest()
let faces = VNDetectFaceLandmarksRequest()
do { try handler.perform([foreground, pose, faces]) } catch { fail("Vision failed: \(error.localizedDescription)") }

guard let faceObs = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
  fail("No face found. Use a photo where your face is clearly visible.")
}
let face = faceObs.boundingBox
guard let instances = foreground.results?.first else { fail("Couldn't separate you from the background.") }

// Vision uses normalized coordinates with the origin at the bottom left; convert to pixels, top-left origin.
func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: (1 - p.y) * H) }
let faceRect = CGRect(x: face.minX * W, y: (1 - face.maxY) * H, width: face.width * W, height: face.height * H)

// Bounding box of the subject, from the mask.
let mask: CVPixelBuffer
do { mask = try instances.generateScaledMaskForImage(forInstances: instances.allInstances, from: handler) } catch {
  fail("Couldn't build the cut-out mask.")
}
CVPixelBufferLockBaseAddress(mask, .readOnly)
let mw = CVPixelBufferGetWidth(mask)
let mh = CVPixelBufferGetHeight(mask)
let rowBytes = CVPixelBufferGetBytesPerRow(mask)
let base = CVPixelBufferGetBaseAddress(mask)!
var minX = mw, minY = mh, maxX = 0, maxY = 0
for y in 0..<mh {
  let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
  for x in 0..<mw where row[x] > 0.5 {
    if x < minX { minX = x }
    if x > maxX { maxX = x }
    if y < minY { minY = y }
    if y > maxY { maxY = y }
  }
}
CVPixelBufferUnlockBaseAddress(mask, .readOnly)
guard maxX > minX, maxY > minY else { fail("Couldn't find a person in the photo.") }
let sx = W / CGFloat(mw)
let sy = H / CGFloat(mh)
let padX = W * 0.03
let padTop = H * 0.03
let cropX0: CGFloat = max(0, CGFloat(minX) * sx - padX)
let cropY0: CGFloat = max(0, CGFloat(minY) * sy - padTop)
let cropX1: CGFloat = min(W, CGFloat(maxX) * sx + padX)
let cropY1: CGFloat = min(H, CGFloat(maxY) * sy)
let crop = CGRect(x: cropX0, y: cropY0, width: cropX1 - cropX0, height: cropY1 - cropY0)

// Body points (when visible) for the throat and heart.
let joints = (try? pose.results?.first?.recognizedPoints(.all)) ?? [:]
func joint(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
  guard let p = joints[name], p.confidence > 0.3 else { return nil }
  return px(p.location)
}
let neck = joint(.neck)
let lShoulder = joint(.leftShoulder)  // the subject's left: the viewer's right
let rShoulder = joint(.rightShoulder)

// Vision's face box starts around the brows; the forehead is just above it.
let forehead = CGPoint(x: faceRect.midX, y: faceRect.minY - faceRect.height * 0.08)
let chin = CGPoint(x: faceRect.midX, y: faceRect.maxY)
let neckPoint = neck ?? CGPoint(x: chin.x, y: chin.y + faceRect.height * 0.45)
// The neck joint sits low, between the shoulders; the visible throat is just below the chin.
let throat = CGPoint(x: chin.x + (neckPoint.x - chin.x) * 0.2, y: chin.y + (neckPoint.y - chin.y) * 0.2)
// Heart: the subject's left chest, a little inside the shoulder and below it (above crossed arms, if any).
let halfSpan: CGFloat = lShoulder.map { $0.x - neckPoint.x } ?? rShoulder.map { neckPoint.x - $0.x } ?? faceRect.width * 1.3
let heart = CGPoint(x: neckPoint.x + halfSpan * 0.42, y: neckPoint.y + abs(halfSpan) * 0.5)
let shoulderTop = [lShoulder?.y, rShoulder?.y].compactMap { $0 }.min() ?? (neckPoint.y + faceRect.height * 0.1)

func norm(_ p: CGPoint) -> [Double] {
  [Double((p.x - crop.minX) / crop.width), Double((p.y - crop.minY) / crop.height)]
}

func writePNG(_ img: CGImage, _ name: String) {
  let url = outDir.appendingPathComponent(name)
  guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("Couldn't write \(name)")
  }
  CGImageDestinationAddImage(dest, img, nil)
  if !CGImageDestinationFinalize(dest) { fail("Couldn't write \(name)") }
}

// Cut-out, cropped to the person. Soft edge pixels are a mix of the person and the old backdrop, which
// shows as a pale rim; so their color is replaced by the nearest solid interior color ("decontaminated")
// and the alpha edge is pulled in slightly.
let iw = Int(W), ih = Int(H)
var full = [UInt8](repeating: 0, count: iw * ih * 4)
context.render(ci, toBitmap: &full, rowBytes: iw * 4, bounds: CGRect(x: 0, y: 0, width: iw, height: ih), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
var coverage = [Float](repeating: 0, count: iw * ih)
CVPixelBufferLockBaseAddress(mask, .readOnly)
for y in 0..<ih {
  let row = base.advanced(by: min(mh - 1, Int(CGFloat(y) / sy)) * rowBytes).assumingMemoryBound(to: Float32.self)
  for x in 0..<iw { coverage[y * iw + x] = row[min(mw - 1, Int(CGFloat(x) / sx))] }
}
CVPixelBufferUnlockBaseAddress(mask, .readOnly)
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
guard let fullImage = CGImage(
  width: iw, height: ih, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: iw * 4, space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(full) as CFData)!,
  decode: nil, shouldInterpolate: true, intent: .defaultIntent),
  let cut = fullImage.cropping(to: crop.integral)
else { fail("Couldn't crop the cut-out.") }
writePNG(cut, "cutout.png")

// Keep the (downscaled) original so the photo can be reprocessed when this tool improves.
if let full = context.createCGImage(ci, from: ci.extent),
  let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent("original.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
{
  CGImageDestinationAddImage(dest, full, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
  CGImageDestinationFinalize(dest)
}

// Silhouette outline, 100 rows: where the person starts and ends across each row (0–1 of the cut-out width).
// The dashboard uses it to put labels where the page shows through.
var outline: [[Double]] = []
CVPixelBufferLockBaseAddress(mask, .readOnly)
for i in 0..<100 {
  let iy = Int((crop.minY + (CGFloat(i) + 0.5) / 100 * crop.height) / sy)
  let row = base.advanced(by: min(mh - 1, iy) * rowBytes).assumingMemoryBound(to: Float32.self)
  var lo = -1, hi = -1
  for x in 0..<mw where row[x] > 0.5 {
    if lo < 0 { lo = x }
    hi = x
  }
  outline.append(lo < 0 ? [1, 0] : [Double((CGFloat(lo) * sx - crop.minX) / crop.width), Double((CGFloat(hi) * sx - crop.minX) / crop.width)])
}
CVPixelBufferUnlockBaseAddress(mask, .readOnly)

// Square avatar around the face, from the original photo.
let side = min(min(W, H), faceRect.height * 2.1)
var square = CGRect(x: faceRect.midX - side / 2, y: faceRect.midY - side * 0.46, width: side, height: side)
square.origin.x = min(max(0, square.minX), W - side)
square.origin.y = min(max(0, square.minY), H - side)
let ciSquare = CGRect(x: square.minX, y: H - square.maxY, width: side, height: side)
let avatarScale = 320 / side
let avatarCI = ci.cropped(to: ciSquare)
  .transformed(by: CGAffineTransform(translationX: -ciSquare.minX, y: -ciSquare.minY))
  .transformed(by: CGAffineTransform(scaleX: avatarScale, y: avatarScale))
guard let avatar = context.createCGImage(avatarCI, from: avatarCI.extent) else { fail("Couldn't build the avatar.") }
writePNG(avatar, "avatar.png")

let meta: [String: Any] = [
  "width": Int(crop.width.rounded()),
  "height": Int(crop.height.rounded()),
  "face": [
    Double((faceRect.minX - crop.minX) / crop.width), Double((faceRect.minY - crop.minY) / crop.height),
    Double(faceRect.width / crop.width), Double(faceRect.height / crop.height),
  ],
  "shoulderY": Double((shoulderTop - crop.minY) / crop.height),
  "outline": outline,
  "dots": ["temp": norm(forehead), "breathing": norm(throat), "heart": norm(heart)],
]
let json = try! JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
try! json.write(to: outDir.appendingPathComponent("meta.json"))
print("cut-out \(Int(crop.width))×\(Int(crop.height))")

// Cuts the person out of a portrait and finds where to pin the vitals callouts.
// Runs entirely on this Mac with Apple's Vision framework; nothing is uploaded.
//
// Usage: cutout <input image> <output dir>
// Writes: cutout.png (person on transparent background, cropped to them),
//         depth.png (estimated relief for the 3D view, white = nearest),
//         avatar.png (square face crop), meta.json (layout points, 0–1 within cutout.png).
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
let root = joint(.root)

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
_ = root

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

// ---------- depth estimate for the 3D view ----------
// A single photo has no true depth, so build a plausible relief: the silhouette is "inflated"
// (rounded at the edges, fuller in the middle), the head is an ellipsoid, the nose stands out,
// eye sockets sit back slightly, and forearms (from body pose) are raised in front of the torso.
let dw = 384
let dh = max(1, Int((CGFloat(dw) * crop.height / crop.width).rounded()))
var inside = [Bool](repeating: false, count: dw * dh)
CVPixelBufferLockBaseAddress(mask, .readOnly)
for y in 0..<dh {
  for x in 0..<dw {
    let ux: CGFloat = (CGFloat(x) + 0.5) / CGFloat(dw)
    let uy: CGFloat = (CGFloat(y) + 0.5) / CGFloat(dh)
    let ix = Int((crop.minX + ux * crop.width) / sx)
    let iy = Int((crop.minY + uy * crop.height) / sy)
    guard ix >= 0, ix < mw, iy >= 0, iy < mh else { continue }
    let row = base.advanced(by: iy * rowBytes).assumingMemoryBound(to: Float32.self)
    inside[y * dw + x] = row[ix] > 0.5
  }
}
CVPixelBufferUnlockBaseAddress(mask, .readOnly)

// Chamfer distance transform: distance (px) from each inside pixel to the silhouette edge.
let big: Float = 1e9
var dist = inside.map { $0 ? big : 0 }
for y in 0..<dh {
  for x in 0..<dw where dist[y * dw + x] > 0 {
    var d = dist[y * dw + x]
    if x > 0 { d = min(d, dist[y * dw + x - 1] + 1) }
    if y > 0 { d = min(d, dist[(y - 1) * dw + x] + 1) }
    if x > 0 && y > 0 { d = min(d, dist[(y - 1) * dw + x - 1] + 1.414) }
    if x < dw - 1 && y > 0 { d = min(d, dist[(y - 1) * dw + x + 1] + 1.414) }
    dist[y * dw + x] = d
  }
}
for y in stride(from: dh - 1, through: 0, by: -1) {
  for x in stride(from: dw - 1, through: 0, by: -1) where dist[y * dw + x] > 0 {
    var d = dist[y * dw + x]
    if x < dw - 1 { d = min(d, dist[y * dw + x + 1] + 1) }
    if y < dh - 1 { d = min(d, dist[(y + 1) * dw + x] + 1) }
    if x < dw - 1 && y < dh - 1 { d = min(d, dist[(y + 1) * dw + x + 1] + 1.414) }
    if x > 0 && y < dh - 1 { d = min(d, dist[(y + 1) * dw + x - 1] + 1.414) }
    dist[y * dw + x] = d
  }
}

// Helpers in depth-map pixels.
func dp(_ p: CGPoint) -> (Float, Float) {
  (Float((p.x - crop.minX) / crop.width) * Float(dw), Float((p.y - crop.minY) / crop.height) * Float(dh))
}
func landmark(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
  guard let pts = region?.normalizedPoints, !pts.isEmpty else { return nil }
  let c = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
  let n = CGFloat(pts.count)
  return px(CGPoint(x: face.minX + c.x / n * face.width, y: face.minY + c.y / n * face.height))
}
let (fcx, fcy) = dp(CGPoint(x: faceRect.midX, y: faceRect.midY))
let fwPx = Float(faceRect.width / crop.width) * Float(dw)
let fhPx = Float(faceRect.height / crop.height) * Float(dh)
let nose = landmark(faceObs.landmarks?.nose).map(dp)
let pupils = [landmark(faceObs.landmarks?.leftPupil), landmark(faceObs.landmarks?.rightPupil)].compactMap { $0 }.map(dp)
let arms: [((Float, Float), (Float, Float))] = [
  (joint(.leftElbow), joint(.leftWrist)), (joint(.rightElbow), joint(.rightWrist)),
].compactMap { e, w in (e != nil && w != nil) ? (dp(e!), dp(w!)) : nil }

let rim = Float(dw) * 0.16
let armR = Float(dw) * 0.075

// Forearms folded in front of the body are often hidden from pose detection, so also find them by
// skin tone: pixels below the shoulders whose color matches the face, smoothed into a soft mask.
let shoulderLine = Float((shoulderTop - crop.minY) / crop.height) * Float(dh)
var rgba = [UInt8](repeating: 0, count: dw * dh * 4)
let small = ci.cropped(to: CGRect(x: crop.minX, y: H - crop.maxY, width: crop.width, height: crop.height))
  .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -(H - crop.maxY)))
  .transformed(by: CGAffineTransform(scaleX: CGFloat(dw) / crop.width, y: CGFloat(dh) / crop.height))
context.render(small, toBitmap: &rgba, rowBytes: dw * 4, bounds: CGRect(x: 0, y: 0, width: dw, height: dh), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
// render(toBitmap:) writes rows top-down, the same orientation as the depth grid.
func pixel(_ x: Int, _ y: Int) -> (Float, Float, Float) {
  let i = (y * dw + x) * 4
  return (Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
}
var skinR: Float = 0, skinG: Float = 0, skinL: Float = 0, skinN: Float = 0
for y in Int(fcy - fhPx * 0.15)..<Int(fcy + fhPx * 0.25) {
  for x in Int(fcx - fwPx * 0.25)..<Int(fcx + fwPx * 0.25) where x >= 0 && x < dw && y >= 0 && y < dh && inside[y * dw + x] {
    let (r, g, b) = pixel(x, y)
    let sum = max(r + g + b, 1)
    skinR += r / sum; skinG += g / sum; skinL += sum; skinN += 1
  }
}
var armMask = [Float](repeating: 0, count: dw * dh)
if skinN > 0 {
  skinR /= skinN; skinG /= skinN; skinL /= skinN
  for y in 0..<dh where Float(y) > shoulderLine {
    for x in 0..<dw where inside[y * dw + x] {
      let (r, g, b) = pixel(x, y)
      let sum = max(r + g + b, 1)
      let dr: Float = r / sum - skinR
      let dg: Float = g / sum - skinG
      let close: Bool = (dr * dr + dg * dg).squareRoot() < 0.045 && sum > skinL * 0.35 && sum < skinL * 1.8
      armMask[y * dw + x] = close ? 1 : 0
    }
  }
  for _ in 0..<3 {
    var out = armMask
    for y in 0..<dh {
      for x in 0..<dw {
        var sum: Float = 0, n: Float = 0
        for oy in -3...3 {
          for ox in -3...3 {
            let xx = x + ox, yy = y + oy
            if xx >= 0, xx < dw, yy >= 0, yy < dh { sum += armMask[yy * dw + xx]; n += 1 }
          }
        }
        out[y * dw + x] = sum / n
      }
    }
    armMask = out
  }
}
if ProcessInfo.processInfo.environment["CUTOUT_DEBUG"] != nil {
  let rgbImg = CGImage(
    width: dw, height: dh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: dw * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(rgba) as CFData)!,
    decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  writePNG(rgbImg, "debug-rgba.png")
  let armBytes = armMask.map { UInt8(max(0, min(255, $0 * 255))) }
  let armImg = CGImage(
    width: dw, height: dh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: dw, space: CGColorSpaceCreateDeviceGray(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: CGDataProvider(data: Data(armBytes) as CFData)!,
    decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  writePNG(armImg, "debug-arm.png")
}
var depth = [Float](repeating: 0, count: dw * dh)
for y in 0..<dh {
  for x in 0..<dw where inside[y * dw + x] {
    let fx = Float(x), fy = Float(y)
    let t: Float = min(dist[y * dw + x] / rim, 1)
    let edge: Float = 1 - t
    var d: Float = 0.5 * (1 - edge * edge).squareRoot()

    let qx: Float = (fx - fcx) / (fwPx * 0.62)
    let qy: Float = (fy - fcy) / (fhPx * 0.78)
    let q: Float = qx * qx + qy * qy
    if q < 1 {
      // Dome that eases to zero slope at its rim, so the jaw blends into the neck instead of forming a wall.
      let rimFade: Float = q < 0.6 ? 1 : 1 - pow((q - 0.6) / 0.4, 2)
      d += 0.3 * (1 - q).squareRoot() * max(0, rimFade)
    }
    if fy > shoulderLine { d += 0.2 * armMask[y * dw + x] }
    if let (nx, ny) = nose {
      let ex: Float = fx - nx
      let ey: Float = fy - ny
      let r2: Float = (ex * ex + ey * ey) / (fwPx * fwPx * 0.018)
      d += 0.1 * exp(-r2)
    }
    for (ppx, ppy) in pupils {
      let ex: Float = fx - ppx
      let ey: Float = fy - ppy
      let r2: Float = (ex * ex + ey * ey) / (fwPx * fwPx * 0.012)
      d -= 0.035 * exp(-r2)
    }
    for (a, b) in arms {
      let vx: Float = b.0 - a.0
      let vy: Float = b.1 - a.1
      let len2: Float = max(vx * vx + vy * vy, 1)
      let proj: Float = ((fx - a.0) * vx + (fy - a.1) * vy) / len2
      let u: Float = max(0, min(1, proj))
      let ddx: Float = fx - (a.0 + u * vx)
      let ddy: Float = fy - (a.1 + u * vy)
      let r: Float = (ddx * ddx + ddy * ddy).squareRoot() / armR
      if r < 1 { d += 0.2 * (1 - r * r).squareRoot() }
    }
    depth[y * dw + x] = max(d, 0.02)
  }
}

// Soften steps (box-blur passes), then normalize to 0–1.
for _ in 0..<4 {
  var out = depth
  for y in 0..<dh {
    for x in 0..<dw {
      var sum: Float = 0, n: Float = 0
      for oy in -2...2 {
        for ox in -2...2 {
          let xx = x + ox, yy = y + oy
          if xx >= 0, xx < dw, yy >= 0, yy < dh { sum += depth[yy * dw + xx]; n += 1 }
        }
      }
      out[y * dw + x] = sum / n
    }
  }
  depth = out
}
let peak = max(depth.max() ?? 1, 0.001)
let bytes = depth.map { UInt8(max(0, min(255, $0 / peak * 255))) }
let gray = CGColorSpaceCreateDeviceGray()
let provider = CGDataProvider(data: Data(bytes) as CFData)!
guard let depthImage = CGImage(
  width: dw, height: dh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: dw, space: gray,
  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
  shouldInterpolate: true, intent: .defaultIntent)
else { fail("Couldn't build the depth map.") }
writePNG(depthImage, "depth.png")

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
print("cut-out \(Int(crop.width))×\(Int(crop.height)), depth \(dw)×\(dh), arms by pose: \(arms.count), skin samples: \(Int(skinN))")

import SwiftUI
import UIKit

/// The profile photo from the server (uploaded on the web or the Mac; the app only shows it).
/// Images are fetched with the session, cached by photo version in memory and in Caches, and graded
/// black-and-white exactly like the web's photo-tone filter.
@MainActor
enum ProfileImages {
    enum Kind: String { case avatar, cutout }

    private static var memory: [String: UIImage] = [:]

    private static func file(_ kind: Kind, _ version: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("profile", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(kind.rawValue)-\(version).png")
    }

    /// The graded image, or nil when there's no photo (or it can't be loaded right now).
    static func image(_ kind: Kind, version: String, dark: Bool) async -> UIImage? {
        let key = "\(kind.rawValue)-\(version)-\(dark ? "dark" : "light")"
        if let hit = memory[key] { return hit }
        let url = file(kind, version)
        var data = try? Data(contentsOf: url)
        if data == nil, let client = APIClient.current() {
            data = try? await client.profileImage("\(kind.rawValue).png", version: version)
            if let data {
                removeOld(kind)
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
        guard let data, let original = UIImage(data: data) else { return nil }
        let graded = await Task.detached(priority: .userInitiated) { PhotoTone.apply(to: original, dark: dark) }.value
        memory[key] = graded
        return graded
    }

    /// Signing out (or someone else signing in): nothing of this person's photo stays on the phone, in memory or in
    /// Caches. A load already on its way may still keep its image in memory; the next sign-out clears it.
    static func clear() {
        memory = [:]
        try? FileManager.default.removeItem(at: file(.avatar, "x").deletingLastPathComponent())
    }

    /// A new photo version makes the old files useless.
    private static func removeOld(_ kind: Kind) {
        let dir = file(kind, "x").deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("\(kind.rawValue)-") {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

/// Black-and-white grade from src/components/Figure.tsx: saturate 0, then levels to 0.2–0.97 (light) or
/// 0.06–0.93 (dark), on straight (unpremultiplied) sRGB, so transparent edges of the cut-out stay clean.
enum PhotoTone {
    static func apply(to image: UIImage, dark: Bool) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let (lo, hi): (Double, Double) = dark ? (0.06, 0.93) : (0.2, 0.97)
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Levels lookup per luminance byte; luminance weights match feColorMatrix saturate(0).
        let table = (0...255).map { UInt8(((lo + Double($0) / 255 * (hi - lo)) * 255).rounded()) }
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3])
            if a == 0 { continue }
            let r = Double(pixels[i]) * 255 / a, g = Double(pixels[i + 1]) * 255 / a, b = Double(pixels[i + 2]) * 255 / a
            let lum = min(255, max(0, Int((0.2126 * r + 0.7152 * g + 0.0722 * b).rounded())))
            let v = UInt8((Double(table[lum]) * a / 255).rounded()) // premultiply again
            pixels[i] = v
            pixels[i + 1] = v
            pixels[i + 2] = v
        }
        guard let out = ctx.makeImage() else { return image }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }
}

/// The round avatar from the web's top bar (.avatar): photo, or the name's initial in sage on pale sage, in a thin white
/// ring with the pill's soft shadow.
struct Avatar: View {
    let photo: PhotoMeta?
    let name: String?
    var size: CGFloat = 42
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.accentSoft
                // 12px in the web's 32px circle.
                Text(initial).font(.app(fixedSize: size * 0.375, weight: .medium)).foregroundStyle(Palette.accentSoftInk)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .padding(2)
        .background(Circle().fill(Palette.surface))
        .tokenShadow(.pill, in: Circle())
        .task(id: "\(photo?.versionKey ?? "none")-\(scheme == .dark)") {
            image = nil
            guard let photo else { return }
            image = await ProfileImages.image(.avatar, version: photo.versionKey, dark: scheme == .dark)
        }
        .accessibilityLabel(name.map { "Profile photo of \($0)" } ?? "Profile photo")
    }

    /// The web's initialOf: the name's first letter, or a middle dot without one.
    private var initial: String { (name?.trimmingCharacters(in: .whitespaces).first).map { String($0).uppercased() } ?? "·" }
}

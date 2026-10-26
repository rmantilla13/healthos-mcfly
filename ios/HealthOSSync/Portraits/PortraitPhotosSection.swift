import SwiftUI

/// Profile's "Your portrait photos" (src/pages/Profile.tsx PortraitPhotos): a card that opens in place, with the
/// portrait studio (reference photos, portraits made from them) and "Use a photo as is". Profile places it; what it
/// shows is built here. Until then it counts the files, as the web's line under the title does, and says the rest is
/// coming. Hidden on a server older than portraits.
struct PortraitPhotosSection: View {
    @Environment(Dashboard.self) private var dashboard
    /// Unknown until read; missing on a server without portraits.
    @State private var list: Availability.Read<PortraitList> = .unknown

    var body: some View {
        if list != .missing {
            Collapsible("Your portrait photos", meta: meta, systemImage: "camera") {
                Text("Your portrait studio is coming in this build.").foregroundStyle(Palette.ink2)
            }
            .task(id: dashboard.generation) {
                do {
                    list = try await dashboard.portraits().map { .known($0) } ?? .missing
                } catch {
                    // Offline: the count waits for the next look.
                }
            }
        }
    }

    /// "3 files", as the web counts them; nothing until the list is read.
    private var meta: String? {
        guard let n = list.value?.portraits.count else { return nil }
        return "\(n) \(n == 1 ? "file" : "files")"
    }
}

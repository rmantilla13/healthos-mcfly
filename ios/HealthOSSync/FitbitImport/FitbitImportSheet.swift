import SwiftUI

/// Importing a Fitbit or Google Health Takeout export (src/pages/FitbitImport.tsx), opened from Integrations' "Import
/// Fitbit data" (slice M presents it). Slice O builds it here. `onClose` is the web's: the presenter's own close, or
/// the sheet's dismiss.
struct FitbitImportSheet: View {
    var onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) { self.onClose = onClose }

    var body: some View {
        SheetScaffold(eyebrow: "Integrations", title: "Import Fitbit data", onClose: onClose) {
            Text("Importing a Fitbit export is coming in this build.").font(.app(.subheadline)).foregroundStyle(Palette.ink2)
        }
    }
}

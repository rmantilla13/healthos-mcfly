import SwiftUI

/// The Sleep page (src/pages/Sleep.tsx), under More. Until it's built here, the charts the Trends tab had for Sleep.
/// `tab` is the web's ?tab= (stages, trends, coaching), for the page to open on.
struct SleepScreen: View {
    var tab: String?

    var body: some View { TrendsPage(.sleep) }
}

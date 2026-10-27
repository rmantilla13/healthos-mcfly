import SwiftUI

// iPhone Duo: the bars (§1 O3 and O8, rule P8). Every iOS 27.0 toolbar API the app uses goes through here.

extension AppTab {
    /// More: "square.grid.2x2" in a vertical bar, else "ellipsis" (O3: tabs and toolbar items share one column there,
    /// and the ellipsis is the system's overflow menu). The other tabs keep their symbol. AppShell reads it (F4).
    func symbol(verticalBar: Bool) -> String {
        switch self {
        case .more, .settings: verticalBar ? "square.grid.2x2" : "ellipsis"
        default: symbol
        }
    }
}

/// Which toolbar items give way first when the vertical bar runs out of room (O8): low before normal before high.
enum DuoPriority: Sendable {
    case high, normal, low
}

extension ToolbarContent {
    /// visibilityPriority on iOS 27.0+ (the overflow order, O8); nothing before.
    @ToolbarContentBuilder
    func duoVisibilityPriority(_ priority: DuoPriority) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(priority.system)
        } else {
            self
        }
    }
}

@available(iOS 27.0, *)
private extension DuoPriority {
    var system: ToolbarItemVisibilityPriority {
        switch self {
        case .high: .high
        case .normal: .automatic
        case .low: .low
        }
    }
}

extension ToolbarItemPlacement {
    /// A page's prominent action: .topBarPinnedTrailing on iOS 27.0+, .topBarTrailing before.
    static var duoProminent: ToolbarItemPlacement {
        if #available(iOS 27.0, *) { .topBarPinnedTrailing } else { .topBarTrailing }
    }
}

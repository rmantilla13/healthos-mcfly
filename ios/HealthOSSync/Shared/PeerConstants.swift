import Foundation

// Anonymous peer comparisons (shared/peers.ts, server/peers.ts): which quarter of a group of people your age who also
// take part your 30-day average sits in, for the same measurement from the same source. Only aggregates ever leave the
// server, and only for a group of at least `minOthers` other people. Onboarding's third step (slice A) and Profile's
// age-group comparison (slice F) both use these; PeerConstantsTests reads them from shared/peers.ts.
enum Peers {
    /// The fewest other people in a group before anything is shown.
    static let minOthers = 20
    /// The fewest recorded days, yours and each of theirs, in the window.
    static let minDays = 7
    /// The window an average covers.
    static let windowDays = 30
    /// Comparisons are for adults: under 18, taking part can't be turned on.
    static let minAge = 18

    /// The age groups (AGE_BANDS).
    static let ageBands: [(label: String, min: Int, max: Int)] = [
        ("18–29", 18, 29), ("30–39", 30, 39), ("40–49", 40, 49), ("50–59", 50, 59), ("60–69", 60, 69), ("70+", 70, 200),
    ]

    /// The age group's label for an age; nil without an age or under 18 (ageBand).
    static func ageBand(_ age: Int?) -> String? {
        guard let age else { return nil }
        return ageBands.first { age >= $0.min && age <= $0.max }?.label
    }

    /// One measurement from one source, since devices measure differently (PEER_PAIRS). `digits` is how a value is
    /// rounded and shown.
    struct Pair: Equatable {
        let metric: String
        let source: String
        let label: String
        let unit: String
        let digits: Int
    }

    static let pairs: [Pair] = [
        Pair(metric: "resting_hr", source: "whoop", label: "Resting heart rate", unit: "bpm", digits: 0),
        Pair(metric: "resting_hr", source: "apple", label: "Resting heart rate", unit: "bpm", digits: 0),
        Pair(metric: "hrv_rmssd", source: "whoop", label: "Heart rate variability", unit: "ms", digits: 0),
        Pair(metric: "hrv_sdnn", source: "apple", label: "Heart rate variability", unit: "ms", digits: 0),
        Pair(metric: "sleep_hours", source: "whoop", label: "Sleep", unit: "h", digits: 1),
        Pair(metric: "sleep_hours", source: "apple", label: "Sleep", unit: "h", digits: 1),
        Pair(metric: "steps", source: "apple", label: "Steps", unit: "steps", digits: 0),
        Pair(metric: "spo2", source: "whoop", label: "Blood oxygen", unit: "%", digits: 1),
        Pair(metric: "spo2", source: "apple", label: "Blood oxygen", unit: "%", digits: 1),
        Pair(metric: "resp_rate", source: "whoop", label: "Respiratory rate", unit: "breaths/min", digits: 1),
        Pair(metric: "recovery", source: "whoop", label: "Recovery", unit: "%", digits: 0),
    ]

    /// A pair's label and unit; the source "demo" (the local preview's sample) uses the metric's first pair (peerPair).
    static func pair(metric: String, source: String) -> Pair? {
        pairs.first { $0.metric == metric && $0.source == source } ?? pairs.first { $0.metric == metric }
    }

    /// Where your average sits among the group's quarters (PeerBand), from the rounded figures in the same answer only.
    enum Band: String, CaseIterable {
        case belowP25 = "below_p25", p25Median = "p25_median", medianP75 = "median_p75", aboveP75 = "above_p75"
    }

    /// Equal to a quartile counts inside the middle half, and at the median in its lower quarter, so each label stays
    /// true when quartiles round to the same value (peerBand).
    static func band(you: Double, p25: Double, median: Double, p75: Double) -> Band {
        if you < p25 { return .belowP25 }
        if you > p75 { return .aboveP75 }
        return you <= median ? .p25Median : .medianP75
    }
}

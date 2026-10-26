import Foundation
import Observation

/// What one open sheet has loaded and which range it shows (the web sheet's useApi and its two effects): the last
/// answer of any range stays up while another range loads, unless it's empty; an answer that's current for the range
/// on screen may move the range (SheetRanges); a server without the sheet hands over to the phone for good. Memory only,
/// and it goes with the sheet.
@MainActor
@Observable
final class MetricSheetModel {
    /// The server's sheet for a range; nil when it has none for this metric.
    typealias FromServer = (MetricRange) async throws -> MetricSheetData?
    /// The sheet built on the phone from what the server has (MetricSheetFallback).
    typealias OnPhone = (MetricRange) async throws -> MetricSheetData

    let key: MetricKey
    private(set) var ranges: SheetRanges
    /// The last sheet that arrived, of any range.
    private(set) var data: MetricSheetData?
    /// `data` is the answer for the range on screen as it is now, not a copy kept from before.
    private(set) var current = false
    private(set) var loading = false
    private(set) var error: String?
    /// The server has no sheet for this metric: built on the phone from then on.
    private(set) var onPhone = false
    /// This sheet's answers by range, so going back to a range shows it at once; read again after a sync.
    private var answers: [MetricRange: MetricSheetData] = [:]
    private var answersFor: Int?

    init(key: MetricKey, range: MetricRange?) {
        self.key = key
        ranges = SheetRanges(key: key, asked: range)
    }

    var range: MetricRange { ranges.range }

    /// The sheet on screen: not one about to move to a longer range, nor another range's empty one.
    var shown: MetricSheetData? {
        guard let data, data.key == key, data.shows(asked: ranges.range, picked: ranges.picked) else { return nil }
        return data
    }

    /// Why a range the person didn't press is the pressed one.
    var note: String? { ranges.note(shown: shown) }

    func pick(_ range: MetricRange) { ranges.pick(range) }

    /// Loads the range on screen. `generation` is the dashboard's: after new data every range is read again, and what's on
    /// screen stays up until it is. A load the range moved on from, or one cancelled, changes nothing.
    func load(generation: Int, fromServer: FromServer, onPhone phone: OnPhone) async {
        let range = ranges.range
        if answersFor != generation {
            answers = [:]
            answersFor = generation
        } else if let hit = answers[range] {
            data = hit
            current = true
            error = nil
            loading = false
            ranges.heard(hit, current: true)
            return
        }
        current = false
        loading = true
        error = nil
        do {
            var sheet: MetricSheetData?
            if !onPhone {
                sheet = try await fromServer(range)
                if sheet == nil { onPhone = true }
            }
            let answer: MetricSheetData
            if let sheet { answer = sheet } else { answer = try await phone(range) }
            guard !Task.isCancelled, range == ranges.range else { return }
            answers[range] = answer
            data = answer
            current = true
            loading = false
            ranges.heard(answer, current: true)
        } catch {
            guard !Task.isCancelled, !APIClient.isCancellation(error), range == ranges.range else { return }
            self.error = Self.message(error)
            loading = false
        }
    }

    /// The server's own words, as the web shows them after "Couldn't load this: ".
    static func message(_ error: Error) -> String {
        switch error as? APIError {
        case .server(_, let message)?: message.isEmpty ? SheetWords.somethingWrong : message
        case .misconfigured(let message)?, .network(let message)?: message
        case .signInRequired?: APIError.signInRequired.localizedDescription
        case nil: error is DecodingError ? SheetWords.somethingWrong : error.localizedDescription
        }
    }
}

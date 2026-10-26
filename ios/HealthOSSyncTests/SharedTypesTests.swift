import SwiftUI
import XCTest
@testable import HealthOSSync

/// The pieces more than one page builds with can be made from another file: if one goes back to private, this file
/// stops compiling. Plus the one change that came with opening them up, the workout sources' names.
@MainActor
final class SharedTypesTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try XCTUnwrap(try? Data(contentsOf: url), "missing fixture \(name).json")
    }

    func testEachCanBeMadeFromAnotherFile() throws {
        let workout = try XCTUnwrap(try JSONDecoder().decode([Workout].self, from: fixture("workouts")).first)
        let day = try JSONDecoder().decode(DayData.self, from: fixture("day"))
        let steps = try XCTUnwrap(day.steps)
        let food = try XCTUnwrap(try JSONDecoder().decode(NutritionData.self, from: fixture("nutrition-all")).days.first)

        // Vitals and Body: a day by hour, workouts, a page's trend metrics, Home's tappable card.
        _ = HoursChart(metric: .steps, series: steps, reading: DayReading(metric: .steps, series: steps, data: day))
        _ = HoursChart(metric: .heart, series: steps, reading: DayReading(metric: .heart, series: steps, data: day), compact: true, label: "Heart rate")
        _ = WorkoutsCard(days: 30)
        _ = WorkoutListRow(workout: workout, units: .metric)
        _ = TrendsLoader(metrics: ["resting_hr"], days: 30) { _ in EmptyView() }
        _ = MetricCard(title: "Resting heart rate", route: .vitals) { Text("58 bpm") }
        // Home's food card, from Nutrition's.
        _ = FoodEnergyCard(week: [], target: nil, today: food.date)
        _ = FoodProteinCard(week: [], before: [], target: 120, today: food.date)
        _ = MacroDonut(parts: FoodMath.parts(food), energy: nil)
        _ = FoodDayCard(day: food, today: food.date, mode: .all)
        _ = FoodChartCard(title: "Protein", points: [], start: food.date, end: food.date, target: nil, format: { "\($0) g" })
        // The camera and barcode reader, for onboarding, portraits, lab reports and Nutrition.
        _ = CameraPicker { _ in }
        _ = BarcodeScanner { _ in }
        // "Use a photo as is", and Profile's sections for slices to fill.
        _ = PhotoSection()
        let preview: (PhotoCutout, @escaping () async -> Void) -> PhotoPreview = PhotoPreview.init
        _ = preview
        _ = PeersSection()
        _ = PortraitPhotosSection()
    }

    func testWorkoutSourcesInTheWebsWords() {
        XCTAssertEqual(WorkoutListRow.sourceName("apple"), "Apple Health")
        XCTAssertEqual(WorkoutListRow.sourceName("whoop"), "WHOOP")
        XCTAssertEqual(WorkoutListRow.sourceName("apple+whoop"), "Apple Health and WHOOP")
        XCTAssertEqual(WorkoutListRow.sourceName("fitbit"), "Fitbit", "not the id")
        XCTAssertEqual(WorkoutListRow.sourceName("garmin"), "garmin", "one this app doesn't know shows as sent")
    }
}

import XCTest
@testable import HealthOSSync

/// The Bluetooth Heart Rate Measurement format (what a WHOOP strap sends with Heart Rate Broadcast on), and
/// how the live screen keeps its last few minutes.
final class HeartRateMeasurementTests: XCTestCase {
    private func parse(_ bytes: [UInt8]) -> HeartRateMeasurement? { HeartRateMeasurement.parse(Data(bytes)) }

    func testEightBitHeartRate() {
        XCTAssertEqual(parse([0x00, 72]), HeartRateMeasurement(bpm: 72, contact: .unsupported, energyExpended: nil, rrIntervals: []))
    }

    func testSixteenBitHeartRateIsLittleEndian() {
        // 0x012C = 300: a value only the 16-bit format can hold.
        XCTAssertEqual(parse([0x01, 0x2C, 0x01])?.bpm, 300)
        XCTAssertEqual(parse([0x01, 0x48, 0x00])?.bpm, 72)
    }

    func testSkinContact() {
        XCTAssertEqual(parse([0x06, 64])?.contact, .detected)
        XCTAssertEqual(parse([0x04, 0])?.contact, .notDetected)
        XCTAssertEqual(parse([0x02, 64])?.contact, .unsupported, "the detected bit means nothing unless contact is supported")
    }

    func testEnergyExpendedComesBeforeTheIntervals() {
        // Flags: energy + RR. 70 bpm, 0x0123 kJ, then RR 1024 (1 s) and 512 (0.5 s).
        let m = parse([0x18, 70, 0x23, 0x01, 0x00, 0x04, 0x00, 0x02])
        XCTAssertEqual(m?.bpm, 70)
        XCTAssertEqual(m?.energyExpended, 0x0123)
        XCTAssertEqual(m?.rrIntervals, [1.0, 0.5])
    }

    func testIntervalsWithSixteenBitHeartRateAndAStrayByte() {
        let m = parse([0x11, 0x50, 0x00, 0x33, 0x03, 0x99])
        XCTAssertEqual(m?.bpm, 80)
        XCTAssertEqual(m?.rrIntervals, [Double(0x0333) / 1024], "the odd trailing byte is ignored")
        XCTAssertNil(m?.energyExpended)
    }

    func testShortOrEmptyDataIsRejected() {
        XCTAssertNil(parse([]))
        XCTAssertNil(parse([0x00]), "no heart rate byte")
        XCTAssertNil(parse([0x01, 0x48]), "16-bit format with one byte")
        XCTAssertNil(parse([0x08, 70, 0x23]), "energy announced but cut short")
    }

    private func reading(_ bpm: Int, _ contact: HeartRateMeasurement.Contact) -> HeartRateMeasurement {
        HeartRateMeasurement(bpm: bpm, contact: contact, energyExpended: nil, rrIntervals: [])
    }

    func testTheLiveViewKeepsFiveMinutes() {
        let live = LiveHeartRate()
        let start = Date(timeIntervalSince1970: 1_000_000)
        live.record(reading(60, .detected), at: start)
        live.record(reading(75, .unsupported), at: start.addingTimeInterval(301))
        XCTAssertFalse(live.noContact)
        XCTAssertEqual(live.beats.map(\.bpm), [75], "older than five minutes is dropped")
        XCTAssertEqual(live.latest?.bpm, 75)
    }

    func testAStrapOffTheSkinIsNotCharted() {
        let live = LiveHeartRate()
        let start = Date(timeIntervalSince1970: 1_000_000)
        live.record(reading(60, .detected), at: start)
        // A slipped optical strap still sends a plausible number; the contact flag is what says it's wrong.
        live.record(reading(72, .notDetected), at: start.addingTimeInterval(1))
        XCTAssertTrue(live.noContact)
        live.record(reading(0, .unsupported), at: start.addingTimeInterval(2))
        XCTAssertTrue(live.noContact, "zero means no reading, whatever the flags say")
        XCTAssertEqual(live.beats.map(\.bpm), [60])
        XCTAssertEqual(parse([0x04, 64]), HeartRateMeasurement(bpm: 64, contact: .notDetected, energyExpended: nil, rrIntervals: []))
        // Back on the skin: the warning clears and readings are charted again.
        live.record(reading(80, .detected), at: start.addingTimeInterval(3))
        XCTAssertFalse(live.noContact)
        XCTAssertEqual(live.beats.map(\.bpm), [60, 80])
    }

    func testStrapsStayInTheOrderTheyWereHeard() {
        let a = LiveHeartRate.Strap(id: UUID(), name: "WHOOP 4C1234", rssi: -80)
        let b = LiveHeartRate.Strap(id: UUID(), name: "Polar H10", rssi: -50)
        var list = LiveHeartRate.merge([], a)
        list = LiveHeartRate.merge(list, b)
        // Heard again, closer: only its signal changes, so the rows don't move under a finger.
        list = LiveHeartRate.merge(list, LiveHeartRate.Strap(id: a.id, name: a.name, rssi: -40))
        XCTAssertEqual(list.map(\.name), ["WHOOP 4C1234", "Polar H10"])
        XCTAssertEqual(list.first?.rssi, -40)
        // A connected strap reports no signal: the last known one is kept.
        list = LiveHeartRate.merge(list, LiveHeartRate.Strap(id: b.id, name: b.name, rssi: nil, connected: true))
        XCTAssertEqual(list.last?.rssi, -50)
        XCTAssertEqual(list.last?.connected, true)
        XCTAssertEqual(list.first?.connected, false, "an unknown signal isn't 'connected to this iPhone'")
    }

    func testGapsSplitTheLine() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let beats = [0, 1, 2, 30, 31].map { LiveHeartRate.Beat(at: start.addingTimeInterval(Double($0)), bpm: 70) }
        XCTAssertEqual(LiveHeartRate.runs(beats).map { $0.beats.count }, [3, 2])
        XCTAssertEqual(LiveHeartRate.runs([]), [])
    }

    func testTheWatchCardReadsOnlyAppleWatchHeartRate() {
        XCTAssertTrue(LiveHeartRate.isFromWatch(productType: "Watch7,3"))
        XCTAssertFalse(LiveHeartRate.isFromWatch(productType: "iPhone17,1"), "WHOOP's or another app's copy, written from the phone")
        XCTAssertFalse(LiveHeartRate.isFromWatch(productType: nil))
        XCTAssertTrue(LiveHeartRate.isFromWatch(productType: "Watch7,3", deviceModel: "Watch"))
        XCTAssertFalse(LiveHeartRate.isFromWatch(productType: "Watch7,3", deviceModel: "Polar H10"), "a chest strap paired to the Watch")
    }
}

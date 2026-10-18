import Foundation

/// One reading from a Bluetooth heart rate sensor: the standard Heart Rate Measurement characteristic (0x2A37).
/// A WHOOP strap sends these while Heart Rate Broadcast is on; chest straps and many watches send the same.
struct HeartRateMeasurement: Equatable {
    enum Contact: Equatable {
        /// The sensor doesn't say.
        case unsupported
        /// It says it isn't touching skin: the beats per minute mean nothing.
        case notDetected
        case detected
    }

    let bpm: Int
    let contact: Contact
    /// Kilojoules since the sensor last reset it, when it reports that.
    let energyExpended: Int?
    /// Beat-to-beat intervals in seconds, oldest first.
    let rrIntervals: [Double]

    /// Flags byte, then the heart rate (8 or 16 bits), then optional energy (16 bits) and RR intervals
    /// (16 bits each, in 1/1024 s), all little-endian. nil when the bytes are shorter than the flags announce.
    static func parse(_ data: Data) -> HeartRateMeasurement? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        var index = 1
        func uint8() -> Int? {
            guard index < bytes.count else { return nil }
            index += 1
            return Int(bytes[index - 1])
        }
        func uint16() -> Int? {
            guard index + 1 < bytes.count else { return nil }
            index += 2
            return Int(bytes[index - 2]) | Int(bytes[index - 1]) << 8
        }

        guard let bpm = flags & 0x01 == 0 ? uint8() : uint16() else { return nil }
        let contact: Contact = flags & 0x04 == 0 ? .unsupported : flags & 0x02 == 0 ? .notDetected : .detected
        var energy: Int?
        if flags & 0x08 != 0 {
            guard let value = uint16() else { return nil }
            energy = value
        }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            // Whatever is left, two bytes at a time; a stray odd byte is ignored.
            while let value = uint16() { rr.append(Double(value) / 1024) }
        }
        return HeartRateMeasurement(bpm: bpm, contact: contact, energyExpended: energy, rrIntervals: rr)
    }
}

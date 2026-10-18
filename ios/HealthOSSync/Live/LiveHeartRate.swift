import CoreBluetooth
import HealthKit
import Observation

/// Heart rate while the live screen is open, from two places:
/// - a Bluetooth heart rate sensor: a WHOOP strap with Heart Rate Broadcast on (or a chest strap), about once
///   a second, for as long as the screen is open and the app is in front;
/// - Apple Health: the newest heart rate an Apple Watch has synced to this iPhone, which arrives every few minutes.
///
/// Which strap: the one the person picked last time connects by itself. Otherwise every strap heard is listed
/// and the person taps theirs; nothing is guessed, because in a gym or a family home the nearest strap may be
/// someone else's. Nothing is stored or sent anywhere except that choice (the strap's Bluetooth identifier).
/// All callbacks land on the main queue.
@Observable
final class LiveHeartRate: NSObject {
    enum SensorState: Equatable {
        /// Not started, stopped, or Bluetooth is restarting.
        case off
        case bluetoothOff
        case unauthorized
        /// No Bluetooth LE here (the simulator).
        case unsupported
        /// Listening; `straps` are the ones heard so far, for the person to pick from.
        case choosing(straps: [Strap], since: Date)
        case connecting(String, since: Date)
        case streaming(String)
        case reconnecting(String, since: Date)
        /// It wouldn't connect (`connected` false), or connected but won't send heart rate.
        case failed(String, connected: Bool)
    }

    struct Strap: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// Signal strength in dBm (closer is higher); nil when not known.
        var rssi: Int?
        /// Already connected to this iPhone (another app holds it), so it isn't advertising.
        var connected = false
    }

    /// Straps in the order they were first heard, so a row never moves under a finger; a strap heard again
    /// only updates its signal.
    static func merge(_ straps: [Strap], _ strap: Strap) -> [Strap] {
        var out = straps
        if let i = out.firstIndex(where: { $0.id == strap.id }) {
            if strap.rssi != nil { out[i].rssi = strap.rssi }
            if strap.connected { out[i].connected = true }
        } else {
            out.append(strap)
        }
        return out
    }

    struct Beat: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let bpm: Int
    }

    /// An unbroken stretch of readings, drawn as one line.
    struct Run: Identifiable, Equatable {
        let id: Int
        var beats: [Beat]
    }

    /// Readings split wherever more than five seconds went by without one, so a gap isn't drawn as a line.
    static func runs(_ beats: [Beat]) -> [Run] {
        var out: [Run] = []
        for beat in beats {
            if let last = out.last?.beats.last, beat.at.timeIntervalSince(last.at) <= 5 { out[out.count - 1].beats.append(beat) } else { out.append(Run(id: out.count, beats: [beat])) }
        }
        return out
    }

    struct WatchReading: Equatable {
        let bpm: Int
        let at: Date
        let source: String
    }

    /// How much of the stream the chart shows.
    static let window: TimeInterval = 5 * 60
    /// How far back to look for the newest Apple Watch reading.
    static let watchLookback: TimeInterval = 6 * 3600

    private(set) var sensor: SensorState = .off
    private(set) var beats: [Beat] = []
    /// The sensor says it isn't touching skin (a loose or removed strap).
    private(set) var noContact = false
    private(set) var watch: WatchReading?
    private(set) var watchLoaded = false
    /// healthOS hasn't asked for Health access yet, so there's nothing it may read.
    private(set) var watchNeedsAccess = false
    /// A made-up stream, in the simulator, which has no Bluetooth.
    private(set) var demo = false

    var latest: Beat? { beats.last }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    /// The strap most recently connected to, kept after a failure so "Try again" has something to try.
    @ObservationIgnored private var lastTried: CBPeripheral?
    /// Every strap heard while choosing, by identifier, to connect to the one picked.
    @ObservationIgnored private var heard: [UUID: CBPeripheral] = [:]
    /// While choosing: straps another app connects in the meantime stop advertising, so look for those too.
    @ObservationIgnored private var lookAgain: Timer?
    @ObservationIgnored private var query: HKAnchoredObjectQuery?
    /// Which Health query is current, so a stopped one's late answer is ignored.
    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var running = false
    /// "Choose another strap" was asked for: until something is picked, the remembered strap is only listed, even
    /// after leaving the app or Bluetooth restarting. A new sheet starts without it.
    @ObservationIgnored private var skipRemembered = false
    /// The strap the person tapped; it becomes the remembered one once it actually sends a reading.
    @ObservationIgnored private var picked: UUID?
    /// One disconnect this app caused itself (Try again), which mustn't read as the strap being lost.
    @ObservationIgnored private var expectedDisconnect: UUID?

    private static let service = CBUUID(string: "180D")
    private static let measurement = CBUUID(string: "2A37")
    private static let rememberedKey = "liveHeartRateSensor"

    /// The strap the person picked. Only its identifier, which this iPhone gave it.
    private var remembered: UUID? {
        get { UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.rememberedKey) }
    }

    func start() {
        guard !running else { return }
        running = true
        // A fresh start: a gap in the stream isn't drawn as if nothing happened in between.
        beats = []
        noContact = false
        #if targetEnvironment(simulator)
        startDemo()
        #else
        // The state callback starts listening once Bluetooth is ready (and asks for permission the first time).
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        startWatch()
    }

    func stop() {
        guard running else { return }
        running = false
        let on = central?.state == .poweredOn
        if on, let peripheral { central?.cancelPeripheralConnection(peripheral) }
        if on { central?.stopScan() }
        lookAgain?.invalidate()
        lookAgain = nil
        central = nil
        peripheral = nil
        lastTried = nil
        picked = nil
        expectedDisconnect = nil
        heard = [:]
        stopWatch()
        demoTask?.cancel()
        demoTask = nil
        sensor = .off
    }

    /// The person tapped their strap: connect, and (once it sends a reading) use it from now on.
    func pick(_ id: UUID) {
        guard running, peripheral == nil, let p = heard[id] else { return }
        picked = id
        skipRemembered = false
        connect(p)
    }

    /// Let go of this strap and list the ones nearby again. The remembered one only changes when another is picked.
    func chooseAnother() {
        guard running, let central, central.state == .poweredOn else { return }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        beats = []
        skipRemembered = true
        listen()
    }

    /// Ask the same strap again (it was slow, out of range, or wouldn't send).
    func tryAgain() {
        guard running, let central, central.state == .poweredOn else { return }
        guard let p = peripheral ?? lastTried else { return listen() }
        // Connected but silent: drop the link and set it up again (that disconnect is ours, not a loss).
        // Not connected yet: just ask again.
        if p.state == .connected {
            expectedDisconnect = p.identifier
            central.cancelPeripheralConnection(p)
        }
        connect(p)
    }

    /// One reading in: kept for the chart unless the sensor says it isn't on skin.
    func record(_ m: HeartRateMeasurement, at now: Date = Date()) {
        noContact = m.contact == .notDetected || m.bpm <= 0
        if !noContact { beats.append(Beat(at: now, bpm: m.bpm)) }
        beats.removeAll { now.timeIntervalSince($0.at) > Self.window }
    }

    // MARK: Apple Health

    /// Heart rate measured by an Apple Watch, not copies other apps (WHOOP, Oura, this one) wrote to Health.
    static func isFromWatch(productType: String?, deviceModel: String? = nil) -> Bool {
        productType?.hasPrefix("Watch") == true && (deviceModel == nil || deviceModel == "Watch")
    }

    func restartWatch() {
        stopWatch()
        watchNeedsAccess = false
        watchLoaded = false
        if running { startWatch() }
    }

    private func stopWatch() {
        if let query { Health.shared.store.stop(query) }
        query = nil
        queryGeneration += 1
    }

    private func startWatch() {
        let generation = queryGeneration
        let predicate = HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-Self.watchLookback), end: nil, options: [])
        let handle: ([HKSample]?, Error?) -> Void = { [weak self] samples, error in
            let newest = (samples as? [HKQuantitySample])?
                .filter { Self.isFromWatch(productType: $0.sourceRevision.productType, deviceModel: $0.device?.model) }
                .max { $0.endDate < $1.endDate }
            let reading = newest.map {
                WatchReading(bpm: Int($0.quantity.doubleValue(for: .count().unitDivided(by: .minute())).rounded()), at: $0.endDate, source: $0.sourceRevision.source.name)
            }
            let notAsked = (error as? HKError)?.code == .errorAuthorizationNotDetermined
            DispatchQueue.main.async {
                guard let self, self.running, generation == self.queryGeneration else { return }
                self.watchLoaded = true
                if notAsked { self.watchNeedsAccess = true }
                if let reading, reading.at > self.watch?.at ?? .distantPast { self.watch = reading }
            }
        }
        // The first answer is everything from the last few hours; after that, each batch the Watch syncs.
        let q = HKAnchoredObjectQuery(type: HKQuantityType(.heartRate), predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { _, samples, _, _, error in
            handle(samples, error)
        }
        q.updateHandler = { _, samples, _, _, error in handle(samples, error) }
        query = q
        Health.shared.store.execute(q)
    }

    // MARK: Simulator

    private func startDemo() {
        demo = true
        sensor = .streaming("Simulator demo")
        demoTask = Task { @MainActor [weak self] in
            var t = 0.0
            while !Task.isCancelled {
                let bpm = 72 + 8 * sin(t / 9) + Double.random(in: -2...2)
                self?.record(HeartRateMeasurement(bpm: Int(bpm.rounded()), contact: .detected, energyExpended: nil, rrIntervals: []))
                t += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: Bluetooth

extension LiveHeartRate: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard running else { return }
        // Below powered on, scanning has stopped and connections are gone; below powered off the peripheral
        // objects are no longer valid. Start over when it's back.
        if central.state != .poweredOn {
            lookAgain?.invalidate()
            lookAgain = nil
            peripheral = nil
            lastTried = nil
            heard = [:]
        }
        switch central.state {
        case .poweredOn: listen()
        case .poweredOff: sensor = .bluetoothOff
        case .unauthorized: sensor = .unauthorized
        case .unsupported: sensor = .unsupported
        default: sensor = .off // resetting or not known yet: another update follows
        }
    }

    /// Scan, and list what's heard. Straps connected to this iPhone already (the WHOOP app holds one, and then
    /// it doesn't advertise) are listed too, now and every couple of seconds. The remembered strap connects by
    /// itself, unless the person just asked to choose another.
    private func listen() {
        guard let central else { return }
        heard = [:]
        sensor = .choosing(straps: [], since: Date())
        central.scanForPeripherals(withServices: [Self.service], options: nil)
        addConnected()
        lookAgain?.invalidate()
        lookAgain = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.addConnected() }
    }

    private func addConnected() {
        guard running, peripheral == nil, let central else { return }
        for p in central.retrieveConnectedPeripherals(withServices: [Self.service]) { hear(p, rssi: nil, connected: true) }
    }

    private func hear(_ p: CBPeripheral, rssi: Int?, connected: Bool = false) {
        guard running, peripheral == nil, case .choosing(let straps, let since) = sensor else { return }
        if !skipRemembered, p.identifier == remembered { return connect(p) }
        heard[p.identifier] = p
        sensor = .choosing(straps: Self.merge(straps, Strap(id: p.identifier, name: Self.name(p), rssi: rssi, connected: connected)), since: since)
    }

    private static func name(_ p: CBPeripheral) -> String { p.name ?? "Heart rate sensor" }

    private func connect(_ p: CBPeripheral) {
        lookAgain?.invalidate()
        lookAgain = nil
        central?.stopScan()
        // A different strap from the last one: its readings start a new chart.
        if p.identifier != lastTried?.identifier { beats = [] }
        peripheral = p
        lastTried = p
        p.delegate = self
        sensor = .connecting(Self.name(p), since: Date())
        central?.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 127 means the strength wasn't available.
        hear(peripheral, rssi: RSSI.intValue == 127 ? nil : RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Usually distance or a busy radio: ask again. A broken pairing or refused encryption won't fix itself.
        let code = (error as? CBError)?.code
        if code == .peerRemovedPairingInformation || code == .encryptionTimedOut { fail(peripheral, connected: false) } else { reconnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // The disconnect from our own Try again: the new request is already out, so nothing was lost.
        if expectedDisconnect == peripheral.identifier {
            expectedDisconnect = nil
            if peripheral === self.peripheral { central.connect(peripheral, options: nil) }
            return
        }
        reconnect(peripheral)
    }

    /// iOS keeps a connection request open until the strap is back in range, so one request is enough.
    private func reconnect(_ p: CBPeripheral) {
        guard running, p === peripheral, let central, central.state == .poweredOn else { return }
        if case .reconnecting = sensor {} else { sensor = .reconnecting(Self.name(p), since: Date()) }
        central.connect(p, options: nil)
    }

    /// Errors that mean the link dropped, not that the strap can't give heart rate.
    private static func transient(_ error: Error?) -> Bool {
        guard let code = (error as? CBError)?.code else { return false }
        return code == .peripheralDisconnected || code == .connectionTimeout || code == .notConnected
    }

    /// It won't connect or won't give heart rate: let go of it and say so. "Try again" and "Choose another strap" are offered.
    private func fail(_ p: CBPeripheral, connected: Bool = true) {
        guard running, p === peripheral else { return }
        peripheral = nil
        central?.cancelPeripheralConnection(p)
        sensor = .failed(Self.name(p), connected: connected)
    }

    /// A setup step failed: a dropped link is retried, anything else is a strap without heart rate.
    private func setupError(_ p: CBPeripheral, _ error: Error?) {
        if Self.transient(error) { reconnect(p) } else { fail(p) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return setupError(peripheral, error) }
        peripheral.discoverCharacteristics([Self.measurement], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.measurement }) else { return setupError(peripheral, error) }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil || !characteristic.isNotifying { setupError(peripheral, error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running, peripheral === self.peripheral, characteristic.uuid == Self.measurement, let data = characteristic.value,
              let m = HeartRateMeasurement.parse(data) else { return }
        // A strap the person tapped is theirs once it actually streams.
        if picked == peripheral.identifier {
            remembered = peripheral.identifier
            picked = nil
        }
        sensor = .streaming(Self.name(peripheral))
        record(m)
    }
}

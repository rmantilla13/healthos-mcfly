import Charts
import SwiftUI
import UIKit

/// Live heart rate, opened from the Heart reading on Today. Streams only while it's open and the app is in front.
struct LiveHeartRateView: View {
    @State private var live = LiveHeartRate()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SensorCard(live: live)
                    WatchCard(live: live)
                }
                .padding(16)
            }
            .background(Palette.page)
            .navigationTitle("Live heart rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
        // Bluetooth stops in the background; pick the strap up again on return.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { live.start() } else if phase == .background { live.stop() }
        }
    }
}

// MARK: - WHOOP (or any Bluetooth heart rate sensor)

private struct SensorCard: View {
    let live: LiveHeartRate

    /// How long a connection may take, or a stream may go quiet, before the card explains what to check.
    private static let patience: TimeInterval = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(deviceName ?? "WHOOP", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
            }
            // Ticks every second: the reading ages, the chart scrolls, and help appears when things go quiet.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 12) { content(now: context.date) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("The strap's live readings stay on this iPhone. They aren't saved or sent to healthOS.")
                .font(.caption)
                .foregroundStyle(Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(.pink)
    }

    private var deviceName: String? {
        switch live.sensor {
        case .connecting(let name, _), .streaming(let name), .reconnecting(let name, _), .failed(let name, _): name
        default: nil
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch live.sensor {
        case .off:
            ProgressView()
        case .bluetoothOff:
            Help(title: "Bluetooth is off", text: "Turn on Bluetooth in Control Center to connect to your WHOOP.")
        case .unauthorized:
            Help(title: "Bluetooth isn't allowed", text: "Let healthOS use Bluetooth to connect to your WHOOP's heart rate broadcast.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.bordered)
        case .unsupported:
            Help(title: "No Bluetooth here", text: "This device can't connect to a Bluetooth heart rate sensor.")
        case .choosing(let straps, let since):
            if straps.isEmpty {
                Waiting(text: "Looking for your WHOOP…")
            } else {
                Help(title: "Tap the strap you're wearing", text: "healthOS remembers it and connects to it by itself next time.")
                ForEach(straps) { strap in
                    Button { live.pick(strap.id) } label: {
                        HStack {
                            Text(strap.name).foregroundStyle(Palette.ink)
                            Spacer()
                            Text(Self.whereIs(strap)).font(.footnote).foregroundStyle(Palette.ink3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel([strap.name, Self.whereIs(strap)].filter { !$0.isEmpty }.joined(separator: ", "))
                }
            }
            // Give a strap that's already broadcasting a moment to show up before explaining.
            if now.timeIntervalSince(since) > 6 { BroadcastHelp(heading: straps.isEmpty ? "Turn on Heart Rate Broadcast" : "Don't see yours?") }
        case .connecting(let name, let since):
            Waiting(text: "Connecting to \(name)…")
            if now.timeIntervalSince(since) > Self.patience {
                BroadcastHelp(heading: "Taking a while?")
                actions
            }
        case .reconnecting(let name, let since):
            Help(title: "Lost \(name)", text: "Reconnecting when it's back in range. Keep the strap near this iPhone.")
            chart(now: now)
            if now.timeIntervalSince(since) > Self.patience { actions }
        case .failed(let name, let connected):
            if connected {
                Help(title: "No heart rate from \(name)", text: "It connected but didn't send a heart rate. If it's your WHOOP, check Heart Rate Broadcast is on, then try again.")
            } else {
                Help(title: "Couldn't connect to \(name)", text: "It may need pairing again: forget it under Bluetooth in Settings, then try again.")
            }
            actions
        case .streaming(let name):
            reading(name: name, now: now)
        }
    }

    @ViewBuilder
    private func reading(name: String, now: Date) -> some View {
        let quiet = live.latest.map { now.timeIntervalSince($0.at) } ?? .infinity
        if live.noContact {
            Help(title: "\(name) isn't reading your pulse", text: "Make sure the strap sits snugly on your wrist or arm.")
        } else if let beat = live.latest, quiet <= 10 {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.title2)
                    .foregroundStyle(Palette.vitalHeart)
                    .symbolEffect(.pulse, options: .repeating.speed(Double(beat.bpm) / 60), isActive: true)
                    .accessibilityHidden(true)
                BigValue(value: "\(beat.bpm)", unit: "bpm", size: 48)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heart rate \(beat.bpm) beats per minute")
            Text("Live from \(name), about once a second.").font(.footnote).foregroundStyle(Palette.ink3)
        } else {
            Waiting(text: "Waiting for \(name)…")
            if quiet > Self.patience * 2 { BroadcastHelp() }
        }
        chart(now: now)
        if !live.demo {
            Button("Choose another strap") { live.chooseAnother() }.font(.footnote)
        }
    }

    /// Telling straps apart: roughly how close, or that it's already connected to this iPhone.
    static func whereIs(_ strap: LiveHeartRate.Strap) -> String {
        if strap.connected { return "connected to this iPhone" }
        guard let rssi = strap.rssi else { return "" }
        return rssi > -60 ? "very close" : rssi > -75 ? "nearby" : "farther away"
    }

    /// When a strap is slow, gone or silent: ask it again, or pick a different one.
    private var actions: some View {
        HStack(spacing: 10) {
            Button("Try again") { live.tryAgain() }.buttonStyle(.bordered)
            Button("Choose another strap") { live.chooseAnother() }.buttonStyle(.bordered)
        }
        .font(.footnote)
    }

    /// The last five minutes, on a fixed five-minute axis, with gaps left as gaps.
    @ViewBuilder
    private func chart(now: Date) -> some View {
        let start = now.addingTimeInterval(-LiveHeartRate.window)
        let shown = live.beats.filter { $0.at >= start }
        if shown.count > 1 {
            let runs = LiveHeartRate.runs(shown)
            let values = shown.map(\.bpm)
            let low = (values.min() ?? 60) - 5
            let high = (values.max() ?? 100) + 5
            Chart(runs) { run in
                // A lone reading between gaps is a dot; a stretch of them is a line.
                if run.beats.count == 1, let beat = run.beats.first {
                    PointMark(x: .value("Time", beat.at), y: .value("bpm", beat.bpm))
                        .foregroundStyle(Palette.vitalHeart)
                        .symbolSize(20)
                } else {
                    ForEach(run.beats) { beat in
                        LineMark(x: .value("Time", beat.at), y: .value("bpm", beat.bpm), series: .value("Run", run.id))
                            .foregroundStyle(Palette.vitalHeart)
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartXScale(domain: start...now)
            .chartYScale(domain: low...high)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Palette.grid)
                    AxisValueLabel().foregroundStyle(Palette.ink3)
                }
            }
            .frame(height: 120)
            .accessibilityLabel("Heart rate over the last five minutes, from \(values.min() ?? 0) to \(values.max() ?? 0) beats per minute")
            Text("Last \(Int(LiveHeartRate.window / 60)) minutes").font(.caption).foregroundStyle(Palette.ink3)
        }
    }
}

private struct Waiting: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(Palette.ink2)
        }
    }
}

/// How to turn on the broadcast, for when a strap doesn't show up or answer.
private struct BroadcastHelp: View {
    var heading = "Turn on Heart Rate Broadcast"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
            Text("In the WHOOP app, open your strap's device settings and turn on heart rate broadcasting. Keep the strap close to this iPhone.")
            Text("Any Bluetooth heart rate strap works too. Broadcasting uses a little more of the strap's battery.")
        }
        .font(.footnote)
        .foregroundStyle(Palette.ink2)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Help: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
            Text(text).font(.footnote).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Apple Watch (via Apple Health)

private struct WatchCard: View {
    let live: LiveHeartRate
    @Environment(AppModel.self) private var sync: AppModel?
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Apple Watch", systemImage: "applewatch")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            if let w = live.watch {
                // Ages in place without waiting for the next reading.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        BigValue(value: "\(w.bpm)", unit: "bpm")
                        Text("\(Self.age(of: w.at, now: context.date)) · from \(w.source)").font(.footnote).foregroundStyle(Palette.ink2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                Text("Your Watch sends heart rate to this iPhone every few minutes, so this is the newest reading, not a live one. New readings appear here as they arrive.")
                    .font(.footnote)
                    .foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if live.watchNeedsAccess {
                Help(title: "Health access needed", text: "healthOS hasn't asked to read Apple Health on this iPhone yet.")
                Button("Allow Health access") {
                    asking = true
                    Task {
                        if let sync { await sync.requestHealthAccess() } else { try? await Health.shared.requestAuthorization() }
                        asking = false
                        live.restartWatch()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(asking)
            } else if live.watchLoaded {
                Help(title: "No recent heart rate", text: "Nothing from an Apple Watch in the last \(Int(LiveHeartRate.watchLookback / 3600)) hours. If you wear one, check healthOS may read heart rate in the Health app.")
            } else {
                ProgressView()
            }
        }
        .card()
        // The app's own sync can ask for Health access while this is open: read again once it has.
        .onChange(of: sync?.healthRequested) { _, asked in
            if asked == true, live.watchNeedsAccess { live.restartWatch() }
        }
    }

    static func age(of date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

import SwiftUI

// Add a weight, body fat or lean body mass by hand (AddEntrySheet.tsx, POST /api/body/entries): the value in your units,
// its day (today by default; never a day that hasn't happened, by your own time zone, which the server checks), an
// optional time, where it's from and a note. Under the form, that metric's entries, each of which can be deleted after
// asking, since a delete can't be undone. While demo data shows, saving is off. Entries aren't written to Apple Health,
// as the web doesn't: the sync would bring them back as Apple Health's.

struct BodyEntrySheet: View {
    let metric: BodyMetric
    /// The person's today, from the server.
    let today: String
    let demo: Bool
    /// After a save or a delete: the dashboard reads the day again, so the cards and charts show it.
    let changed: () -> Void
    let close: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.bodyReads) private var reads
    @State private var value = ""
    @State private var date = Date()
    @State private var hasTime = false
    @State private var time = Date()
    @State private var method: BodyMethod?
    @State private var note = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        let unit = metric.unit(dashboard.units)
        SheetScaffold(eyebrow: "Body", title: metric.addTitle, size: .sm, onClose: close) {
            VStack(alignment: .leading, spacing: 18) {
                if demo {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Turn off demo data on Integrations to add your own measurements.")
                            .font(.app(.footnote)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                        Button("Open Integrations") {
                            close()
                            dashboard.open(.integrations)
                        }
                        .font(.app(.footnote, weight: .semibold)).foregroundStyle(Palette.accentText).buttonStyle(.plain).frame(minHeight: 44)
                    }
                    .padding(14)
                    .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("body.entry.demo")
                }
                valueField(unit)
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker(selection: $date, in: ...BodyEntryDates.date(today), displayedComponents: .date) {
                        Text("Date").font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                    }
                    .accessibilityIdentifier("body.entry.date")
                    Toggle(isOn: $hasTime.animation()) {
                        HStack(spacing: 6) {
                            Text("Time").font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                            Text("optional").font(.app(.caption)).foregroundStyle(Palette.ink3)
                        }
                    }
                    .accessibilityIdentifier("body.entry.hasTime")
                    if hasTime {
                        DatePicker(selection: $time, displayedComponents: .hourAndMinute) {
                            Text("At").font(.app(.subheadline)).foregroundStyle(Palette.ink2)
                        }
                        .accessibilityIdentifier("body.entry.time")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Where it's from").font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                        Text("optional").font(.app(.caption)).foregroundStyle(Palette.ink3)
                    }
                    BodyFlow(spacing: 8, lineSpacing: 8) {
                        ForEach(BodyMethod.allCases, id: \.self) { m in
                            ChipToggle(m.label, isOn: Binding(get: { method == m }, set: { method = $0 ? m : nil }))
                                .accessibilityIdentifier("body.entry.from.\(m.rawValue)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Where it's from")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Note").font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
                        Text("optional").font(.app(.caption)).foregroundStyle(Palette.ink3)
                    }
                    TextField("", text: $note)
                        .font(.app(.body))
                        .textInputAutocapitalization(.sentences)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(Palette.border))
                        .onChange(of: note) { _, n in if n.count > BodyMath.noteMax { note = String(n.prefix(BodyMath.noteMax)) } }
                        .accessibilityLabel("Note, optional")
                        .accessibilityIdentifier("body.entry.note")
                }
                if let error {
                    Text(error).font(.app(.footnote)).foregroundStyle(Palette.critical).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("body.entry.error")
                }
                if !demo {
                    BodyEntryList(metric: metric, today: today, changed: changed)
                }
            }
        } footer: {
            Button("Cancel", action: close).buttonStyle(.quietPill)
            Button(busy ? "Saving…" : "Save entry") { Task { await save(unit: unit) } }
                .buttonStyle(.accentPill)
                .disabled(busy || demo)
                .accessibilityIdentifier("body.entry.save")
        }
        .keyboardDismissal()
        .onAppear { date = BodyEntryDates.date(today) }
    }

    private func valueField(_ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.label).font(.app(.subheadline, weight: .medium)).foregroundStyle(Palette.ink)
            HStack(spacing: 8) {
                TextField("", text: $value)
                    .font(.app(.body))
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .accessibilityLabel(metric.label)
                    .accessibilityHint(metric.hint(unit: unit))
                    .accessibilityIdentifier("body.entry.value")
                Text(unit).font(.app(.subheadline)).foregroundStyle(Palette.ink2).accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(error == nil ? Palette.border : Palette.critical))
            Text(metric.hint(unit: unit)).font(.app(.caption)).foregroundStyle(Palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(unit: String) async {
        guard !busy else { return }
        guard let n = BodyMath.value(value) else {
            error = "Enter your \(metric.name) as a number."
            return
        }
        busy = true
        error = nil
        let body = BodyMath.entryBody(metric: metric, value: n, unit: unit, date: Day.of(date), time: hasTime ? BodyEntryDates.clock(time) : nil,
                                      method: method, note: note)
        do {
            try await reads.add(dashboard, body)
            changed()
            close()
        } catch {
            // Signed out or someone else's now: the sheet is going, and nothing is said.
            if let words = BodyModel.words(error) { self.error = BodyMath.message(error).isEmpty ? words : BodyMath.message(error) }
            busy = false
        }
    }
}

enum BodyEntryDates {
    /// The day as a date for the picker: its local midnight (today when it can't be read).
    static func date(_ day: String) -> Date { Day.localMidnight(day) ?? Date() }

    /// "07:30" for the time picked, on the phone's clock.
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// The metric's entries, newest first (RecentEntries): eight until "Show all", each with Delete entry, asked again
/// first ("Delete this entry?" Delete / Keep), since it can't be undone.
struct BodyEntryList: View {
    let metric: BodyMetric
    let today: String
    let changed: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.bodyReads) private var reads
    @State private var read: BodyRead<BodyEntries?> = .loading
    @State private var all = false
    @State private var asking: String?
    @State private var failed: String?
    @State private var version = 0

    var body: some View {
        Group {
            switch read {
            case .loading: EmptyView()
            case .failed: Text("Couldn't load your entries.").font(.app(.footnote)).foregroundStyle(Palette.ink3)
            case .done(let data):
                // A server without entries has nothing to list.
                if let entries = data?.entries, !entries.isEmpty { list(entries) }
            }
        }
        .task(id: version) {
            let asked = dashboard.session
            do {
                let data = try await reads.entries(dashboard, metric)
                if dashboard.session == asked { read = .done(data) }
            } catch {
                if dashboard.session == asked, BodyModel.words(error) != nil { read = .failed(BodyModel.words(error)!) }
            }
        }
    }

    private func list(_ entries: [BodyEntry]) -> some View {
        let unit = metric.unit(dashboard.units)
        let shown = all ? entries : Array(entries.prefix(BodyMath.recent))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Your entries").font(.app(.headline, weight: .medium)).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            ForEach(shown) { e in
                let when = BodyMath.when(e, today: today)
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 12) {
                            entryText(e, unit: unit)
                            Spacer(minLength: 0)
                            if asking != e.id { deleteButton(e, when: when) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            entryText(e, unit: unit)
                            if asking != e.id { deleteButton(e, when: when) }
                        }
                    }
                    if asking == e.id {
                        BodyFlow(spacing: 10, lineSpacing: 8) {
                            Text("Delete this entry?").font(.app(.footnote)).foregroundStyle(Palette.ink).accessibilityHidden(true)
                            Button("Delete", role: .destructive) { Task { await remove(e) } }
                                .buttonStyle(.quietPill).foregroundStyle(Palette.critical)
                                .accessibilityLabel("Delete the entry from \(when)")
                                .accessibilityIdentifier("body.entry.confirmDelete")
                            Button("Keep") { asking = nil }.buttonStyle(.quietPill)
                                .accessibilityIdentifier("body.entry.keep")
                        }
                    }
                }
                .padding(.vertical, 4)
                Divider().overlay(Palette.border)
            }
            if let failed { Text(failed).font(.app(.footnote)).foregroundStyle(Palette.critical).fixedSize(horizontal: false, vertical: true) }
            if entries.count > BodyMath.recent {
                Button(all ? "Show fewer" : "Show all \(entries.count)") { all.toggle() }.buttonStyle(.quietPill)
                    .accessibilityIdentifier("body.entry.showAll")
            }
        }
        .padding(.top, 8)
        .accessibilityIdentifier("body.entry.list")
    }

    private func entryText(_ e: BodyEntry, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(BodyMetric.show(metric.inUnits(e.value, dashboard.units), unit: unit)).font(.app(.subheadline, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(BodyMath.detail(e, today: today)).font(.app(.caption)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func deleteButton(_ e: BodyEntry, when: String) -> some View {
        Button("Delete entry") {
            failed = nil
            asking = e.id
        }
        .buttonStyle(.quietPill)
        .accessibilityLabel("Delete entry from \(when)")
        .accessibilityIdentifier("body.entry.delete")
    }

    private func remove(_ e: BodyEntry) async {
        failed = nil
        do {
            try await reads.delete(dashboard, e.id)
            asking = nil
            version += 1
            changed()
        } catch {
            if BodyModel.words(error) != nil { failed = BodyMath.message(error) }
        }
    }
}

import PhotosUI
import SwiftUI
import VisionKit

// The Nutrition tab's Log (src/pages/FoodLog.tsx): a day's entries, each editable, and one sheet to add more: a food
// database search, a barcode, McFly's estimate from a photo or a few words (a draft to check and save, never saved on
// its own), or amounts typed in. Same tone as the rest of Nutrition: no score, no "remaining", no colour for more or less.

/// The Log tab: its own List, so swipe to delete works (a List can't sit inside the other tabs' ScrollView).
struct FoodLogTab<Header: View>: View {
    @ViewBuilder let header: () -> Header
    @Environment(Dashboard.self) private var dashboard
    @State private var log: FoodLog?
    @State private var error: String?
    @State private var day: String?
    @State private var adding = false
    @State private var editing: FoodEntry?
    @State private var reviewing = false
    /// McFly's note on its latest estimate, shown while it's reviewed (it isn't stored with the drafts).
    @State private var note = ""
    @State private var counted: NutritionData?
    @State private var rowError: String?

    var body: some View {
        List {
            // Where the other tabs put it (16 pt in, as far down), and clear of the section's rounded corner, which
            // clips a row's content even with a clear background.
            Section { header() }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 16, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
            if let log {
                content(log)
            } else if let error {
                Section { Text("Couldn't load your food log: \(error)").font(.footnote).foregroundStyle(Palette.ink2) }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }.listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Palette.page)
        .refreshable { await reload() }
        .task(id: "\(dashboard.generation)|\(dashboard.nutritionMode?.rawValue ?? "off")") { await reload() }
        .sheet(isPresented: $adding, onDismiss: askHealth) {
            if let log {
                FoodAddSheet(log: log, date: selectedDay(log), units: dashboard.units, onChange: { await reload() }) { estimateNote in
                    note = estimateNote
                    adding = false
                    reviewing = true
                }
            }
        }
        .sheet(item: $editing) { entry in
            FoodEditSheet(entry: entry, mode: log?.mode ?? .none, units: dashboard.units) { await reload() }
        }
        .sheet(isPresented: $reviewing, onDismiss: askHealth) {
            if let log, !log.drafts.isEmpty {
                FoodReviewSheet(drafts: log.drafts, batch: log.draftBatch ?? "", note: note, mode: log.mode, units: dashboard.units) { await reload() }
            }
        }
    }

    /// Health's write question, held back while a sheet was up.
    private func askHealth() {
        Task { await dashboard.askFoodHealthIfPending() }
    }

    private func selectedDay(_ log: FoodLog) -> String {
        if let day, day >= log.start, day <= log.today { return day }
        return log.today
    }

    @ViewBuilder
    private func content(_ log: FoodLog) -> some View {
        let selected = selectedDay(log)
        let entries = log.entries.filter { $0.date == selected }
        let units = dashboard.units
        Section {
            FoodDayHeader(day: selected, today: log.today, canBack: selected > log.start, canForward: selected < log.today) { step in
                day = Day.add(selected, step)
            }
            .listRowBackground(Palette.surface)
            Button { adding = true } label: {
                Label("Add food", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Palette.surface)
            .accessibilityIdentifier("addFood")
            if !log.drafts.isEmpty {
                Button { reviewing = true } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("McFly's estimate to check").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text("For \(log.drafts[0].time). Nothing counts until you save it.").font(.caption).foregroundStyle(Palette.ink3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowBackground(Tone.blue.background)
            }
            if entries.isEmpty {
                Text("Nothing logged in healthOS on this day.").font(.footnote).foregroundStyle(Palette.ink3)
                    .listRowBackground(Palette.surface)
            }
            ForEach(entries) { e in
                FoodEntryRow(entry: e, units: units)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = e }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { delete(e) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .listRowBackground(Palette.surface)
                    .accessibilityHint("Opens it to edit. Swipe to delete.")
            }
            if let rowError {
                Text(rowError).font(.footnote).foregroundStyle(.red).listRowBackground(Palette.surface)
            }
        }
        if !entries.isEmpty {
            Section {
                let sum = FoodText.amounts(FoodText.addUp(entries), units: units)
                if log.mode != .none, !sum.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Logged here").font(.caption).foregroundStyle(Palette.ink3)
                        Text(sum).font(.footnote).foregroundStyle(Palette.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let app = counted?.days.first(where: { $0.date == selected })?.app, app != "healthOS" {
                    Text("This day's totals on the other tabs come from \(app), which logged more. Two apps are never added together, because apps copy each other's food through Apple Health. You can choose which app counts on the web, on the Macros tab.")
                        .font(.caption).foregroundStyle(Palette.ink3)
                }
            }
            .listRowBackground(Palette.surface)
        }
        Section {
            Text(log.mode == .none
                 ? "You chose to see no amounts, so what you log here isn't saved to Apple Health."
                 : "Food you log on this iPhone is saved to Apple Health too, with only the amounts you see. healthOS doesn't count it twice.")
                .font(.caption).foregroundStyle(Palette.ink3)
        }
        .listRowBackground(Color.clear)
    }

    private func reload() async {
        do {
            log = try await dashboard.loadFoodLog(days: 14)
            error = nil
            counted = try? await dashboard.nutrition(days: 14)
        } catch {
            guard !Task.isCancelled, !APIClient.isCancellation(error) else { return }
            self.error = error.foodMessage
        }
    }

    private func delete(_ e: FoodEntry) {
        rowError = nil
        Task {
            do {
                try await dashboard.deleteFood(e)
            } catch {
                rowError = error.foodMessage
            }
            await reload()
        }
    }
}

private struct FoodDayHeader: View {
    let day: String
    let today: String
    let canBack: Bool
    let canForward: Bool
    let step: (Int) -> Void

    var body: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .disabled(!canBack)
                .accessibilityLabel("Day before")
            Spacer()
            VStack(spacing: 1) {
                Text(Fmt.relativeDay(day, today: today)).font(.headline).foregroundStyle(Palette.ink)
                Text(Fmt.day(day, "EEEEMMMMd")).font(.caption).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .disabled(!canForward)
                .accessibilityLabel("Day after")
        }
        .buttonStyle(.borderless)
    }
}

private struct FoodEntryRow: View {
    let entry: FoodEntry
    let units: Units

    var body: some View {
        let line = FoodText.amounts(entry.values, units: units)
        HStack(alignment: .top, spacing: 12) {
            Text(entry.time).font(.caption.monospacedDigit()).foregroundStyle(Palette.ink3).frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                let detail = FoodText.detail(entry)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Palette.ink3) }
                if !line.isEmpty { Text(line).font(.caption).foregroundStyle(Palette.ink2) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editing

/// Name, time, how many, and the amounts this person sees. Only what changed is sent.
private struct FoodEditSheet: View {
    let entry: FoodEntry
    let mode: NutritionMode
    let units: Units
    let onDone: () async -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var time: Date
    @State private var quantity: String
    @State private var typed: [String: String]
    @State private var busy = false
    @State private var error: String?

    init(entry: FoodEntry, mode: NutritionMode, units: Units, onDone: @escaping () async -> Void) {
        self.entry = entry
        self.mode = mode
        self.units = units
        self.onDone = onDone
        _name = State(initialValue: entry.name)
        _time = State(initialValue: FoodBody.date(forTime: entry.time))
        _quantity = State(initialValue: FoodText.quantityText(entry.quantity))
        _typed = State(initialValue: Dictionary(uniqueKeysWithValues: FoodField.typed(mode).map { ($0.key, $0.text(entry.values[$0.key], units: units)) }))
    }

    var body: some View {
        let fields = FoodField.typed(mode)
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).accessibilityIdentifier("editName")
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    LabeledContent("How many\(entry.portion.isEmpty ? "" : " (\(entry.portion))")") {
                        TextField("1", text: $quantity).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                            .accessibilityIdentifier("editQuantity")
                    }
                } footer: {
                    Text([FoodText.detail(entry), FoodText.amounts(entry.values, units: units)].filter { !$0.isEmpty }.joined(separator: "\n"))
                }
                if !fields.isEmpty {
                    Section {
                        ForEach(fields) { f in
                            LabeledContent("\(f.label) (\(f.unit(units)))") {
                                TextField("–", text: Binding(get: { typed[f.key] ?? "" }, set: { typed[f.key] = $0 }))
                                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                                    .accessibilityLabel("\(f.label) in \(f.unit(units))")
                            }
                        }
                    } footer: {
                        Text("Amounts are for the whole entry. Changing only how many scales them all.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissal()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : "Save") { save(fields) }.disabled(busy).accessibilityIdentifier("saveEntry")
                }
            }
        }
    }

    private func save(_ fields: [FoodField]) {
        do {
            let t = FoodBody.time(time)
            guard let body = try FoodBody.patch(entry, name: name, time: t, quantity: foodQuantity(quantity), typed: typed, fields: fields, units: units) else {
                return dismiss()
            }
            busy = true
            error = nil
            Task {
                do {
                    try await dashboard.changeFood(entry, body)
                    await onDone()
                    dismiss()
                } catch {
                    self.error = error.foodMessage
                }
                busy = false
            }
        } catch {
            self.error = error.foodMessage
        }
    }
}

// MARK: - Adding

enum FoodAddMode: String, CaseIterable, Identifiable {
    case search = "Search", scan = "Scan", estimate = "Photo or words", quick = "Quick add"
    var id: String { rawValue }

    /// No estimate where McFly can't (can.estimate), no quick add where amounts are hidden.
    static func available(_ log: FoodLog) -> [FoodAddMode] {
        allCases.filter { m in
            switch m {
            case .estimate: log.can.estimate
            case .quick: log.mode != .none
            default: true
            }
        }
    }
}

/// When an entry is for: the day on screen, at a time (today defaults to now, a past day to midday).
struct FoodWhen {
    let date: String
    var time: Date
    var timeText: String { FoodBody.time(time) }
}

private struct FoodAddSheet: View {
    let log: FoodLog
    let date: String
    let units: Units
    let onChange: () async -> Void
    /// McFly made drafts: close this sheet and review them, with its note.
    let onDrafts: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: FoodAddMode = .search
    @State private var when: FoodWhen

    init(log: FoodLog, date: String, units: Units, onChange: @escaping () async -> Void, onDrafts: @escaping (String) -> Void) {
        self.log = log
        self.date = date
        self.units = units
        self.onChange = onChange
        self.onDrafts = onDrafts
        _when = State(initialValue: FoodWhen(date: date, time: date == log.today ? Date() : FoodBody.date(forTime: "12:00")))
    }

    var body: some View {
        let modes = FoodAddMode.available(log)
        let current = modes.contains(mode) ? mode : .search
        NavigationStack {
            Form {
                Section {
                    Picker("How", selection: $mode) {
                        ForEach(modes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("addModes")
                    DatePicker("\(Fmt.relativeDay(date, today: log.today)) at", selection: $when.time, displayedComponents: .hourAndMinute)
                }
                switch current {
                case .search: FoodSearchSection(when: when, units: units, usda: log.can.usda, quick: modes.contains(.quick), onChange: onChange) { mode = .quick }
                case .scan: FoodScanSection(when: when, units: units, quick: modes.contains(.quick), onChange: onChange) { mode = .quick }
                case .estimate: FoodEstimateSection(when: when, onDrafts: onDrafts, onChange: onChange)
                case .quick: FoodQuickSection(when: when, mode: log.mode, units: units, onChange: onChange)
                }
            }
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissal()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("addDone") } }
            .navigationDestination(for: FoodPick.self) { pick in
                FoodPickView(pick: pick, when: when, units: units, onChange: onChange)
            }
        }
    }
}

/// A database food chosen from a search or a barcode, to pick its portion and how many.
struct FoodPick: Hashable {
    let food: FoodResult
    let barcode: Bool

    static func == (a: FoodPick, b: FoodPick) -> Bool { a.food.ref == b.food.ref && a.barcode == b.barcode }
    func hash(into h: inout Hasher) { h.combine(food.ref); h.combine(barcode) }
}

private struct FoodResultsList: View {
    let found: FoodSearch
    let barcode: Bool
    let quick: Bool
    let toQuick: () -> Void

    var body: some View {
        ForEach(found.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(Palette.ink3) }
        if found.results.isEmpty {
            Text(barcode ? "That barcode isn’t in USDA FoodData Central or Open Food Facts." + (quick ? " Quick add from the label instead." : "")
                         : "Nothing found. Try fewer or other words.")
                .font(.footnote).foregroundStyle(Palette.ink2)
            if barcode, quick { Button("Quick add from the label", action: toQuick) }
        } else {
            ForEach(found.results) { r in
                NavigationLink(value: FoodPick(food: r, barcode: barcode)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                        Text([r.brand, r.source == "usda" ? "USDA" : "Open Food Facts"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Palette.ink3)
                    }
                }
            }
        }
    }
}

private struct FoodSearchSection: View {
    let when: FoodWhen
    let units: Units
    let usda: Bool
    let quick: Bool
    let onChange: () async -> Void
    let toQuick: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var query = ""
    @State private var found: FoodSearch?
    @State private var searched = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            HStack {
                TextField("Search foods, or type a barcode", text: $query)
                    .submitLabel(.search)
                    .onSubmit(search)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("foodQuery")
                Button(busy ? "Searching…" : "Search", action: search)
                    .disabled(busy || query.trimmingCharacters(in: .whitespaces).count < 2)
                    .accessibilityIdentifier("foodSearch")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } footer: {
            Text("Foods from \(usda ? "USDA FoodData Central and " : "")Open Food Facts. healthOS's server sends them your search, never your name.")
        }
        if let found {
            Section { FoodResultsList(found: found, barcode: isBarcode(searched), quick: quick, toQuick: toQuick) }
        }
    }

    private func isBarcode(_ s: String) -> Bool { s.range(of: #"^[\d\s-]{8,}$"#, options: .regularExpression) != nil }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        busy = true
        error = nil
        Task {
            do {
                found = try await dashboard.searchFoods(q)
                searched = q
            } catch {
                self.error = error.foodMessage
            }
            busy = false
        }
    }
}

/// A barcode: the camera where the device has it, or typed (also when the camera is off).
private struct FoodScanSection: View {
    let when: FoodWhen
    let units: Units
    let quick: Bool
    let onChange: () async -> Void
    let toQuick: () -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var code = ""
    @State private var found: FoodSearch?
    @State private var busy = false
    @State private var error: String?
    @State private var lastScanned: String?

    private var canScan: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        Section {
            if canScan {
                BarcodeScanner { scanned in
                    guard scanned != lastScanned, !busy else { return }
                    lastScanned = scanned
                    code = scanned
                    lookUp()
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets())
            } else {
                Text("Scanning needs the camera. Type the numbers under the barcode instead.").font(.footnote).foregroundStyle(Palette.ink2)
            }
            HStack {
                TextField("Barcode", text: $code).keyboardType(.numberPad).accessibilityIdentifier("barcodeField")
                Button(busy ? "Looking up…" : "Look up", action: lookUp)
                    .disabled(busy || code.filter(\.isNumber).count < 8)
                    .accessibilityIdentifier("barcodeLookUp")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } footer: {
            Text("Barcodes are looked up in Open Food Facts, then USDA FoodData Central. healthOS's server sends them the code, never your name.")
        }
        if let found {
            Section { FoodResultsList(found: found, barcode: true, quick: quick, toQuick: toQuick) }
        }
    }

    private func lookUp() {
        let digits = code.filter(\.isNumber)
        guard digits.count >= 8 else { return }
        busy = true
        error = nil
        Task {
            do {
                found = try await dashboard.barcode(digits)
            } catch {
                self.error = error.foodMessage
            }
            busy = false
        }
    }
}

/// VisionKit's live barcode reader, for EAN-13 (and UPC-A within it), EAN-8 and UPC-E.
private struct BarcodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])], qualityLevel: .balanced,
                                           recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        DispatchQueue.main.async { try? vc.startScanning() }
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                if let s = b.payloadStringValue { onCode(s); return }
            }
        }
    }
}

/// One database food: which portion, how many, what that comes to (only the amounts the setting shows), then Add.
private struct FoodPickView: View {
    let pick: FoodPick
    let when: FoodWhen
    let units: Units
    let onChange: () async -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dismiss) private var dismiss
    @State private var portion = 0
    @State private var quantity = "1"
    @State private var busy = false
    @State private var error: String?
    @State private var added: String?

    var body: some View {
        let food = pick.food
        let q = foodQuantity(quantity)
        let values = food.portions.indices.contains(portion) ? food.portions[portion].values : [:]
        let preview = q.map { FoodText.amounts(FoodText.scaled(values, by: $0), units: units) } ?? ""
        Form {
            Section {
                Text(food.name).font(.headline)
                if let brand = food.brand, !brand.isEmpty { Text(brand).font(.footnote).foregroundStyle(Palette.ink3) }
            }
            Section {
                Picker("Portion", selection: $portion) {
                    ForEach(Array(food.portions.enumerated()), id: \.offset) { i, p in Text(p.label).tag(i) }
                }
                LabeledContent("How many") {
                    TextField("1", text: $quantity).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                        .accessibilityIdentifier("pickQuantity")
                }
                if !preview.isEmpty { Text(preview).font(.footnote).foregroundStyle(Palette.ink2) }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            if let added { Section { Text("Added \(added).").font(.footnote) } }
            Section {
                Button(busy ? "Adding…" : "Add") { add(q) }
                    .disabled(busy || q == nil || food.portions.isEmpty)
                    .accessibilityIdentifier("pickAdd")
            }
        }
        .navigationTitle(pick.barcode ? "Barcode" : "Food")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissal()
    }

    private func add(_ q: Double?) {
        guard let q else { return }
        busy = true
        error = nil
        Task {
            do {
                let e = try await dashboard.addFood(FoodBody.food(ref: pick.food.ref, portionIndex: portion, quantity: q, barcode: pick.barcode,
                                                                  date: when.date, time: when.timeText))
                added = e.name
                await onChange()
                dismiss()
            } catch {
                self.error = error.foodMessage
            }
            busy = false
        }
    }
}

/// McFly's estimate from a photo, a few words or both: a draft to check, never saved on its own.
private struct FoodEstimateSection: View {
    let when: FoodWhen
    let onDrafts: (String) -> Void
    let onChange: () async -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var description = ""
    @State private var item: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var jpeg: Data?
    @State private var camera = false
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        Section {
            TextField("What did you have? For example: pasta with pesto, cooked in olive oil, about half a plate.", text: $description, axis: .vertical)
                .lineLimit(3...6)
                .accessibilityIdentifier("estimateText")
            if let photo {
                HStack {
                    Image(uiImage: photo).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Your photo, as it will be sent")
                    Spacer()
                    Button("Remove photo", role: .destructive) { self.photo = nil; jpeg = nil; item = nil }
                }
            } else {
                PhotosPicker(selection: $item, matching: .images) { Label("Choose a photo", systemImage: "photo") }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { camera = true } label: { Label("Take a photo", systemImage: "camera") }
                }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(Palette.ink2) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button(busy ? "Estimating…" : "Estimate", action: estimate)
                .disabled(busy || (description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && jpeg == nil))
                .accessibilityIdentifier("estimate")
        } footer: {
            Text("The photo and words go to Anthropic for this one estimate, and healthOS doesn't keep them. It counts as one McFly question. Estimates are rough, often a third off on calories, so you check them before anything is saved. A few words about oil, sauces or portion size help most.")
        }
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task {
                if let data = try? await new.loadTransferable(type: Data.self), let image = UIImage(data: data) { use(image) }
                else { error = "That photo couldn't be opened here. Try another, or describe it instead." }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { image in
                camera = false
                if let image { use(image) }
            }
            .ignoresSafeArea()
        }
    }

    private func use(_ image: UIImage) {
        error = nil
        guard let data = FoodPhoto.jpeg(from: image) else {
            error = "That photo couldn't be opened here. Try another, or describe it instead."
            return
        }
        jpeg = data
        photo = UIImage(data: data)
    }

    private func estimate() {
        busy = true
        error = nil
        note = nil
        Task {
            do {
                let r = try await dashboard.estimateFood(FoodBody.estimate(description: description.trimmingCharacters(in: .whitespacesAndNewlines), jpeg: jpeg,
                                                                           date: when.date, time: when.timeText))
                if r.drafts.isEmpty {
                    note = (r.note?.isEmpty == false ? r.note : nil) ?? "McFly didn't find food or drink to estimate."
                } else {
                    description = ""
                    photo = nil
                    jpeg = nil
                    item = nil
                    await onChange()
                    onDrafts(r.note ?? "")
                }
            } catch {
                self.error = error.foodMessage
            }
            busy = false
        }
    }
}

/// The camera, for a meal photo (devices only).
private struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// Amounts typed in: an optional name, calories (only when they're shown), protein, carbs, fat and water.
private struct FoodQuickSection: View {
    let when: FoodWhen
    let mode: NutritionMode
    let units: Units
    let onChange: () async -> Void
    @Environment(Dashboard.self) private var dashboard
    @State private var name = ""
    @State private var typed: [String: String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var added: String?

    var body: some View {
        let fields = FoodField.typed(mode)
        Section {
            TextField("Name (optional)", text: $name).accessibilityIdentifier("quickName")
            ForEach(fields) { f in
                LabeledContent("\(f.label) (\(f.unit(units)))") {
                    TextField("", text: Binding(get: { typed[f.key] ?? "" }, set: { typed[f.key] = $0 }))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 100)
                        .accessibilityLabel("\(f.label) in \(f.unit(units))")
                        .accessibilityIdentifier("quick-\(f.key)")
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if let added { Text("Added \(added).").font(.footnote) }
            Button(busy ? "Adding…" : "Add") { add(fields) }.disabled(busy).accessibilityIdentifier("quickAdd")
        }
    }

    private func add(_ fields: [FoodField]) {
        var values: [String: Double] = [:]
        for f in fields {
            guard let v = f.amount(typed[f.key] ?? "", units: units) else { continue }
            guard v.isFinite, v >= 0 else { return error = "\(f.label) should be a number." }
            values[f.key] = v
        }
        guard !values.isEmpty else { return error = "Enter at least one amount." }
        busy = true
        error = nil
        Task {
            do {
                let e = try await dashboard.addFood(FoodBody.quick(name: name, values: values, date: when.date, time: when.timeText))
                added = e.name
                name = ""
                typed = [:]
                await onChange()
            } catch {
                self.error = error.foodMessage
            }
            busy = false
        }
    }
}

// MARK: - Reviewing an estimate

/// McFly's draft: rename, change how many, or leave items out, then save what's left. Nothing counts until then.
private struct FoodReviewSheet: View {
    let drafts: [FoodEntry]
    let batch: String
    let note: String
    let mode: NutritionMode
    let units: Units
    let onDone: () async -> Void
    @Environment(Dashboard.self) private var dashboard
    @Environment(\.dismiss) private var dismiss
    @State private var kept: [Kept]
    @State private var busy = false
    @State private var error: String?

    struct Kept: Identifiable {
        let id: String
        var name: String
        var quantity: String
    }

    init(drafts: [FoodEntry], batch: String, note: String, mode: NutritionMode, units: Units, onDone: @escaping () async -> Void) {
        self.drafts = drafts
        self.batch = batch
        self.note = note
        self.mode = mode
        self.units = units
        self.onDone = onDone
        _kept = State(initialValue: drafts.map { Kept(id: $0.id, name: $0.name, quantity: FoodText.quantityText($0.quantity)) })
    }

    var body: some View {
        let byID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        NavigationStack {
            Form {
                Section {
                    Text("For \(drafts.first?.time ?? ""). Check it, then save. Nothing counts until you do.").font(.footnote)
                    if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(Palette.ink2) }
                }
                ForEach($kept) { $k in
                    if let d = byID[k.id] {
                        Section(d.portion.isEmpty ? "Item" : d.portion) {
                            TextField("Name", text: $k.name).accessibilityLabel("Name")
                            LabeledContent("How many") {
                                TextField("1", text: $k.quantity).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                            }
                            if mode != .none, let q = foodQuantity(k.quantity) {
                                let line = FoodText.amounts(FoodText.scaled(d.values, by: q / d.quantity), units: units)
                                if !line.isEmpty { Text(line).font(.footnote).foregroundStyle(Palette.ink2) }
                            }
                            Button("Leave out", role: .destructive) { kept.removeAll { $0.id == k.id } }
                        }
                    }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                Section {
                    Button(busy ? "Saving…" : kept.count == 1 ? "Save 1 item" : "Save \(kept.count) items") { save(byID) }
                        .disabled(busy || kept.isEmpty)
                        .accessibilityIdentifier("saveDrafts")
                    Button("Discard", role: .destructive, action: discard).disabled(busy)
                } footer: {
                    Text("You can fix any amount after saving, with Edit.")
                }
            }
            .navigationTitle("McFly's estimate")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissal()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }
    }

    private func save(_ byID: [String: FoodEntry]) {
        busy = true
        error = nil
        Task {
            do {
                for k in kept {
                    guard let d = byID[k.id] else { continue }
                    var patch: [String: Any] = [:]
                    let name = k.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.isEmpty { throw FoodError("Give it a name.") }
                    if name != d.name { patch["name"] = name }
                    guard let q = foodQuantity(k.quantity) else { throw FoodError("Choose an amount above 0 and up to 50.") }
                    if q != d.quantity { patch["quantity"] = q }
                    if !patch.isEmpty { try await dashboard.changeFood(d, patch, draft: true) }
                }
                try await dashboard.saveDrafts(batch: batch, ids: kept.map(\.id))
                await onDone()
                dismiss()
            } catch {
                self.error = error.foodMessage
            }
            busy = false
        }
    }

    private func discard() {
        busy = true
        Task {
            do {
                try await dashboard.discardDrafts(batch: batch)
                await onDone()
                dismiss()
            } catch {
                self.error = error.foodMessage
            }
            busy = false
        }
    }
}

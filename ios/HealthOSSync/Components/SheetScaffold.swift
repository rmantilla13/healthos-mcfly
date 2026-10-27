import SwiftUI

/// How wide a sheet's column may get (the web's Sheet widths: .sheet-sm, .sheet, .sheet-lg). Only a sheet wider than
/// that (the inner display's centred sheet) is capped; every iPhone's sheet is narrower.
enum SheetSize: Sendable {
    /// 480: the key sheets.
    case sm
    /// 650: the default.
    case md
    /// 860: Profile → Cards.
    case lg

    /// The column's width at most, its padding included.
    var maxWidth: CGFloat {
        switch self {
        case .sm: 480
        case .md: 650
        case .lg: 860
        }
    }
}

/// A sheet laid out as the web's dialogs (Sheet.tsx, full screen on a phone): an eyebrow over the title, a round close
/// button, the body, and its buttons after it on the right (.sheet-foot), all over the pale mint sheet gradient and
/// scrolling as one, as on the web. It opens at full height.
///
/// On iOS 27.1 and later it always sits in a NavigationStack with its bar hidden (DuoSheetStack), so its structure never
/// changes on a fold and nothing typed in it is lost (§4, O5); before 27.1, where no fold or vertical bar can happen,
/// it's as it always was. Where the sheet has a vertical bar of its own (the iPhone Duo's outer display), that bar
/// shows and holds Close (`.cancellationAction`, at its top) in place of the round ×. The sheet is its own scope: its
/// band comes from its own width, and it reads its own bar edge from inside itself (Shell/Duo/DuoScope.swift). It never
/// splits on the fold: the system places the sheet.
///
///     .sheet(isPresented: $editing) {
///         SheetScaffold(eyebrow: "Home", title: "Edit widgets") {
///             …
///         } footer: {
///             Button("Done") { editing = false }.buttonStyle(.accentPill)
///         }
///     }
struct SheetScaffold<Content: View, Footer: View>: View {
    var eyebrow: String?
    let title: String
    /// The column's widest (the web's Sheet width).
    var size: SheetSize
    /// What the close button does; dismissing the sheet when nil.
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    let hasFooter: Bool
    @Environment(\.dismiss) private var dismiss

    init(eyebrow: String? = nil, title: String, size: SheetSize = .md, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.eyebrow = eyebrow
        self.title = title
        self.size = size
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
        hasFooter = Footer.self != EmptyView.self
    }

    var body: some View {
        DuoSheetStack {
            DuoScope(.sheet(maxWidth: size.maxWidth, padding: Self.padding)) { scope in
                let inBar = scope.barEdge != nil
                ScrollView { column(closeInBar: inBar, side: scope.margins.leading) }
                    .scrollDismissesKeyboard(.interactively)
                    .font(.app(.body))
                    .foregroundStyle(Palette.ink)
                    .tint(Palette.tint)
                    .toggleStyle(.appSwitch)
                    .toolbar(inBar ? .visible : .hidden, for: .navigationBar)
                    .toolbar {
                        if inBar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(action: close) { Label("Close", systemImage: "xmark") }
                            }
                        }
                    }
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground { GradientFill(.gradSheet) }
    }

    /// The sides' padding, as the web's phone sheet (18px).
    static var padding: CGFloat { 18 }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// The sheet's column, `side` in from each edge: 18 on every iPhone; more on a sheet wider than its SheetSize.
    private func column(closeInBar: Bool, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let eyebrow { Eyebrow(eyebrow) }
                    Text(title)
                        .font(.app(size: 22, weight: .medium, relativeTo: .title2))
                        .tracking(-0.22)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                if !closeInBar { SheetCloseButton(action: close) }
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasFooter {
                // No band or line of its own: the web's footer sits on the sheet's gradient.
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    footer
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, side)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }
}

extension SheetScaffold where Footer == EmptyView {
    init(eyebrow: String? = nil, title: String, size: SheetSize = .md, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(eyebrow: eyebrow, title: title, size: size, onClose: onClose, content: content) { EmptyView() }
    }
}

/// The sheet's round close button: an × on a white circle with a soft shadow.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.ink2)
                .frame(width: 40, height: 40)
                .background(Palette.surface, in: Circle())
                .tokenShadow(.pill, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

import SwiftUI

/// A sheet laid out as the web's dialogs (Sheet.tsx, full screen on a phone): an eyebrow over the title, a round close
/// button, the body, and buttons along the bottom, over the pale mint sheet gradient. It opens at full height.
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
    /// What the close button does; dismissing the sheet when nil.
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    let hasFooter: Bool
    @Environment(\.dismiss) private var dismiss

    init(eyebrow: String? = nil, title: String, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.eyebrow = eyebrow
        self.title = title
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
        hasFooter = Footer.self != EmptyView.self
    }

    var body: some View {
        ScrollView {
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
                    SheetCloseButton { if let onClose { onClose() } else { dismiss() } }
                }
                VStack(alignment: .leading, spacing: 14) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasFooter {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Palette.surface)
                .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
            }
        }
        .tint(Palette.tint)
        .presentationDetents([.large])
        .presentationCornerRadius(Radius.sheet)
        .presentationBackground { GradientFill(.gradSheet) }
    }
}

extension SheetScaffold where Footer == EmptyView {
    init(eyebrow: String? = nil, title: String, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(eyebrow: eyebrow, title: title, onClose: onClose, content: content) { EmptyView() }
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

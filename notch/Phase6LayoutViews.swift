import SwiftUI

/// Shows the Shelf's existing file, clipboard, and folder tools together so no
/// stored content is hidden behind a second navigation row.
struct Phase6ShelfOverview: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 8
            let width = geometry.size.width
            if width >= 640 {
                let clipboardWidth = max(220, width * 0.4)
                let sideWidth = max(0, (width - gap * 2 - clipboardWidth) / 2)
                HStack(alignment: .top, spacing: gap) {
                    filesPane(width: sideWidth, height: nil)
                    clipboardPane(width: clipboardWidth, height: nil)
                    foldersPane(width: sideWidth, height: nil)
                }
                .frame(width: width, height: geometry.size.height, alignment: .top)
            } else {
                let sectionHeight = max(130, (geometry.size.height - 120 - gap * 2) / 2)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: gap) {
                        filesPane(width: width, height: nil, compact: true, fillsAvailableHeight: false)
                            .fixedSize(horizontal: false, vertical: true)
                        clipboardPane(width: width, height: sectionHeight, compact: true)
                        foldersPane(width: width, height: sectionHeight, compact: true)
                    }
                    .frame(width: width, alignment: .topLeading)
                }
                .frame(width: width, height: geometry.size.height)
            }
        }
        .accessibilityIdentifier("shelf-panel")
    }

    private func filesPane(width: CGFloat, height: CGFloat?, compact: Bool? = nil, fillsAvailableHeight: Bool = true) -> some View {
        shelfPane("Files", symbol: "tray.full.fill", tint: NotchModule.shelf.tint, width: width, height: height, fillsAvailableHeight: fillsAvailableHeight) {
            IntegratedShelfView(store: shelf, compact: compact ?? (width < 260))
        }
    }

    private func clipboardPane(width: CGFloat, height: CGFloat?, compact: Bool? = nil) -> some View {
        shelfPane("Clipboard", symbol: "doc.on.clipboard", tint: .cyan, width: width, height: height) {
            ClipboardWorkspaceView(compact: compact ?? (width < 260))
        }
    }

    private func foldersPane(width: CGFloat, height: CGFloat?, compact: Bool? = nil) -> some View {
        shelfPane("Folders", symbol: "folder.fill", tint: .mint, width: width, height: height) {
            FolderWorkspaceView(compact: compact ?? (width < 260))
        }
    }

    private func shelfPane<Content: View>(
        _ title: String,
        symbol: String,
        tint: Color,
        width: CGFloat,
        height: CGFloat?,
        fillsAvailableHeight: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
            content()
                .frame(maxWidth: .infinity, maxHeight: fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
        }
        .padding(8)
        .frame(width: width, height: height, alignment: .topLeading)
        .frame(maxHeight: height == nil && fillsAvailableHeight ? .infinity : nil, alignment: .topLeading)
        .background(.white.opacity(0.035), in: shape)
        .clipShape(shape)
    }
}

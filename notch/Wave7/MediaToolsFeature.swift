import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum MediaToolsFeature {
    private static let lock = NSLock()
    private static var cancelActiveJob: (() -> Void)?

    static func apply(_ feature: NotchFeature, enabled: Bool) {
        guard feature == .mediaTools, !enabled else { return }
        lock.lock()
        let cancel = cancelActiveJob
        cancelActiveJob = nil
        lock.unlock()
        cancel?()
    }

    fileprivate static func registerCancellation(_ cancel: @escaping () -> Void) {
        lock.lock()
        cancelActiveJob = cancel
        lock.unlock()
    }

    fileprivate static func clearCancellation() {
        lock.lock()
        cancelActiveJob = nil
        lock.unlock()
    }
}

enum ConvertAction: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, heic, webp
    case halfSize, max1080, customResize, compressJPEG, stripMetadata
    case mp4H264, hevc, compress1080, compress720, extractM4A, makeGIF
    case audioM4A, mergePDF, imagesPDF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        case .halfSize: return "50%"
        case .max1080: return "1080 px"
        case .customResize: return "Resize…"
        case .compressJPEG: return "Compress JPEG"
        case .stripMetadata: return "Strip Metadata"
        case .mp4H264: return "MP4 · H.264"
        case .hevc: return "HEVC"
        case .compress1080: return "Compress 1080p"
        case .compress720: return "Compress 720p"
        case .extractM4A: return "Extract M4A"
        case .makeGIF: return "GIF · 10 sec"
        case .audioM4A: return "M4A · AAC"
        case .mergePDF: return "Merge PDFs"
        case .imagesPDF: return "Images to PDF"
        }
    }

    var symbol: String {
        switch self {
        case .png, .jpeg, .heic, .webp, .compressJPEG, .stripMetadata, .halfSize, .max1080, .customResize, .imagesPDF:
            return "photo"
        case .mp4H264, .hevc, .compress1080, .compress720, .makeGIF:
            return "film"
        case .extractM4A, .audioM4A:
            return "waveform"
        case .mergePDF:
            return "doc.on.doc"
        }
    }

    fileprivate func output(suggestedFor input: ConvertInput) -> (suffix: String, ext: String, typeIdentifier: String?) {
        let originalExtension = input.url.pathExtension.isEmpty ? "png" : input.url.pathExtension.lowercased()
        switch self {
        case .png: return ("PNG", "png", UTType.png.identifier)
        case .jpeg: return ("JPEG", "jpg", UTType.jpeg.identifier)
        case .heic: return ("HEIC", "heic", UTType.heic.identifier)
        case .webp: return ("WebP", "webp", UTType.webP.identifier)
        case .halfSize: return ("50%", originalExtension, nil)
        case .max1080: return ("1080px", originalExtension, nil)
        case .customResize: return ("Resized", originalExtension, nil)
        case .compressJPEG: return ("Compressed", "jpg", UTType.jpeg.identifier)
        case .stripMetadata: return ("Metadata Stripped", originalExtension, nil)
        case .mp4H264: return ("H264", "mp4", UTType.mpeg4Movie.identifier)
        case .hevc: return ("HEVC", "mp4", UTType.mpeg4Movie.identifier)
        case .compress1080: return ("1080p", "mp4", UTType.mpeg4Movie.identifier)
        case .compress720: return ("720p", "mp4", UTType.mpeg4Movie.identifier)
        case .extractM4A, .audioM4A: return ("AAC", "m4a", UTType.mpeg4Audio.identifier)
        case .makeGIF: return ("GIF", "gif", UTType.gif.identifier)
        case .mergePDF: return ("Merged", "pdf", UTType.pdf.identifier)
        case .imagesPDF: return ("PDF", "pdf", UTType.pdf.identifier)
        }
    }
}

enum ConvertPlanner {
    static func actions(for utType: UTType) -> [ConvertAction] {
        if utType.conforms(to: .image) {
            let destinations = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
            var actions: [ConvertAction] = []
            if destinations.contains(UTType.png.identifier) { actions.append(.png) }
            if destinations.contains(UTType.jpeg.identifier) { actions.append(.jpeg) }
            if destinations.contains(UTType.heic.identifier) { actions.append(.heic) }
            if destinations.contains(UTType.webP.identifier) { actions.append(.webp) }
            actions += [.halfSize, .max1080, .customResize, .compressJPEG, .stripMetadata, .imagesPDF]
            return actions
        }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) {
            return [.mp4H264, .hevc, .compress1080, .compress720, .extractM4A, .makeGIF]
        }
        if utType.conforms(to: .audio) { return [.audioM4A] }
        if utType.conforms(to: .pdf) { return [.mergePDF] }
        return []
    }
}

enum ConvertNaming {
    /// Builds a sibling name and reserves numeric suffixes against the supplied snapshot.
    static func outputURL(input: URL, suffix: String, ext: String, existing: Set<URL>) -> URL {
        let folder = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let cleanSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExtension = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let suffixText = cleanSuffix.isEmpty ? "" : " \(cleanSuffix)"
        let occupied = Set(existing.map { $0.standardizedFileURL.path.lowercased() })

        var number = 1
        while true {
            let collisionText = number == 1 ? "" : " \(number)"
            let filename = "\(stem)\(suffixText)\(collisionText)\(cleanExtension.isEmpty ? "" : ".\(cleanExtension)")"
            let candidate = folder.appendingPathComponent(filename).standardizedFileURL
            if !occupied.contains(candidate.path.lowercased()) { return candidate }
            number += 1
        }
    }
}

enum ResizeMath {
    /// Fits an image inside a maximum edge without enlarging it.
    static func size(for size: CGSize, maxEdge: CGFloat) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, maxEdge.isFinite,
              size.width > 0, size.height > 0, maxEdge > 0 else { return .zero }
        let scale = min(1, maxEdge / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded()),
                      height: max(1, (size.height * scale).rounded()))
    }
}

private struct ConvertInput: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let bookmarkData: Data?

    init(id: UUID = UUID(), url: URL, bookmarkData: Data? = nil) {
        self.id = id
        self.url = url.standardizedFileURL
        self.bookmarkData = bookmarkData
    }

    var contentType: UTType {
        UTType(filenameExtension: url.pathExtension) ?? .item
    }
}

private struct ConvertProgressRow: Identifiable {
    let id: UUID
    let name: String
    var status: String
    var progress: Double
    var outputURL: URL?
    var outputBookmark: Data?
}

private struct PublishedConvertFile {
    let url: URL
    let bookmarkData: Data?
}

@MainActor
struct MediaToolsView: View {
    @AppStorage(NotchFeature.mediaTools.defaultsKey) private var featureEnabled = true
    @State private var inputs: [ConvertInput] = []
    @State private var rows: [ConvertProgressRow] = []
    @State private var jobTask: Task<Void, Never>?
    @State private var isRunning = false
    @State private var isDropTargeted = false
    @State private var statusText = "Drop files here or choose files to convert."
    @State private var errorText: String?
    @State private var outputFolderBookmark = UserDefaults.standard.data(forKey: "notch.mediaTools.outputFolderBookmark")
    @State private var askedForOutputFolder = false

    private static let outputFolderKey = "notch.mediaTools.outputFolderBookmark"

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .foregroundStyle(.white.opacity(0.85))
                Text("Convert")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                toolButton("Choose Files…", symbol: "plus", id: "convert-choose-files",
                           help: "Choose one or more images, videos, audio files, or PDFs.") {
                    self.chooseFiles()
                }
                toolButton("Use Shelf files", symbol: "tray", id: "convert-use-shelf",
                           help: "Add supported files currently in Shelf.") {
                    self.useShelfFiles()
                }
                toolButton("Cancel", symbol: "xmark", id: "convert-cancel",
                           help: "Cancel the current conversion job.", isDisabled: !isRunning) {
                    self.jobTask?.cancel()
                }
            }

            HStack(spacing: 9) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "square.and.arrow.down")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isDropTargeted ? "Release to add files" : "Drop images, video, audio, or PDFs")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                    Text(statusText)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !inputs.isEmpty {
                    Text("\(inputs.count) selected")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                    toolButton("Clear", symbol: "trash", id: "convert-clear-selection",
                               help: "Remove all selected files.", isDisabled: isRunning) {
                        self.inputs.removeAll()
                        self.rows.removeAll()
                        self.errorText = nil
                        self.statusText = "Drop files here or choose files to convert."
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(isDropTargeted ? 0.10 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(isDropTargeted ? 0.35 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: receiveDrop)

            if inputs.isEmpty {
                Text("Choose files to see format, resize, and compression actions.")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(availableActions) { action in
                            self.toolButton(action.title, symbol: action.symbol,
                                       id: "convert-action-\(action.rawValue)",
                                       help: self.actionHelp(action), isDisabled: !self.canRun(action)) {
                                if action == .customResize {
                                    guard let edge = self.requestCustomMaxEdge() else { return }
                                    self.startJob(action, customMaxEdge: edge)
                                } else {
                                    self.startJob(action)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 32)
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.95))
                    .lineLimit(1)
                    .help(errorText)
            }

            if !rows.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(rows.prefix(8)) { row in
                            self.progressRow(row)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 84)
            }
        }
        .padding(12)
        .background(Color.black)
        .onChange(of: featureEnabled) { _, enabled in
            if !enabled { self.jobTask?.cancel() }
        }
    }

    private var availableActions: [ConvertAction] {
        let offered = Set(inputs.flatMap { ConvertPlanner.actions(for: $0.contentType) })
        return ConvertAction.allCases.filter { offered.contains($0) }
    }

    private func canRun(_ action: ConvertAction) -> Bool {
        guard featureEnabled, !isRunning else { return false }
        switch action {
        case .mergePDF:
            return inputs.filter { $0.contentType.conforms(to: .pdf) }.count >= 2
        case .imagesPDF:
            return inputs.contains { $0.contentType.conforms(to: .image) }
        default:
            return inputs.contains { ConvertPlanner.actions(for: $0.contentType).contains(action) }
        }
    }

    private func actionHelp(_ action: ConvertAction) -> String {
        switch action {
        case .halfSize: return "Resize each selected image to half of its current dimensions."
        case .max1080: return "Resize each selected image so its longest edge is at most 1080 pixels."
        case .customResize: return "Choose a maximum edge in pixels for selected images."
        case .compressJPEG: return "Save selected images as JPEG at 70% quality."
        case .stripMetadata: return "Write selected images without embedded metadata."
        case .mp4H264: return "Export selected videos as H.264 MP4."
        case .hevc: return "Export selected videos using HEVC compression."
        case .compress1080: return "Export selected videos at up to 1920 by 1080."
        case .compress720: return "Export selected videos at up to 1280 by 720."
        case .extractM4A: return "Extract the audio track from selected videos as M4A."
        case .makeGIF: return "Create a 480-pixel GIF from the first 10 seconds at 10 frames per second."
        case .audioM4A: return "Convert selected audio files to AAC in an M4A container."
        case .mergePDF: return "Merge the selected PDFs in their current order."
        case .imagesPDF: return "Put each selected image on a page in one PDF."
        case .png: return "Convert selected images to PNG."
        case .jpeg: return "Convert selected images to JPEG."
        case .heic: return "Convert selected images to HEIC."
        case .webp: return "Convert selected images to WebP when ImageIO supports it."
        }
    }

    private func toolButton(_ title: String, symbol: String, id: String, help: String,
                            isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(isDisabled ? 0.38 : 0.92))
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isDisabled ? 0.025 : 0.075)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .disabled(isDisabled)
        .help(help)
        .accessibilityIdentifier(id)
    }

    private func progressRow(_ row: ConvertProgressRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.progress >= 1 ? "checkmark.circle.fill" : "doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(row.progress >= 1 ? .green : .white.opacity(0.65))
                .frame(width: 14)
            Text(row.name)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            Text(row.status)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: row.progress)
                .tint(.white.opacity(0.8))
                .frame(width: 72)
            if let outputURL = row.outputURL {
                toolButton("Reveal", symbol: "magnifyingglass", id: "convert-reveal-\(row.id.uuidString.lowercased())",
                           help: "Reveal \(outputURL.lastPathComponent) in Finder.") {
                    self.reveal(outputURL, bookmark: row.outputBookmark)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.05)))
        .accessibilityElement(children: .contain)
    }

    private func chooseFiles() {
        guard featureEnabled, !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Files"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        addInputs(panel.urls)
    }

    private func useShelfFiles() {
        guard featureEnabled, !isRunning else { return }
        let shelfFiles = ShelfStore.shared.items.compactMap { item -> (URL, Data?)? in
            guard item.isFile else { return nil }
            var url = item.url
            if let bookmark = item.bookmarkData {
                var stale = false
                url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                relativeTo: nil, bookmarkDataIsStale: &stale)) ?? url
            }
            return (url, item.bookmarkData)
        }
        addInputs(shelfFiles.map(\.0), bookmarks: shelfFiles.map(\.1))
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard featureEnabled, !isRunning else { return false }
        let group = DispatchGroup()
        let collector = ConvertDropCollector()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = ConvertDropCollector.url(from: item) { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.addInputs(collector.urls)
        }
        return true
    }

    private func addInputs(_ urls: [URL], bookmarks: [Data?]? = nil) {
        var added = 0
        for (index, url) in urls.enumerated() where url.isFileURL {
            let standardized = url.standardizedFileURL
            guard !inputs.contains(where: { $0.url.path == standardized.path }) else { continue }
            let type = UTType(filenameExtension: standardized.pathExtension) ?? .item
            guard !ConvertPlanner.actions(for: type).isEmpty else { continue }
            let bookmark = bookmarks.flatMap { index < $0.count ? $0[index] : nil }
                ?? (try? standardized.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            inputs.append(ConvertInput(url: standardized, bookmarkData: bookmark))
            added += 1
        }
        if added > 0 {
            rows.removeAll()
            errorText = nil
            statusText = "Ready. Actions apply to supported selected files."
        } else if inputs.isEmpty {
            statusText = "No supported files found. Choose images, video, audio, or PDFs."
        }
    }

    private func requestCustomMaxEdge() -> CGFloat? {
        let field = NSTextField(string: "2048")
        field.frame = NSRect(x: 0, y: 0, width: 210, height: 24)
        let alert = NSAlert()
        alert.messageText = "Custom maximum edge"
        alert.informativeText = "Enter the longest image edge in pixels."
        alert.accessoryView = field
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value >= 1, value <= 100_000 else {
            errorText = "Enter a maximum edge between 1 and 100000 pixels."
            return nil
        }
        errorText = nil
        return CGFloat(value)
    }

    private func startJob(_ action: ConvertAction, customMaxEdge: CGFloat? = nil) {
        guard canRun(action) else { return }
        errorText = nil
        askedForOutputFolder = false
        isRunning = true
        statusText = "Starting \(action.title)…"
        rows = inputs.prefix(8).map {
            ConvertProgressRow(id: $0.id, name: $0.url.lastPathComponent, status: "Queued", progress: 0.02)
        }
        let task = Task { @MainActor in
            await self.runJob(action, customMaxEdge: customMaxEdge)
        }
        jobTask = task
        MediaToolsFeature.registerCancellation { task.cancel() }
    }

    private func runJob(_ action: ConvertAction, customMaxEdge: CGFloat?) async {
        defer {
            isRunning = false
            jobTask = nil
            MediaToolsFeature.clearCancellation()
        }
        do {
            switch action {
            case .mergePDF:
                let pdfs = inputs.filter { $0.contentType.conforms(to: .pdf) }
                try await runGroupedJob(action, inputs: pdfs, customMaxEdge: customMaxEdge)
            case .imagesPDF:
                let images = inputs.filter { $0.contentType.conforms(to: .image) }
                try await runGroupedJob(action, inputs: images, customMaxEdge: customMaxEdge)
            default:
                for input in inputs where ConvertPlanner.actions(for: input.contentType).contains(action) {
                    try Task.checkCancellation()
                    setProgress(for: input.id, status: "Converting…", progress: 0.12)
                    do {
                        let output = action.output(suggestedFor: input)
                        let temporaryURL = try await createTemporaryOutput(action, inputs: [input], ext: output.ext,
                                                                           customMaxEdge: customMaxEdge)
                        do {
                            let published = try await publish(temporaryURL, input: input, suffix: output.suffix, ext: output.ext)
                            try? FileManager.default.removeItem(at: temporaryURL)
                            setProgress(for: input.id, status: "Complete", progress: 1,
                                        outputURL: published.url, outputBookmark: published.bookmarkData)
                        } catch {
                            try? FileManager.default.removeItem(at: temporaryURL)
                            throw error
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        setProgress(for: input.id, status: "Failed", progress: 1)
                        errorText = error.localizedDescription
                    }
                }
            }
            if Task.isCancelled {
                statusText = "Conversion cancelled."
            } else if errorText == nil {
                statusText = "Conversion complete."
            } else {
                statusText = "Finished with an error."
            }
        } catch is CancellationError {
            statusText = "Conversion cancelled."
            for row in rows where row.progress < 1 {
                setProgress(for: row.id, status: "Cancelled", progress: 0)
            }
        } catch {
            statusText = "Conversion failed."
            errorText = error.localizedDescription
        }
    }

    private func runGroupedJob(_ action: ConvertAction, inputs groupedInputs: [ConvertInput], customMaxEdge: CGFloat?) async throws {
        guard let first = groupedInputs.first else { return }
        for input in groupedInputs { setProgress(for: input.id, status: "Preparing…", progress: 0.08) }
        let output = action.output(suggestedFor: first)
        let temporaryURL = try await createTemporaryOutput(action, inputs: groupedInputs, ext: output.ext,
                                                           customMaxEdge: customMaxEdge)
        do {
            let published = try await publish(temporaryURL, input: first, suffix: output.suffix, ext: output.ext)
            try? FileManager.default.removeItem(at: temporaryURL)
            for input in groupedInputs {
                setProgress(for: input.id, status: "Included", progress: 1,
                            outputURL: input.id == first.id ? published.url : nil,
                            outputBookmark: input.id == first.id ? published.bookmarkData : nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func createTemporaryOutput(_ action: ConvertAction, inputs: [ConvertInput], ext: String,
                                      customMaxEdge: CGFloat?) async throws -> URL {
        let worker = Task.detached(priority: .userInitiated) {
            try await MediaConverter.makeTemporaryOutput(action: action, inputs: inputs, ext: ext,
                                                         customMaxEdge: customMaxEdge)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func publish(_ temporaryURL: URL, input: ConvertInput, suffix: String, ext: String) async throws -> PublishedConvertFile {
        do {
            return try await publishSibling(temporaryURL, input: input, suffix: suffix, ext: ext)
        } catch {
            let siblingError = error
            if let bookmark = outputFolderBookmark {
                do { return try await publishInFolder(temporaryURL, input: input, suffix: suffix, ext: ext, bookmark: bookmark) }
                catch {
                    outputFolderBookmark = nil
                    UserDefaults.standard.removeObject(forKey: Self.outputFolderKey)
                }
            }
            guard !askedForOutputFolder else { throw siblingError }
            askedForOutputFolder = true
            guard let folder = chooseOutputFolder() else { throw ConvertError.outputFolderRequired }
            let bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            outputFolderBookmark = bookmark
            UserDefaults.standard.set(bookmark, forKey: Self.outputFolderKey)
            return try await publishInFolder(temporaryURL, input: input, suffix: suffix, ext: ext, bookmark: bookmark)
        }
    }

    private func publishSibling(_ temporaryURL: URL, input: ConvertInput, suffix: String, ext: String) async throws -> PublishedConvertFile {
        try await Task.detached(priority: .utility) {
            try ConvertOutputPublisher.publishSibling(temporaryURL, input: input, suffix: suffix, ext: ext)
        }.value
    }

    private func publishInFolder(_ temporaryURL: URL, input: ConvertInput, suffix: String, ext: String,
                                 bookmark: Data) async throws -> PublishedConvertFile {
        try await Task.detached(priority: .utility) {
            try ConvertOutputPublisher.publishInFolder(temporaryURL, input: input, suffix: suffix, ext: ext,
                                                       folderBookmark: bookmark)
        }.value
    }

    private func chooseOutputFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Output Folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func setProgress(for id: UUID, status: String, progress: Double,
                             outputURL: URL? = nil, outputBookmark: Data? = nil) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = status
        rows[index].progress = progress
        if let outputURL { rows[index].outputURL = outputURL }
        if let outputBookmark { rows[index].outputBookmark = outputBookmark }
    }

    private func reveal(_ url: URL, bookmark: Data?) {
        var scopedURL = url
        var stale = false
        if let bookmark,
           let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                   relativeTo: nil, bookmarkDataIsStale: &stale) {
            scopedURL = resolved.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent)
        }
        let didStart = scopedURL.deletingLastPathComponent().startAccessingSecurityScopedResource()
        NSWorkspace.shared.activateFileViewerSelecting([scopedURL])
        if didStart { scopedURL.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
    }
}

private enum ConvertError: LocalizedError {
    case cannotRead(String)
    case cannotWrite(String)
    case unsupported(String)
    case outputFolderRequired

    var errorDescription: String? {
        switch self {
        case .cannotRead(let name): return "Could not read \(name)."
        case .cannotWrite(let name): return "Could not write \(name)."
        case .unsupported(let message): return message
        case .outputFolderRequired: return "Choose an output folder to save converted files."
        }
    }
}

private final class ConvertDropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        values.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    static func url(from item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { return url }
            if let string = String(data: data, encoding: .utf8) { return URL(string: string)?.isFileURL == true ? URL(string: string) : nil }
        }
        return nil
    }
}

private enum ConvertOutputPublisher {
    static func publishSibling(_ temporaryURL: URL, input: ConvertInput, suffix: String, ext: String) throws -> PublishedConvertFile {
        let source = resolve(input)
        let didStart = source.startAccessingSecurityScopedResource()
        defer { if didStart { source.stopAccessingSecurityScopedResource() } }
        let existing = Set((try? FileManager.default.contentsOfDirectory(at: source.deletingLastPathComponent(),
                                                                         includingPropertiesForKeys: nil)) ?? [])
        let target = ConvertNaming.outputURL(input: source, suffix: suffix, ext: ext, existing: existing)
        try FileManager.default.copyItem(at: temporaryURL, to: target)
        return PublishedConvertFile(url: target, bookmarkData: input.bookmarkData)
    }

    static func publishInFolder(_ temporaryURL: URL, input: ConvertInput, suffix: String, ext: String,
                                folderBookmark: Data) throws -> PublishedConvertFile {
        let folder = try resolve(folderBookmark)
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        let namedInput = folder.appendingPathComponent(input.url.lastPathComponent)
        let existing = Set((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        let target = ConvertNaming.outputURL(input: namedInput, suffix: suffix, ext: ext, existing: existing)
        try FileManager.default.copyItem(at: temporaryURL, to: target)
        return PublishedConvertFile(url: target, bookmarkData: folderBookmark)
    }

    private static func resolve(_ input: ConvertInput) -> URL {
        guard let bookmark = input.bookmarkData else { return input.url }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ?? input.url
    }

    private static func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                       relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

private enum MediaConverter {
    static func makeTemporaryOutput(action: ConvertAction, inputs: [ConvertInput], ext: String,
                                    customMaxEdge: CGFloat?) async throws -> URL {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-convert-\(UUID().uuidString).\(ext)")
        do {
            try Task.checkCancellation()
            switch action {
            case .mergePDF:
                try mergePDFs(inputs, destination: temporaryURL)
            case .imagesPDF:
                try imagesToPDF(inputs, destination: temporaryURL)
            case .png, .jpeg, .heic, .webp, .halfSize, .max1080, .customResize, .compressJPEG, .stripMetadata:
                guard let input = inputs.first else { throw ConvertError.cannotRead("the selected image") }
                try convertImage(input, action: action, destination: temporaryURL, customMaxEdge: customMaxEdge)
            case .mp4H264, .hevc, .compress1080, .compress720, .extractM4A, .makeGIF:
                guard let input = inputs.first else { throw ConvertError.cannotRead("the selected video") }
                if action == .makeGIF {
                    try makeGIF(input, destination: temporaryURL)
                } else {
                    try await exportAsset(input, action: action, destination: temporaryURL)
                }
            case .audioM4A:
                guard let input = inputs.first else { throw ConvertError.cannotRead("the selected audio") }
                try await exportAsset(input, action: action, destination: temporaryURL)
            }
            try Task.checkCancellation()
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func withAccess<T>(_ input: ConvertInput, body: (URL) throws -> T) throws -> T {
        let url = resolvedURL(input)
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    private static func resolvedURL(_ input: ConvertInput) -> URL {
        guard let bookmark = input.bookmarkData else { return input.url }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ?? input.url
    }

    private static func convertImage(_ input: ConvertInput, action: ConvertAction, destination: URL,
                                     customMaxEdge: CGFloat?) throws {
        try withAccess(input) { sourceURL in
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else { throw ConvertError.cannotRead(input.url.lastPathComponent) }
            let sourceIdentifier = (CGImageSourceGetType(source) as String?) ?? UTType.png.identifier
            let sourceType = UTType(filenameExtension: input.url.pathExtension)
            let destinationIdentifier: String
            switch action {
            case .png: destinationIdentifier = UTType.png.identifier
            case .jpeg, .compressJPEG: destinationIdentifier = UTType.jpeg.identifier
            case .heic: destinationIdentifier = UTType.heic.identifier
            case .webp: destinationIdentifier = UTType.webP.identifier
            default: destinationIdentifier = sourceType?.identifier ?? sourceIdentifier
            }
            guard let imageDestination = CGImageDestinationCreateWithURL(destination as CFURL,
                                                                         destinationIdentifier as CFString, 1, nil) else {
                throw ConvertError.unsupported("ImageIO cannot write \(destinationIdentifier).")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let size = CGSize(width: pixelWidth, height: pixelHeight)
            let maxEdge: CGFloat? = switch action {
            case .halfSize: max(1, max(size.width, size.height) / 2)
            case .max1080: 1080
            case .customResize: customMaxEdge
            case .stripMetadata: max(size.width, size.height)
            default: nil
            }
            var options: [CFString: Any] = [:]
            if action == .compressJPEG { options[kCGImageDestinationLossyCompressionQuality] = 0.7 }
            if let maxEdge {
                guard maxEdge.isFinite, maxEdge > 0 else {
                    throw ConvertError.unsupported("Enter a valid resize edge.")
                }
                let targetSize = action == .halfSize
                    ? CGSize(width: max(1, (size.width / 2).rounded()), height: max(1, (size.height / 2).rounded()))
                    : ResizeMath.size(for: size, maxEdge: maxEdge)
                let maxPixel = Int(max(targetSize.width, targetSize.height))
                let thumbnailOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                    throw ConvertError.cannotRead(input.url.lastPathComponent)
                }
                CGImageDestinationAddImage(imageDestination, image, options as CFDictionary)
            } else if action == .stripMetadata {
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ConvertError.cannotRead(input.url.lastPathComponent)
                }
                CGImageDestinationAddImage(imageDestination, image, options as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(imageDestination, source, 0, options as CFDictionary)
            }
            guard CGImageDestinationFinalize(imageDestination) else { throw ConvertError.cannotWrite(destination.lastPathComponent) }
        }
    }

    private static func exportAsset(_ input: ConvertInput, action: ConvertAction, destination: URL) async throws {
        let url = resolvedURL(input)
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let preset: String
        let fileType: AVFileType
        switch action {
        case .mp4H264: preset = AVAssetExportPresetHighestQuality; fileType = .mp4
        case .hevc: preset = AVAssetExportPresetHEVCHighestQuality; fileType = .mp4
        case .compress1080: preset = AVAssetExportPreset1920x1080; fileType = .mp4
        case .compress720: preset = AVAssetExportPreset1280x720; fileType = .mp4
        case .extractM4A, .audioM4A: preset = AVAssetExportPresetAppleM4A; fileType = .m4a
        default: throw ConvertError.unsupported("This export action is not supported.")
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.unsupported("This media cannot be exported with the selected format.")
        }
        guard exporter.supportedFileTypes.contains(fileType) else {
            throw ConvertError.unsupported("This source cannot be exported as \(fileType.rawValue).")
        }
        let exportTask = Task { try await exporter.export(to: destination, as: fileType) }
        try await withTaskCancellationHandler {
            try await exportTask.value
        } onCancel: {
            exporter.cancelExport()
        }
    }

    private static func makeGIF(_ input: ConvertInput, destination: URL) throws {
        try withAccess(input) { sourceURL in
            let asset = AVURLAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            let duration = CMTimeGetSeconds(asset.duration)
            guard duration.isFinite, duration > 0 else { throw ConvertError.cannotRead(input.url.lastPathComponent) }
            let frameCount = min(100, max(1, Int(ceil(min(10, duration) * 10))))
            guard let imageDestination = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString,
                                                                         frameCount, nil) else {
                throw ConvertError.unsupported("ImageIO cannot create GIF files.")
            }
            CGImageDestinationSetProperties(imageDestination,
                                            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1,
                                                kCGImagePropertyGIFUnclampedDelayTime: 0.1]
            ]
            for index in 0..<frameCount {
                try Task.checkCancellation()
                let time = CMTime(seconds: Double(index) / 10, preferredTimescale: 600)
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                CGImageDestinationAddImage(imageDestination, image, frameProperties as CFDictionary)
            }
            guard CGImageDestinationFinalize(imageDestination) else { throw ConvertError.cannotWrite(destination.lastPathComponent) }
        }
    }

    private static func mergePDFs(_ inputs: [ConvertInput], destination: URL) throws {
        let output = PDFDocument()
        var pageCount = 0
        for input in inputs {
            try Task.checkCancellation()
            try withAccess(input) { url in
                guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                    throw ConvertError.cannotRead(input.url.lastPathComponent)
                }
                for pageIndex in 0..<document.pageCount {
                    if let page = document.page(at: pageIndex) {
                        output.insert(page, at: pageCount)
                        pageCount += 1
                    }
                }
            }
        }
        guard pageCount > 0, output.write(to: destination) else { throw ConvertError.cannotWrite(destination.lastPathComponent) }
    }

    private static func imagesToPDF(_ inputs: [ConvertInput], destination: URL) throws {
        let output = PDFDocument()
        var pageCount = 0
        for input in inputs {
            try Task.checkCancellation()
            try withAccess(input) { url in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let page = PDFPage(image: NSImage(cgImage: image,
                                                        size: NSSize(width: image.width, height: image.height))) else {
                    throw ConvertError.cannotRead(input.url.lastPathComponent)
                }
                output.insert(page, at: pageCount)
                pageCount += 1
            }
        }
        guard pageCount > 0, output.write(to: destination) else { throw ConvertError.cannotWrite(destination.lastPathComponent) }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MaintenanceFeature {
    /// Maintenance has no background work. Each page starts only the scans the user requests;
    /// the Memory page owns its short-lived refresh task while visible.
    static func apply(_ feature: NotchFeature, enabled: Bool) {
        guard feature == .maintenance else { return }
        _ = enabled
    }
}

struct MaintenanceToolView: View {
    @AppStorage(NotchFeature.maintenance.defaultsKey) private var featureEnabled = true
    @State private var page: MaintenancePage = .disk
    @State private var activeScanID: String?
    @State private var scanMessage = ""
    @State private var pendingTrash: MaintenanceTrashRequest?
    @State private var alertMessage: String?
    @State private var memoryTask: Task<Void, Never>?

    @State private var diskItems: [MaintenanceItem] = []
    @State private var cleanItems: [MaintenanceItem] = []
    @State private var selectedCleanCategories: Set<String> = []
    @State private var appPath: String?
    @State private var uninstallItems: [MaintenanceItem] = []
    @State private var selectedLeftovers: Set<String> = []
    @State private var isDropTargeted = false
    @State private var duplicateRoot: String?
    @State private var duplicateItems: [MaintenanceItem] = []
    @State private var duplicateKeepPaths: Set<String> = []
    @State private var startupItems: [MaintenanceItem] = []
    @State private var memoryItems: [MaintenanceItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Maintenance tools", selection: $page) {
                ForEach(MaintenancePage.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .help("Choose a maintenance tool.")
            .accessibilityIdentifier("maintenance-page-picker")

            Group {
                switch page {
                case .disk: diskPage
                case .clean: cleanPage
                case .uninstall: uninstallPage
                case .duplicates: duplicatesPage
                case .startup: startupPage
                case .memory: memoryPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .confirmationDialog(
            pendingTrash?.title ?? "Move selected items to Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move \(pendingTrash?.paths.count ?? 0) items to Trash", role: .destructive) {
                confirmTrash()
            }
            .help("Move only the listed items to Trash.")
            .accessibilityIdentifier("maintenance-confirm-trash")
            Button("Cancel", role: .cancel) { pendingTrash = nil }
                .help("Keep the selected items.")
                .accessibilityIdentifier("maintenance-cancel-trash")
        } message: {
            Text(pendingTrash?.message ?? "")
        }
        .alert("Maintenance", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
                .help("Close this message.")
                .accessibilityIdentifier("maintenance-alert-ok")
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear { if page == .memory { startMemoryPolling() } }
        .onDisappear {
            cancelScan()
            stopMemoryPolling()
        }
        .onChange(of: page) { oldValue, newValue in
            if oldValue == .memory { stopMemoryPolling() }
            if activeScanID != nil { cancelScan() }
            if newValue == .memory { startMemoryPolling() }
        }
        .onChange(of: featureEnabled) { _, isEnabled in
            if isEnabled {
                if page == .memory { startMemoryPolling() }
            } else {
                cancelScan()
                stopMemoryPolling()
                pendingTrash = nil
            }
        }
        .accessibilityIdentifier("maintenance-tool-view")
    }

    private var diskPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                actionButton("Scan home", symbol: "externaldrive", id: "maintenance-disk-scan", help: "Measure the largest home folders, up to 20 seconds.") {
                    scan("disk", timeout: 22) { items, truncated in
                        diskItems = items
                        scanMessage = truncated ? "20-second limit reached; sizes may be partial." : "Top folders in your home folder."
                    }
                }
                if activeScanID != nil {
                    actionButton("Cancel", symbol: "xmark", id: "maintenance-disk-cancel", help: "Cancel the current scan.") { cancelScan() }
                }
                Spacer(minLength: 0)
                Text(scanMessage).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if diskItems.isEmpty {
                emptyCard("Scan home folders to compare their allocated disk space.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        let largest = max(1, diskItems.map(\.size).max() ?? 1)
                        ForEach(Array(diskItems.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 8) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .lineLimit(1)
                                    .frame(width: 150, alignment: .leading)
                                GeometryReader { geometry in
                                    Capsule().fill(.white.opacity(0.08))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(index == 0 ? .cyan : .white.opacity(0.55))
                                                .frame(width: max(3, geometry.size.width * CGFloat(item.size) / CGFloat(largest)))
                                        }
                                }
                                .frame(height: 7)
                                Text(MaintenanceFormat.bytes(item.size))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 75, alignment: .trailing)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("maintenance-disk-row-\(index)")
                        }
                    }
                }
                .frame(maxHeight: 132)
                .scrollIndicators(.automatic)
            }
        }
    }

    private var cleanPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                actionButton("Scan cleanup folders", symbol: "magnifyingglass", id: "maintenance-clean-scan", help: "Measure caches, logs, Xcode DerivedData and simulator caches.") {
                    scan("clean", timeout: 32) { items, _ in
                        cleanItems = items
                        selectedCleanCategories = Set(MaintenanceCleanupCategory.all.map(\.name))
                        scanMessage = "Select categories to move to Trash."
                    }
                }
                let selected = cleanItems.filter { selectedCleanCategories.contains($0.category) }
                actionButton("Move selected to Trash", symbol: "trash", id: "maintenance-clean-trash", help: "Review the exact item count and size before moving selected folders to Trash.", disabled: selected.isEmpty) {
                    pendingTrash = MaintenanceTrashRequest(
                        title: "Clean selected folders?",
                        paths: selected.map(\.path),
                        size: selected.reduce(0) { $0 + $1.size },
                        message: "\(selected.count) items • \(MaintenanceFormat.bytes(selected.reduce(0) { $0 + $1.size })) will move to Trash."
                    )
                }
                if activeScanID != nil {
                    actionButton("Cancel", symbol: "xmark", id: "maintenance-clean-cancel", help: "Cancel the current scan.") { cancelScan() }
                }
                Spacer(minLength: 0)
                Text(scanMessage).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            permissionNote
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(MaintenanceCleanupCategory.all) { category in
                        let matching = cleanItems.filter { $0.category == category.name }
                        let size = matching.reduce(0) { $0 + $1.size }
                        Toggle(isOn: Binding(
                            get: { selectedCleanCategories.contains(category.name) },
                            set: { isSelected in
                                if isSelected { selectedCleanCategories.insert(category.name) }
                                else { selectedCleanCategories.remove(category.name) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Image(systemName: category.symbol).frame(width: 16)
                                Text(category.name).lineLimit(1)
                                Spacer()
                                Text(cleanItems.isEmpty ? "Not scanned" : "\(matching.count) items · \(MaintenanceFormat.bytes(size))")
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 9).frame(minHeight: 28)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                        .help("Select \(category.name) for the Trash confirmation.")
                        .accessibilityIdentifier("maintenance-clean-category-\(category.id)")
                    }
                }
            }
            .frame(maxHeight: 96)
            .scrollIndicators(.automatic)
        }
    }

    private var permissionNote: some View {
        HStack(spacing: 6) {
            Text("Some library folders may need Full Disk Access.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button("Open Settings") {
                if let url = NotchPermission.fullDisk.settingsURL { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold, design: .rounded))
            .frame(minHeight: 28).contentShape(Rectangle())
            .help("Open Full Disk Access settings. Notch will not change permission settings.")
            .accessibilityIdentifier("maintenance-full-disk-settings")
        }
    }

    private var uninstallPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                actionButton("Choose App…", symbol: "app", id: "maintenance-uninstall-choose", help: "Pick an app from /Applications.") { chooseApplication() }
                actionButton("Scan leftovers", symbol: "magnifyingglass", id: "maintenance-uninstall-scan", help: "Find matching files in the supported Library folders.", disabled: appPath == nil) {
                    guard let appPath else { return }
                    scan("uninstall", args: ["appPath": appPath], timeout: 32) { items, _ in
                        uninstallItems = items
                        selectedLeftovers = Set(items.filter { !$0.isApp }.map(\.path))
                    }
                }
                let chosen = uninstallItems.filter { $0.isApp || selectedLeftovers.contains($0.path) }
                actionButton("Move to Trash", symbol: "trash", id: "maintenance-uninstall-trash", help: "Review the app and selected leftovers before moving them to Trash.", disabled: chosen.isEmpty) {
                    let bytes = chosen.reduce(0) { $0 + $1.size }
                    pendingTrash = MaintenanceTrashRequest(
                        title: "Uninstall selected app?",
                        paths: chosen.map(\.path),
                        size: bytes,
                        message: "\(chosen.count) items • \(MaintenanceFormat.bytes(bytes)) will move to Trash."
                    )
                }
                if activeScanID != nil {
                    actionButton("Cancel", symbol: "xmark", id: "maintenance-uninstall-cancel", help: "Cancel the current scan.") { cancelScan() }
                }
                Spacer(minLength: 0)
                Text(scanMessage).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Drop an app here or choose one from /Applications.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text("System apps and Notch are protected.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let appPath {
                    Button {
                        self.appPath = nil
                        uninstallItems = []
                        selectedLeftovers = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Clear the selected app.")
                    .accessibilityIdentifier("maintenance-uninstall-clear")
                    .id(appPath)
                }
            }
            .padding(8)
            .background(isDropTargeted ? .white.opacity(0.1) : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: acceptApplicationDrop)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(uninstallItems.filter { !$0.isApp }) { item in
                        Toggle(isOn: Binding(
                            get: { selectedLeftovers.contains(item.path) },
                            set: { if $0 { selectedLeftovers.insert(item.path) } else { selectedLeftovers.remove(item.path) } }
                        )) {
                            HStack(spacing: 6) {
                                Text(item.category.isEmpty ? URL(fileURLWithPath: item.path).lastPathComponent : item.category)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(MaintenanceFormat.bytes(item.size))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .toggleStyle(.checkbox).frame(minHeight: 28)
                        .help("Select this leftover for the Trash confirmation.")
                        .accessibilityIdentifier("maintenance-leftover-\(item.id.hashValue.magnitude)")
                    }
                }
            }
            .frame(maxHeight: 77)
            .scrollIndicators(.automatic)
        }
    }

    private var duplicatesPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                actionButton("Choose Folder…", symbol: "folder", id: "maintenance-duplicates-choose", help: "Pick a folder inside your home folder to scan.") { chooseDuplicateFolder() }
                actionButton("Scan duplicates", symbol: "doc.on.doc", id: "maintenance-duplicates-scan", help: "Compare file sizes, first 64 KB hashes, then full SHA-256 hashes. Maximum 50,000 files.", disabled: duplicateRoot == nil) {
                    guard let duplicateRoot else { return }
                    scan("duplicates", args: ["root": duplicateRoot], timeout: 122) { items, truncated in
                        duplicateItems = items
                        duplicateKeepPaths = DuplicateKeepPolicy.defaultKeepPaths(items)
                        scanMessage = truncated ? "Time limit reached; result may be partial." : ""
                    }
                }
                let trashItems = duplicateItems.filter { !duplicateKeepPaths.contains($0.path) }
                actionButton("Move copies to Trash", symbol: "trash", id: "maintenance-duplicates-trash", help: "Keep the newest selected file in each group; confirm the exact copies and size.", disabled: trashItems.isEmpty) {
                    let bytes = trashItems.reduce(0) { $0 + $1.size }
                    pendingTrash = MaintenanceTrashRequest(
                        title: "Move duplicate copies to Trash?",
                        paths: trashItems.map(\.path),
                        size: bytes,
                        message: "\(trashItems.count) duplicate files • \(MaintenanceFormat.bytes(bytes)) will move to Trash."
                    )
                }
                if activeScanID != nil {
                    actionButton("Cancel", symbol: "xmark", id: "maintenance-duplicates-cancel", help: "Cancel hashing and folder traversal.") { cancelScan() }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(.cyan)
                Text(duplicateRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Choose a folder to begin.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("\(duplicateGroups.count) groups")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                if !scanMessage.isEmpty {
                    Text(scanMessage).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).frame(minHeight: 28)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(duplicateGroups, id: \.key) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Duplicate group · \(group.items.count) files")
                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(group.items) { item in
                                Toggle(isOn: Binding(
                                    get: { duplicateKeepPaths.contains(item.path) },
                                    set: { if $0 { duplicateKeepPaths.insert(item.path) } else { duplicateKeepPaths.remove(item.path) } }
                                )) {
                                    HStack(spacing: 6) {
                                        Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1)
                                        Spacer(minLength: 3)
                                        Text(item.modified.map(MaintenanceFormat.date) ?? "")
                                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                        Text(MaintenanceFormat.bytes(item.size))
                                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                }
                                .toggleStyle(.checkbox).frame(minHeight: 28)
                                .help("Keep this copy. Newest copies are selected by default.")
                                .accessibilityIdentifier("maintenance-duplicate-keep-\(item.id.hashValue.magnitude)")
                            }
                        }
                        .padding(6)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxHeight: 106)
            .scrollIndicators(.automatic)
        }
    }

    private var startupPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                actionButton("Scan Login Items", symbol: "arrow.clockwise", id: "maintenance-startup-scan", help: "List user and system LaunchAgents with their SMAppService status.") {
                    scan("startup", timeout: 5) { items, _ in startupItems = items }
                }
                Spacer(minLength: 0)
                Text("System LaunchAgents are read-only.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(startupItems) { item in
                        HStack(spacing: 7) {
                            Image(systemName: item.readOnly ? "lock.fill" : "gearshape.2.fill")
                                .foregroundStyle(item.readOnly ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.cyan)).frame(width: 15)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label.isEmpty ? URL(fileURLWithPath: item.path).lastPathComponent : item.label)
                                    .font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
                                Text("\(item.status) · \(item.readOnly ? "/Library/LaunchAgents" : "~/Library/LaunchAgents")")
                                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 2)
                            Text(MaintenanceFormat.bytes(item.size))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            if item.readOnly {
                                Text("Read only").font(.system(size: 9)).foregroundStyle(.secondary)
                            } else {
                                actionButton("Disable", symbol: "trash", id: "maintenance-startup-disable-\(item.id.hashValue.magnitude)", help: "Move this plist to Trash after confirmation.") {
                                    pendingTrash = MaintenanceTrashRequest(
                                        title: "Disable this login item?",
                                        paths: [item.path],
                                        size: item.size,
                                        message: "1 plist • \(MaintenanceFormat.bytes(item.size)) will move to Trash."
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(maxHeight: 128)
            .scrollIndicators(.automatic)
        }
    }

    private var memoryPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "memorychip").foregroundStyle(.cyan)
                Text("Top 8 processes by memory")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer()
                Text("Refreshes every 3 seconds while visible")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(memoryItems.enumerated()), id: \.element.id) { _, item in
                        HStack(spacing: 7) {
                            Text(item.name.isEmpty ? "Process \(item.pid)" : item.name)
                                .font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
                            Spacer(minLength: 3)
                            Text(MaintenanceFormat.bytes(item.memory))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            if item.canQuit {
                                actionButton("Quit", symbol: "xmark", id: "maintenance-memory-quit-\(item.pid)", help: "Ask this app to quit normally. No force quit.") {
                                    Task {
                                        let response = await NotchSystemHelperClient.shared.perform("maintenance", "quit", args: ["pid": item.pid], timeout: 2)
                                        if response?["ok"] as? Bool != true {
                                            alertMessage = response?["error"] as? String ?? "The app did not quit."
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(maxHeight: 142)
            .scrollIndicators(.automatic)
        }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        id: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)
        .help(help)
        .accessibilityIdentifier(id)
    }

    private var duplicateGroups: [(key: String, items: [MaintenanceItem])] {
        let grouped = Dictionary(grouping: duplicateItems.filter { !$0.group.isEmpty }, by: \.group)
        return grouped.keys.sorted().map { (key: $0, items: grouped[$0] ?? []) }
    }

    private func emptyCard(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func scan(
        _ kind: String,
        args: [String: Any] = [:],
        timeout: TimeInterval,
        completion: @escaping ([MaintenanceItem], Bool) -> Void
    ) {
        cancelScan()
        let id = UUID().uuidString
        activeScanID = id
        scanMessage = "Scanning…"
        Task { @MainActor in
            let response = await NotchSystemHelperClient.shared.perform(
                "maintenance",
                "scan",
                args: args.merging(["kind": kind, "requestID": id]) { _, new in new },
                timeout: timeout
            )
            guard activeScanID == id else { return }
            activeScanID = nil
            guard let response, response["error"] == nil else {
                scanMessage = response?["error"] as? String ?? "Helper unavailable."
                return
            }
            let items = MaintenanceItem.parse(response)
            scanMessage = response["cancelled"] as? Bool == true ? "Scan cancelled." : ""
            completion(items, response["truncated"] as? Bool == true)
        }
    }

    private func cancelScan() {
        guard let id = activeScanID else { return }
        activeScanID = nil
        scanMessage = "Cancel requested."
        NotchSystemHelperClient.shared.perform("maintenance", "cancel", args: ["requestID": id], timeout: 2)
    }

    private func confirmTrash() {
        guard let request = pendingTrash else { return }
        pendingTrash = nil
        Task {
            let response = await NotchSystemHelperClient.shared.perform("maintenance", "trash", args: ["paths": request.paths], timeout: 30)
            guard let response else { alertMessage = "The helper did not respond."; return }
            let moved = response["moved"] as? Int ?? 0
            let errors = response["errors"] as? [String] ?? []
            alertMessage = errors.isEmpty
                ? "\(moved) items moved to Trash (\(MaintenanceFormat.bytes(response["freed"] as? Int64 ?? request.size)))."
                : "\(moved) items moved to Trash. \(errors.first ?? "Some items could not be moved.")"
            if page == .clean { cleanItems.removeAll { request.paths.contains($0.path) } }
            if page == .uninstall {
                uninstallItems.removeAll { request.paths.contains($0.path) }
                if request.paths.contains(appPath ?? "") { appPath = nil }
                selectedLeftovers.subtract(request.paths)
            }
            if page == .duplicates {
                duplicateItems.removeAll { request.paths.contains($0.path) }
                duplicateKeepPaths.subtract(request.paths)
            }
            if page == .startup { startupItems.removeAll { request.paths.contains($0.path) } }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to uninstall"
        panel.prompt = "Choose App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "app", url.deletingLastPathComponent().path == "/Applications" else {
            alertMessage = "Choose a user app directly inside /Applications."
            return
        }
        appPath = url.path
        uninstallItems = []
        selectedLeftovers = []
    }

    private func acceptApplicationDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "app",
                  url.deletingLastPathComponent().path == "/Applications" else { return }
            Task { @MainActor in
                appPath = url.path
                uninstallItems = []
                selectedLeftovers = []
            }
        }
        return true
    }

    private func chooseDuplicateFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to scan for duplicates"
        panel.prompt = "Choose Folder"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CleanupScope.isAllowed(path: url.path) else {
            alertMessage = "Choose a folder inside Documents, Desktop, Downloads, or another supported user folder."
            return
        }
        duplicateRoot = url.path
        duplicateItems = []
        duplicateKeepPaths = []
    }

    private func startMemoryPolling() {
        guard featureEnabled, page == .memory, memoryTask == nil else { return }
        memoryTask = Task { @MainActor in
            while !Task.isCancelled && featureEnabled && page == .memory {
                let response = await NotchSystemHelperClient.shared.perform("maintenance", "scan", args: ["kind": "memory", "requestID": UUID().uuidString], timeout: 2)
                if Task.isCancelled { break }
                if let response, response["error"] == nil {
                    memoryItems = MaintenanceItem.parse(response)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            memoryTask = nil
        }
    }

    private func stopMemoryPolling() {
        memoryTask?.cancel()
        memoryTask = nil
    }
}

private enum MaintenancePage: String, CaseIterable, Identifiable {
    case disk, clean, uninstall, duplicates, startup, memory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disk: "Disk"
        case .clean: "Clean"
        case .uninstall: "Uninstall"
        case .duplicates: "Duplicates"
        case .startup: "Startup"
        case .memory: "Memory"
        }
    }
}

private struct MaintenanceCleanupCategory: Identifiable {
    let name: String
    let symbol: String
    var id: String { name.lowercased().replacingOccurrences(of: " ", with: "-") }
    static let all = [
        Self(name: "Caches", symbol: "shippingbox"),
        Self(name: "Logs", symbol: "doc.text"),
        Self(name: "Xcode DerivedData", symbol: "hammer"),
        Self(name: "Simulator caches", symbol: "iphone")
    ]
}

private struct MaintenanceTrashRequest {
    let title: String
    let paths: [String]
    let size: Int64
    let message: String
}

struct MaintenanceItem: Identifiable, Hashable {
    let path: String
    let size: Int64
    var category = ""
    var isApp = false
    var group = ""
    var modified: Date?
    var label = ""
    var status = ""
    var readOnly = false
    var pid: Int32 = 0
    var name = ""
    var memory: Int64 = 0
    var canQuit = false

    var id: String { path }

    static func parse(_ response: [String: Any]?) -> [MaintenanceItem] {
        guard let rows = response?["items"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let path = row["path"] as? String, path.hasPrefix("/") else { return nil }
            let number = row["size"] as? NSNumber
            let timestamp = (row["modified"] as? NSNumber)?.doubleValue
            return MaintenanceItem(
                path: path,
                size: max(0, number?.int64Value ?? 0),
                category: row["category"] as? String ?? "",
                isApp: row["isApp"] as? Bool ?? false,
                group: row["group"] as? String ?? "",
                modified: timestamp.map(Date.init(timeIntervalSince1970:)),
                label: row["label"] as? String ?? "",
                status: row["status"] as? String ?? "",
                readOnly: row["readOnly"] as? Bool ?? false,
                pid: (row["pid"] as? NSNumber)?.int32Value ?? 0,
                name: row["name"] as? String ?? "",
                memory: max(0, (row["memory"] as? NSNumber)?.int64Value ?? 0),
                canQuit: row["canQuit"] as? Bool ?? false
            )
        }
    }
}

enum DuplicateKeepPolicy {
    static func defaultKeepPaths(_ items: [MaintenanceItem]) -> Set<String> {
        Dictionary(grouping: items.filter { !$0.group.isEmpty }, by: \.group)
            .values
            .compactMap { group in
                group.sorted {
                    let left = $0.modified ?? .distantPast
                    let right = $1.modified ?? .distantPast
                    if left != right { return left > right }
                    return $0.path < $1.path
                }.first?.path
            }
            .reduce(into: Set<String>()) { $0.insert($1) }
    }
}

enum MaintenanceFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The app mirrors the helper's conservative roots so folder selection and destructive
/// path handling can be tested before a request crosses XPC.
enum CleanupScope {
    static func allowedRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return [
            library.appendingPathComponent("Caches", isDirectory: true).path,
            library.appendingPathComponent("Logs", isDirectory: true).path,
            library.appendingPathComponent("Developer/Xcode/DerivedData", isDirectory: true).path,
            library.appendingPathComponent("Developer/CoreSimulator/Caches", isDirectory: true).path,
            library.appendingPathComponent("Application Support", isDirectory: true).path,
            library.appendingPathComponent("Preferences", isDirectory: true).path,
            library.appendingPathComponent("Containers", isDirectory: true).path,
            library.appendingPathComponent("Group Containers", isDirectory: true).path,
            library.appendingPathComponent("Saved Application State", isDirectory: true).path,
            library.appendingPathComponent("HTTPStorages", isDirectory: true).path,
            library.appendingPathComponent("WebKit", isDirectory: true).path,
            library.appendingPathComponent("LaunchAgents", isDirectory: true).path,
            home.appendingPathComponent("Desktop", isDirectory: true).path,
            home.appendingPathComponent("Documents", isDirectory: true).path,
            home.appendingPathComponent("Downloads", isDirectory: true).path,
            home.appendingPathComponent("Movies", isDirectory: true).path,
            home.appendingPathComponent("Music", isDirectory: true).path,
            home.appendingPathComponent("Pictures", isDirectory: true).path,
            home.appendingPathComponent("Public", isDirectory: true).path,
            "/Applications"
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    static func isAllowed(
        path: String,
        home: String = NSHomeDirectory(),
        roots: [String]? = nil,
        resolvedPath: String? = nil
    ) -> Bool {
        guard path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return false }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.path
        guard normalized != "/", normalized != homePath else { return false }
        let candidates = (roots ?? allowedRoots(home: URL(fileURLWithPath: home))).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard let root = candidates.first(where: { contains(normalized, root: $0) }) else { return false }
        let canonical = URL(fileURLWithPath: resolvedPath ?? URL(fileURLWithPath: path).resolvingSymlinksInPath().path).standardizedFileURL.path
        guard contains(canonical, root: root), canonical != homePath else { return false }
        if root == "/Applications" {
            return URL(fileURLWithPath: canonical).pathExtension.lowercased() == "app"
                && URL(fileURLWithPath: canonical).deletingLastPathComponent().path == "/Applications"
        }
        return true
    }

    private static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

enum LeftoverMatcher {
    static func matches(bundleID: String, name: String, candidate: String) -> Bool {
        let nameKey = compact(name)
        guard !candidate.isEmpty else { return false }
        if !bundleID.isEmpty {
            let text = candidate.lowercased() as NSString
            let range = text.range(of: bundleID.lowercased())
            if range.location != NSNotFound {
                let beforeIsBoundary = range.location == 0 || !isASCIIAlphaNumeric(text.character(at: range.location - 1))
                let end = NSMaxRange(range)
                let afterIsBoundary = end == text.length || !isASCIIAlphaNumeric(text.character(at: end))
                if beforeIsBoundary && afterIsBoundary { return true }
            }
        }
        return !nameKey.isEmpty && compact(candidate) == nameKey
    }

    private static func isASCIIAlphaNumeric(_ value: unichar) -> Bool {
        (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    private static func compact(_ value: String) -> String {
        value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}

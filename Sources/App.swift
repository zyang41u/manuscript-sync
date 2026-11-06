import AppKit
import SwiftUI

@main
struct ManuscriptSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Manuscript Sync", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ChangedFile: Identifiable {
    let id = UUID()
    let path: String
    let binary: Bool
    let lines: [DiffLine]
}

// Each side is nil when the sync moved nothing that way.
struct PanelChanges {
    let sent: [ChangedFile]?
    let received: [ChangedFile]?
}

@MainActor
final class AppModel: ObservableObject {
    enum Banner {
        case success(String)
        case failure(String)
    }

    @Published var repos: [String] = UserDefaults.standard.stringArray(forKey: "repos") ?? []
    @Published var selected: String? {
        didSet {
            UserDefaults.standard.set(selected, forKey: "selected")
            banner = nil
            changes = nil
            refresh()
        }
    }
    @Published var changeCount: Int?
    @Published var lastSync: Date?
    @Published var record: SyncRecord?
    @Published var banner: Banner?
    @Published var busy = false
    // Non-nil while the changes panel is open.
    @Published var changes: PanelChanges?
    @Published var showingClone = false

    init() {
        let saved = UserDefaults.standard.string(forKey: "selected")
        selected = saved.flatMap { repos.contains($0) ? $0 : nil } ?? repos.first
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard let path = selected else {
            changeCount = nil
            lastSync = nil
            record = nil
            return
        }
        lastSync = UserDefaults.standard.object(forKey: "lastSync." + path) as? Date
        record = UserDefaults.standard.data(forKey: "record." + path)
            .flatMap { try? JSONDecoder().decode(SyncRecord.self, from: $0) }
        let url = URL(fileURLWithPath: path)
        Task {
            let count = await Task.detached { SyncEngine.localChangeCount(url) }.value
            if selected == path { changeCount = count }
        }
    }

    func addRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a manuscript folder cloned from Overleaf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let root = SyncEngine.repoRoot(url) else {
            banner = .failure(SyncError.notARepo.message)
            return
        }
        if !repos.contains(root.path) {
            repos.append(root.path)
            UserDefaults.standard.set(repos, forKey: "repos")
        }
        selected = root.path
    }

    // Where new clones go: the last place used, else next to the current manuscript.
    var defaultCloneParent: URL {
        if let saved = UserDefaults.standard.string(forKey: "cloneParent"),
           FileManager.default.fileExists(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        if let selected { return URL(fileURLWithPath: selected).deletingLastPathComponent() }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    }

    // Returns an error message for the form, or nil once the manuscript is cloned and selected.
    func cloneManuscript(url: String, name: String, parent: URL, addGitignore: Bool) async -> String? {
        let result = await Task.detached {
            Result { try SyncEngine.clone(url, into: parent, name: name, addGitignore: addGitignore) }
        }.value
        switch result {
        case .success(let folder):
            UserDefaults.standard.set(parent.path, forKey: "cloneParent")
            let path = (SyncEngine.repoRoot(folder) ?? folder).path
            if !repos.contains(path) {
                repos.append(path)
                UserDefaults.standard.set(repos, forKey: "repos")
            }
            selected = path
            let pending = (SyncEngine.localChangeCount(folder) ?? 0) > 0
            banner = .success("Cloned \(folder.lastPathComponent). "
                + (pending ? "The new .gitignore goes to Overleaf with your next sync." : "It's ready to sync."))
            return nil
        case .failure(let error):
            return (error as? SyncError)?.message ?? error.localizedDescription
        }
    }

    // Only forgets the folder; nothing on disk is touched.
    func removeSelected() {
        guard let path = selected else { return }
        repos.removeAll { $0 == path }
        UserDefaults.standard.set(repos, forKey: "repos")
        selected = repos.first
    }

    func sync() {
        guard let path = selected, !busy else { return }
        busy = true
        banner = nil
        let url = URL(fileURLWithPath: path)
        Task {
            let result = await Task.detached { Result { try SyncEngine.sync(url) } }.value
            busy = false
            switch result {
            case .success(let outcome):
                let now = Date()
                UserDefaults.standard.set(now, forKey: "lastSync." + path)
                let record = SyncRecord(date: now, sent: outcome.sent, received: outcome.received)
                if let data = try? JSONEncoder().encode(record) {
                    UserDefaults.standard.set(data, forKey: "record." + path)
                }
                UserDefaults.standard.removeObject(forKey: "incoming." + path)  // key used before sent changes were shown
                banner = .success(outcome.summary)
            case .failure(let error):
                banner = .failure((error as? SyncError)?.message ?? error.localizedDescription)
            }
            refresh()
            if changes != nil { await showChanges() }
        }
    }

    func showChanges() async {
        guard let path = selected, let record else { return }
        let url = URL(fileURLWithPath: path)
        changes = await Task.detached {
            func load(_ range: ChangeRange?) -> [ChangedFile]? {
                range.map { range in
                    SyncEngine.diff(url, range).map {
                        ChangedFile(path: $0.path, binary: $0.binary, lines: SyncEngine.lines(of: $0))
                    }
                }
            }
            return PanelChanges(sent: load(record.sent), received: load(record.received))
        }.value
    }

    func hideChanges() {
        changes = nil
    }
}

let syncDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    f.doesRelativeDateFormatting = true
    return f
}()

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // A fixed size either way, so the window resizes itself to fit; the panel scrolls.
        HStack(alignment: .top, spacing: 0) {
            controls
                .padding(20)
                .frame(width: 380)
                .frame(height: model.changes == nil ? nil : 560, alignment: .top)
            if model.changes != nil {
                Divider()
                ChangesPanel()
                    .frame(width: 600, height: 560)
            }
        }
        .sheet(isPresented: $model.showingClone) {
            CloneSheet(parent: model.defaultCloneParent)
                .environmentObject(model)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.repos.isEmpty {
                emptyState
            } else {
                picker
                status
                syncButton
                bannerView
                lastSyncView
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clone a manuscript from Overleaf, or add a folder you already cloned.")
                .foregroundStyle(.secondary)
            Button {
                model.showingClone = true
            } label: {
                Label("Clone from Overleaf", systemImage: "icloud.and.arrow.down")
            }
            Button {
                model.addRepo()
            } label: {
                Label("Add manuscript folder", systemImage: "folder.badge.plus")
            }
            bannerView
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Manuscript").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Picker("Manuscript", selection: $model.selected) {
                    ForEach(model.repos, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(Optional(path))
                    }
                }
                .labelsHidden()
                Button {
                    model.showingClone = true
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                }
                .help("Clone a new manuscript from Overleaf")
                .accessibilityLabel("Clone from Overleaf")
                Button {
                    model.addRepo()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Add a manuscript folder")
                .accessibilityLabel("Add manuscript folder")
                Button {
                    model.removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .help("Remove from this list (the folder is not deleted)")
                .accessibilityLabel("Remove manuscript from list")
                .disabled(model.selected == nil)
            }
            if let path = model.selected {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
        }
    }

    private var status: some View {
        VStack(spacing: 6) {
            row("Local changes", model.changeCount.map { $0 == 0 ? "none" : plural($0, "file") } ?? "–")
            row("Last sync", model.lastSync.map { syncDateFormatter.string(from: $0) } ?? "never")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }

    private var syncButton: some View {
        Button {
            model.sync()
        } label: {
            HStack(spacing: 6) {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(model.busy ? "Syncing…" : "Sync to Overleaf")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.busy || model.selected == nil)
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var bannerView: some View {
        switch model.banner {
        case .success(let text):
            Label(text, systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var lastSyncView: some View {
        if let record = model.record {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("In the last sync").font(.caption).foregroundStyle(.secondary)
                direction("arrow.down.circle", "Received", record.received?.files, empty: "nothing new")
                direction("arrow.up.circle", "Sent", record.sent?.files, empty: "nothing")
                Button {
                    if model.changes == nil {
                        Task { await model.showChanges() }
                    } else {
                        model.hideChanges()
                    }
                } label: {
                    Label(model.changes == nil ? "View changes" : "Hide changes", systemImage: "sidebar.right")
                }
                .disabled(record.sent == nil && record.received == nil)
            }
        }
    }

    private func direction(_ icon: String, _ label: String, _ files: [String]?, empty: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(files?.joined(separator: ", ") ?? empty)
                .foregroundStyle(files == nil ? .secondary : .primary)
                .lineLimit(2)
        }
        .font(.callout)
    }
}

struct CloneSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var name = ""
    @State private var parent: URL
    @State private var addGitignore = true
    @State private var error: String?
    @State private var working = false

    init(parent: URL) {
        _parent = State(initialValue: parent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone a manuscript from Overleaf").font(.headline)
            field("Overleaf link") {
                TextField("https://git.overleaf.com/…", text: $link)
                    .onChange(of: link) { _, newValue in
                        error = nil
                        // A pasted `git clone <link> <folder>` command also names the folder.
                        if name.isEmpty, let suggested = SyncEngine.parseCloneInput(newValue)?.name { name = suggested }
                    }
            }
            field("Folder name") {
                TextField("v2-overleaf", text: $name)
                    .onChange(of: name) { _, _ in error = nil }
            }
            field("Location") {
                HStack {
                    Text(parent.path)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(parent.path)
                    Spacer()
                    Button("Choose…") { chooseParent() }
                }
            }
            Toggle("Add a .gitignore for LaTeX build files", isOn: $addGitignore)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Cloning…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clone") { start() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .disabled(working)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = parent
        panel.prompt = "Choose"
        panel.message = "Choose where the manuscript folder goes"
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }

    private func start() {
        guard let parsed = SyncEngine.parseCloneInput(link) else {
            error = link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Paste the Overleaf link first." : SyncError.badLink.message
            return
        }
        working = true
        error = nil
        Task {
            let message = await model.cloneManuscript(url: parsed.url, name: name, parent: parent, addGitignore: addGitignore)
            working = false
            if let message { error = message } else { dismiss() }
        }
    }
}

// The editor-like pane that opens to the right of the controls.
struct ChangesPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes in the last sync").font(.headline)
                    if let record = model.record {
                        Text(syncDateFormatter.string(from: record.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    model.hideChanges()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide changes")
                .accessibilityLabel("Hide changes")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    group("Received from Overleaf", icon: "arrow.down.circle.fill",
                          files: model.changes?.received, empty: "Nothing new from Overleaf in this sync.")
                    group("Sent to Overleaf", icon: "arrow.up.circle.fill",
                          files: model.changes?.sent, empty: "Nothing sent in this sync.")
                }
                .padding(.bottom, 12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private func group(_ title: String, icon: String, files: [ChangedFile]?, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            if let files {
                if files.isEmpty {
                    Text("These changes are no longer available in this folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        ForEach(files ?? []) { file in
            Section {
                if file.binary {
                    Text("Binary file changed (for example a figure).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                } else {
                    ForEach(file.lines) { LineRow(line: $0) }
                }
            } header: {
                FileHeader(path: file.path, icon: icon)
            }
        }
    }
}

struct FileHeader: View {
    let path: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(path).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct LineRow: View {
    let line: DiffLine

    var body: some View {
        if line.isHunk {
            HStack(spacing: 10) {
                Text("⋯").frame(width: 36, alignment: .trailing)
                Text("line \(line.number ?? 1)")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(line.number.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
                Text(render(line.segments))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(2)
            .padding(.vertical, 1)
            .padding(.trailing, 14)
            .overlay(alignment: .leading) {
                if line.changed { Rectangle().fill(Color.accentColor).frame(width: 3) }
            }
        }
    }

    private func render(_ segments: [DiffSegment]) -> AttributedString {
        var out = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .added:
                piece.swiftUI.foregroundColor = .green
                piece.swiftUI.backgroundColor = Color.green.opacity(0.15)
            case .removed:
                piece.swiftUI.foregroundColor = .red
                piece.swiftUI.backgroundColor = Color.red.opacity(0.12)
                piece.swiftUI.strikethroughStyle = .single
            default:
                break
            }
            out += piece
        }
        return out
    }
}

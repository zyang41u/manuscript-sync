import Foundation

// Git plumbing for the app: one sync = commit everything, pull, push.

struct GitResult {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
}

enum Git {
    // Prefer the git used in Terminal, so the Overleaf token saved in the Keychain is found.
    static let executable: String = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }()

    @discardableResult
    static func run(_ args: [String], in dir: URL) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-c", "core.quotePath=false"] + args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"  // fail instead of waiting for a password nobody can type
        env["GIT_EDITOR"] = "true"
        env["LC_ALL"] = "C"
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return GitResult(status: -1, out: "", err: error.localizedDescription)
        }
        // Read stderr on another thread so a full pipe can't block git.
        var errData = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        reader.wait()
        process.waitUntilExit()
        return GitResult(status: process.terminationStatus,
                         out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self))
    }
}

enum SyncError: Error, Equatable {
    case notARepo
    case noRemote
    case conflict([String])
    case unresolved([String])
    case auth
    case network
    case remoteMoved
    case projectNotFound
    case badLink
    case badFolderName
    case folderExists(String)
    case git(String)

    var message: String {
        switch self {
        case .notARepo:
            return "This folder isn't a git repository. Clone the Overleaf project first, then add its folder."
        case .noRemote:
            return "This folder has no Overleaf remote to sync with."
        case .conflict(let files):
            return "Your edits and Overleaf's edits overlap in: \(files.joined(separator: ", ")). "
                + "Open each file, keep the text you want, delete the <<<<<<<, ======= and >>>>>>> lines, save, then click Sync again."
        case .unresolved(let files):
            return "Conflict markers are still in: \(files.joined(separator: ", ")). "
                + "Delete the <<<<<<<, ======= and >>>>>>> lines, save, then click Sync again."
        case .auth:
            return "Overleaf rejected the login. Your Git token may be missing or expired: make a new one in Overleaf "
                + "(Account Settings → Git Integration), then run git push once in Terminal so the Keychain saves it."
        case .network:
            return "Couldn't reach Overleaf. Check your internet connection and try again."
        case .remoteMoved:
            return "Overleaf changed while syncing. Click Sync again."
        case .projectNotFound:
            return "Overleaf couldn't find that project. Check the link, and that your account can open the project."
        case .badLink:
            return "That doesn't look like an Overleaf project link. Copy the Git link (Overleaf menu → Git) "
                + "or the project's address from the browser."
        case .badFolderName:
            return "Enter a folder name without slashes."
        case .folderExists(let name):
            return "A folder named \(name) already exists there. Pick another name."
        case .git(let detail):
            return "Git error: \(detail)"
        }
    }
}

// Two commits whose diff is one direction of a sync.
struct ChangeRange: Codable, Equatable {
    let start: String
    let end: String
    let files: [String]
}

// What the last sync sent and received; the app keeps one per manuscript.
struct SyncRecord: Codable {
    let date: Date
    let sent: ChangeRange?
    let received: ChangeRange?
}

struct SyncOutcome {
    let sentFiles: Int
    let pushed: Bool
    let sent: ChangeRange?
    let received: ChangeRange?

    var summary: String {
        var parts: [String] = []
        if sentFiles > 0 {
            parts.append("sent \(plural(sentFiles, "file"))")
        } else if pushed {
            parts.append("sent your earlier commits")
        }
        if let received {
            parts.append("got changes in \(plural(received.files.count, "file")) from Overleaf")
        }
        return parts.isEmpty ? "Already in sync. Nothing to send or receive." : "Synced: " + parts.joined(separator: ", ") + "."
    }
}

struct DiffSegment: Equatable {
    enum Kind: Equatable {
        case same, added, removed, newline
        case hunk(Int)  // a new hunk starts at this line of the new file
    }
    let kind: Kind
    let text: String
}

struct DiffLine: Identifiable {
    let id: Int
    let number: Int?  // line in the new file; nil for a hunk marker or a fully deleted line
    let isHunk: Bool
    let segments: [DiffSegment]
    var changed: Bool { segments.contains { $0.kind == .added || $0.kind == .removed } }
}

struct FileDiff: Identifiable {
    let id = UUID()
    let path: String
    var binary = false
    var segments: [DiffSegment] = []
}

func plural(_ n: Int, _ word: String) -> String {
    "\(n) \(word)\(n == 1 ? "" : "s")"
}

enum SyncEngine {
    static func repoRoot(_ dir: URL) -> URL? {
        let r = Git.run(["rev-parse", "--show-toplevel"], in: dir)
        guard r.ok else { return nil }
        return URL(fileURLWithPath: r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func localChangeCount(_ repo: URL) -> Int? {
        let r = Git.run(["status", "--porcelain", "--untracked-files=all"], in: repo)
        guard r.ok else { return nil }
        return lines(r.out).count
    }

    static func sync(_ repo: URL, now: Date = Date()) throws -> SyncOutcome {
        guard repoRoot(repo) != nil else { throw SyncError.notARepo }
        guard Git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repo).ok else {
            throw SyncError.noRemote
        }

        // A previous sync stopped on a conflict: only continue once the markers are gone.
        let midMerge = Git.run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repo).ok
        if midMerge {
            let unmerged = lines(Git.run(["diff", "--name-only", "--diff-filter=U"], in: repo).out)
            let marked = unmerged.filter { hasConflictMarkers(repo.appendingPathComponent($0)) }
            if !marked.isEmpty { throw SyncError.unresolved(marked) }
        }

        let sentFiles = localChangeCount(repo) ?? 0
        let ourSide = head(repo)
        try check(Git.run(["add", "-A"], in: repo))
        let hasStaged = !Git.run(["diff", "--cached", "--quiet"], in: repo).ok
        if hasStaged || midMerge {
            try check(Git.run(["commit", "-m", commitMessage(now)], in: repo))
        }
        // What Overleaf sent is everything between our own side and the merged result.
        let start = midMerge ? ourSide : head(repo)

        let pull = Git.run(["pull", "--no-rebase", "--ff", "--no-edit"], in: repo)
        if !pull.ok {
            let conflicted = lines(Git.run(["diff", "--name-only", "--diff-filter=U"], in: repo).out)
            if !conflicted.isEmpty { throw SyncError.conflict(conflicted) }
            throw classify(pull.err)
        }

        let received = changeRange(repo, from: start, to: head(repo))

        let ahead = Int(Git.run(["rev-list", "--count", "@{u}..HEAD"], in: repo).out
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        var sent: ChangeRange?
        if ahead > 0 {
            // What we push is everything Overleaf doesn't have yet.
            sent = changeRange(repo, from: revision(repo, "@{u}"), to: head(repo))
            let push = Git.run(["push"], in: repo)
            if !push.ok {
                let err = push.err.lowercased()
                if err.contains("rejected") || err.contains("fetch first") || err.contains("non-fast-forward") {
                    throw SyncError.remoteMoved
                }
                throw classify(push.err)
            }
        }
        return SyncOutcome(sentFiles: sentFiles, pushed: ahead > 0, sent: sent, received: received)
    }

    // Same ignore list as the first manuscript: macOS files, TeXPad output, LaTeX build files.
    static let latexGitignore = """
        # macOS
        .DS_Store
        ._*

        # TeXPad build folder
        .texpadtmp/

        # Local compiled PDF (Overleaf compiles its own)
        /main.pdf

        # LaTeX build artifacts
        *.aux
        *.bbl
        *.blg
        *.log
        *.out
        *.toc
        *.fls
        *.fdb_latexmk
        *.synctex.gz

        """

    // Accepts a Git link, a browser project link, a bare project id, or a whole `git clone <link> <folder>` command.
    static func parseCloneInput(_ input: String) -> (url: String, name: String?)? {
        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let index = tokens.firstIndex(where: { overleafGitURL($0) != nil }),
              let url = overleafGitURL(tokens[index]) else { return nil }
        let name = tokens[(index + 1)...].first { !$0.hasPrefix("-") }
        return (url, name)
    }

    static func clone(_ url: String, into parent: URL, name rawName: String, addGitignore: Bool) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw SyncError.badFolderName }
        let folder = parent.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: folder.path) { throw SyncError.folderExists(name) }
        let r = Git.run(["clone", url, folder.path], in: parent)
        if !r.ok {
            try? FileManager.default.removeItem(at: folder)  // the folder didn't exist before this clone
            throw classify(r.err)
        }
        let ignore = folder.appendingPathComponent(".gitignore")
        if addGitignore, !FileManager.default.fileExists(atPath: ignore.path) {
            try latexGitignore.write(to: ignore, atomically: true, encoding: .utf8)
        }
        return folder
    }

    private static func overleafGitURL(_ token: String) -> String? {
        func isProjectID(_ s: Substring) -> Bool { s.count == 24 && s.allSatisfy(\.isHexDigit) }
        if isProjectID(Substring(token)) { return "https://git.overleaf.com/\(token)" }
        guard let url = URL(string: token), let host = url.host?.lowercased(), host.hasSuffix("overleaf.com") else {
            return nil
        }
        let parts = url.path.split(separator: "/")
        if host == "git.overleaf.com", parts.count == 1, isProjectID(parts[0]) { return token }
        if let p = parts.firstIndex(of: "project"), p + 1 < parts.count, isProjectID(parts[p + 1]) {
            return "https://git.overleaf.com/\(parts[p + 1])"
        }
        return nil
    }

    static func diff(_ repo: URL, _ range: ChangeRange) -> [FileDiff] {
        let r = Git.run(["diff", "--word-diff=porcelain", "--no-color", "--no-ext-diff", range.start, range.end], in: repo)
        return r.ok ? parseWordDiff(r.out) : []
    }

    // Word diff, because a LaTeX paragraph is usually one long line.
    static func parseWordDiff(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var inHunk = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                let header = String(line)
                let path = header.range(of: " b/", options: .backwards).map { String(header[$0.upperBound...]) } ?? header
                files.append(FileDiff(path: path))
                inHunk = false
                continue
            }
            guard !files.isEmpty else { continue }
            let last = files.count - 1
            if line.hasPrefix("@@") {
                // "@@ -a,b +c,d @@": c is where the hunk starts in the new file.
                let newStart = line.split(separator: " ").first { $0.hasPrefix("+") }
                    .flatMap { Int($0.dropFirst().prefix { $0.isNumber }) } ?? 1
                files[last].segments.append(DiffSegment(kind: .hunk(newStart), text: ""))
                inHunk = true
                continue
            }
            if !inHunk {
                if line.hasPrefix("Binary files") { files[last].binary = true }
                continue
            }
            guard let marker = line.first else { continue }
            let rest = String(line.dropFirst())
            switch marker {
            case " ": files[last].segments.append(DiffSegment(kind: .same, text: rest))
            case "+": files[last].segments.append(DiffSegment(kind: .added, text: rest))
            case "-": files[last].segments.append(DiffSegment(kind: .removed, text: rest))
            case "~": files[last].segments.append(DiffSegment(kind: .newline, text: ""))
            default: continue
            }
        }
        return files
    }

    // Groups a file's segments into numbered lines, as an editor would show them.
    static func lines(of file: FileDiff) -> [DiffLine] {
        var out: [DiffLine] = []
        var current: [DiffSegment] = []
        var next = 1
        func endLine() {
            // A line with only removed words no longer exists in the new file. An empty one is a blank line.
            let inNewFile = current.isEmpty || current.contains { $0.kind == .same || $0.kind == .added }
            out.append(DiffLine(id: out.count, number: inNewFile ? next : nil, isHunk: false, segments: current))
            if inNewFile { next += 1 }
            current = []
        }
        for segment in file.segments {
            switch segment.kind {
            case .hunk(let start):
                if !current.isEmpty { endLine() }
                out.append(DiffLine(id: out.count, number: start, isHunk: true, segments: []))
                next = start
            case .newline:
                endLine()
            default:
                current.append(segment)
            }
        }
        if !current.isEmpty { endLine() }
        return out
    }

    static func classify(_ err: String) -> SyncError {
        let e = err.lowercased()
        let authSigns = ["authentication failed", "terminal prompts disabled", "could not read username",
                         "could not read password", "error: 401", "error: 403", " 403", " 401"]
        if authSigns.contains(where: { e.contains($0) }) { return .auth }
        let networkSigns = ["could not resolve host", "failed to connect", "timed out", "network is unreachable",
                            "unable to access", "connection refused"]
        if networkSigns.contains(where: { e.contains($0) }) { return .network }
        if e.contains("repository") && e.contains("not found") { return .projectNotFound }
        let detail = lines(err).suffix(3).joined(separator: " ")
        return .git(detail.isEmpty ? "unknown failure" : detail)
    }

    private static func head(_ repo: URL) -> String? {
        revision(repo, "HEAD")
    }

    private static func revision(_ repo: URL, _ name: String) -> String? {
        let r = Git.run(["rev-parse", "-q", "--verify", name], in: repo)
        return r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    private static func changeRange(_ repo: URL, from start: String?, to end: String?) -> ChangeRange? {
        guard let start, let end, start != end else { return nil }
        let files = lines(Git.run(["diff", "--name-only", start, end], in: repo).out)
        return files.isEmpty ? nil : ChangeRange(start: start, end: end, files: files)
    }

    private static func check(_ r: GitResult) throws {
        if !r.ok { throw classify(r.err.isEmpty ? r.out : r.err) }
    }

    private static func commitMessage(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Sync \(f.string(from: now))"
    }

    private static func hasConflictMarkers(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

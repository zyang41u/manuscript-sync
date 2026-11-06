import Foundation

// Runs SyncEngine against a local bare repo standing in for Overleaf.
// "me" is the local manuscript folder, "boss" edits from another clone.

var failures = 0

func expect(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond {
        print("  ok    \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name) (Tests/main.swift:\(line))")
    }
}

@discardableResult
func git(_ dir: URL, _ args: String...) -> GitResult {
    let r = Git.run(args, in: dir)
    if !r.ok { print("    git \(args.joined(separator: " ")) failed: \(r.err)") }
    return r
}

func write(_ dir: URL, _ name: String, _ text: String) {
    try! text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

func read(_ dir: URL, _ name: String) -> String {
    (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
}

func syncError(_ repo: URL) -> SyncError? {
    do {
        _ = try SyncEngine.sync(repo)
        return nil
    } catch {
        return error as? SyncError
    }
}

func added(_ repo: URL, _ range: ChangeRange?, _ file: String = "main.tex") -> String {
    guard let range else { return "" }
    return SyncEngine.diff(repo, range).first { $0.path == file }?
        .segments.filter { $0.kind == .added }.map(\.text).joined() ?? ""
}

func paper(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

let base = ["Weeds compete with crops.", "Line two.", "Line three.", "Line four.",
            "Line five.", "Line six.", "Plants grow in soil."]

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
    .appendingPathComponent("run-\(UUID().uuidString.prefix(8))")
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let remote = root.appendingPathComponent("overleaf.git")
let me = root.appendingPathComponent("me")
let boss = root.appendingPathComponent("boss")

git(root, "init", "--bare", "-b", "main", remote.path)
git(root, "clone", "-q", remote.path, me.path)
git(me, "symbolic-ref", "HEAD", "refs/heads/main")
git(me, "config", "user.name", "Me")
git(me, "config", "user.email", "me@example.com")
write(me, "main.tex", paper(base))
git(me, "add", "-A")
git(me, "commit", "-q", "-m", "init")
git(me, "push", "-q", "-u", "origin", "main")
git(root, "clone", "-q", remote.path, boss.path)
git(boss, "config", "user.name", "Boss")
git(boss, "config", "user.email", "boss@example.com")

print("nothing to do")
do {
    let o = try SyncEngine.sync(me)
    expect(o.sentFiles == 0 && !o.pushed, "no commit, no push")
    expect(o.sent == nil && o.received == nil, "nothing sent, nothing received")
    expect(o.summary == "Already in sync. Nothing to send or receive.", "summary says already in sync")
} catch { expect(false, "sync threw \(error)") }

print("local edit is pushed and recorded as sent")
var mine = base
mine[0] = "Weeds strongly compete with crops."
write(me, "main.tex", paper(mine))
write(me, "notes.tex", "new file\n")
expect(SyncEngine.localChangeCount(me) == 2, "local change count sees edit and new file")
do {
    let o = try SyncEngine.sync(me)
    expect(o.sentFiles == 2 && o.pushed, "sent 2 files")
    expect(o.sent?.files == ["main.tex", "notes.tex"], "sent range lists both files")
    expect(added(me, o.sent).contains("strongly"), "sent diff shows my new word")
    expect(o.received == nil, "nothing received")
    expect(o.summary == "Synced: sent 2 files.", "summary: \(o.summary)")
    expect(SyncEngine.localChangeCount(me) == 0, "working tree clean after sync")
    git(boss, "pull", "-q")
    expect(read(boss, "main.tex") == paper(mine), "boss sees my edit")
    expect(git(me, "log", "-1", "--format=%s").out.hasPrefix("Sync "), "commit message is a timestamp")
} catch { expect(false, "sync threw \(error)") }

print("boss edit is received and shown as a word diff")
var bossText = mine
bossText[6] = "Plants grow in sandy soil."
write(boss, "main.tex", paper(bossText))
git(boss, "commit", "-q", "-am", "boss edit")
git(boss, "push", "-q")
do {
    let o = try SyncEngine.sync(me)
    expect(o.sentFiles == 0 && !o.pushed && o.sent == nil, "nothing sent")
    expect(o.received?.files == ["main.tex"], "received main.tex")
    expect(read(me, "main.tex") == paper(bossText), "my copy has boss's edit")
    if let received = o.received {
        let diff = SyncEngine.diff(me, received)
        expect(diff.count == 1 && diff[0].path == "main.tex", "diff covers main.tex")
        expect(added(me, received) == "sandy", "added words are 'sandy' (got '\(added(me, received))')")
        expect(!(diff.first?.segments.contains { $0.kind == .removed } ?? true), "no words removed")
    }
    expect(o.summary == "Synced: got changes in 1 file from Overleaf.", "summary: \(o.summary)")
} catch { expect(false, "sync threw \(error)") }

print("both edit different lines: each side's changes kept apart")
git(boss, "pull", "-q")
mine = bossText
mine[0] = "Weeds compete hard with crops."
write(me, "main.tex", paper(mine))
bossText[6] = "Plants grow in sandy loam."
write(boss, "main.tex", paper(bossText))
git(boss, "commit", "-q", "-am", "boss edit 2")
git(boss, "push", "-q")
do {
    let o = try SyncEngine.sync(me)
    expect(o.sentFiles == 1 && o.pushed, "my edit sent")
    let merged = read(me, "main.tex")
    expect(merged.contains("compete hard") && merged.contains("sandy loam"), "both edits kept")
    let sentWords = added(me, o.sent)
    let receivedWords = added(me, o.received)
    expect(sentWords.contains("hard") && !sentWords.contains("loam"), "sent diff shows only my edit (got '\(sentWords)')")
    expect(receivedWords.contains("loam") && !receivedWords.contains("hard"), "received diff shows only boss's edit (got '\(receivedWords)')")
    git(boss, "pull", "-q")
    expect(read(boss, "main.tex") == merged, "boss gets the merged file")
} catch { expect(false, "sync threw \(error)") }

print("both edit the same line: conflict, then fixed")
mine = read(me, "main.tex").split(separator: "\n").map(String.init)
var mineConflict = mine
mineConflict[3] = "Line four, my version."
write(me, "main.tex", paper(mineConflict))
var bossConflict = mine
bossConflict[3] = "Line four, boss version."
write(boss, "main.tex", paper(bossConflict))
git(boss, "commit", "-q", "-am", "boss conflict")
git(boss, "push", "-q")
expect(syncError(me) == .conflict(["main.tex"]), "first sync reports the conflict")
expect(read(me, "main.tex").contains("<<<<<<<"), "file holds conflict markers")
expect(syncError(me) == .unresolved(["main.tex"]), "syncing again with markers left is refused")
var resolved = mine
resolved[3] = "Line four, agreed version."
write(me, "main.tex", paper(resolved))
do {
    let o = try SyncEngine.sync(me)
    expect(o.pushed, "resolution pushed")
    expect(o.sent?.files == ["main.tex"], "resolution recorded as sent")
    expect(added(me, o.sent).contains("agreed"), "sent diff shows the agreed text")
    expect(o.received?.files == ["main.tex"], "boss's side recorded as received")
    git(boss, "pull", "-q")
    expect(read(boss, "main.tex") == paper(resolved), "boss gets the agreed version")
    expect(SyncEngine.localChangeCount(me) == 0, "clean after resolving")
} catch { expect(false, "sync threw \(error)") }

print("binary files and earlier commits")
try! Data([0, 1, 2, 3, 0, 255]).write(to: boss.appendingPathComponent("fig.pdf"))
git(boss, "add", "fig.pdf")
git(boss, "commit", "-q", "-m", "figure")
git(boss, "push", "-q")
write(me, "notes.tex", "edited outside the app\n")
git(me, "commit", "-q", "-am", "manual commit")
do {
    let o = try SyncEngine.sync(me)
    expect(o.sentFiles == 0 && o.pushed, "earlier commit pushed")
    expect(o.sent?.files == ["notes.tex"], "earlier commit recorded as sent")
    expect(o.summary.contains("sent your earlier commits"), "summary: \(o.summary)")
    if let received = o.received {
        let fig = SyncEngine.diff(me, received).first { $0.path == "fig.pdf" }
        expect(fig?.binary == true, "figure marked as binary")
    } else { expect(false, "figure received") }
} catch { expect(false, "sync threw \(error)") }

print("errors")
let plain = root.appendingPathComponent("plain")
try! FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
expect(syncError(plain) == .notARepo, "plain folder is not a repo")
expect(SyncEngine.classify("fatal: Authentication failed for 'https://git.overleaf.com/abc/'") == .auth, "auth failure")
expect(SyncEngine.classify("fatal: could not read Username for 'https://git.overleaf.com': terminal prompts disabled") == .auth, "missing token")
expect(SyncEngine.classify("fatal: unable to access 'https://git.overleaf.com/abc/': The requested URL returned error: 403") == .auth, "403")
expect(SyncEngine.classify("fatal: unable to access 'https://git.overleaf.com/abc/': Could not resolve host: git.overleaf.com") == .network, "offline")
let noRemote = root.appendingPathComponent("noremote")
git(root, "init", "-q", "-b", "main", noRemote.path)
expect(syncError(noRemote) == .noRemote, "repo without remote")

print("reading Overleaf links")
let id = "0123456789abcdef01234567"
func parsed(_ s: String) -> String? { SyncEngine.parseCloneInput(s)?.url }
expect(parsed("https://git.overleaf.com/\(id)") == "https://git.overleaf.com/\(id)", "git link kept")
expect(parsed("https://git@git.overleaf.com/\(id)") == "https://git@git.overleaf.com/\(id)", "git link with user kept")
expect(parsed("  https://www.overleaf.com/project/\(id)  ") == "https://git.overleaf.com/\(id)", "project link becomes git link")
expect(parsed(id) == "https://git.overleaf.com/\(id)", "bare project id")
expect(SyncEngine.parseCloneInput("git clone https://git@git.overleaf.com/\(id) v2-overleaf").map { [$0.url, $0.name ?? ""] }
       == ["https://git@git.overleaf.com/\(id)", "v2-overleaf"], "whole git clone command gives link and folder")
expect(SyncEngine.parseCloneInput("https://git.overleaf.com/\(id)")?.name == nil, "plain link has no folder name")
expect(parsed("https://www.overleaf.com/read/abcdefghijkl") == nil, "read-only share link refused")
expect(parsed("hello world") == nil, "random text refused")

print("cloning a new manuscript")
let parent = root.appendingPathComponent("papers")
try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
do {
    let folder = try SyncEngine.clone(remote.path, into: parent, name: "new-paper", addGitignore: true)
    expect(folder.lastPathComponent == "new-paper", "clone lands in the named folder")
    expect(read(folder, "main.tex") == read(me, "main.tex"), "clone has the current manuscript")
    expect(read(folder, ".gitignore").contains(".texpadtmp/"), ".gitignore added")
    expect(SyncEngine.localChangeCount(folder) == 1, ".gitignore waits to be sent")
    let o = try SyncEngine.sync(folder)
    expect(o.sent?.files == [".gitignore"], "first sync sends the .gitignore")
} catch { expect(false, "clone threw \(error)") }
do {
    let folder = try SyncEngine.clone(remote.path, into: parent, name: "plain-copy", addGitignore: false)
    expect(SyncEngine.localChangeCount(folder) == 0, "clone without .gitignore is clean")
} catch { expect(false, "clone threw \(error)") }
func cloneError(_ name: String, _ url: String = remote.path) -> SyncError? {
    do {
        _ = try SyncEngine.clone(url, into: parent, name: name, addGitignore: true)
        return nil
    } catch {
        return error as? SyncError
    }
}
expect(cloneError("new-paper") == .folderExists("new-paper"), "existing folder refused")
expect(cloneError("  ") == .badFolderName, "empty folder name refused")
expect(cloneError("a/b") == .badFolderName, "folder name with slash refused")
if case .git = cloneError("missing", root.appendingPathComponent("nope.git").path) {
    expect(true, "missing remote reported")
} else { expect(false, "missing remote reported") }
expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("missing").path), "failed clone leaves no folder")

let words = SyncEngine.parseWordDiff("""
diff --git a/a.tex b/a.tex
index 1..2 100644
--- a/a.tex
+++ b/a.tex
@@ -1 +1 @@
 Weeds
-compete
+fight
 with crops.
~
@@ -9 +9 @@
 End.
~
""")
expect(words.count == 1 && words[0].path == "a.tex", "parser reads file name")
expect(words[0].segments.map(\.kind) == [.hunk(1), .same, .removed, .added, .same, .newline, .hunk(9), .same, .newline],
       "parser reads segment kinds and hunk starts")
let numbered = SyncEngine.lines(of: words[0])
expect(numbered.map(\.number) == [1, 1, 9, 9] && numbered.map(\.isHunk) == [true, false, true, false], "lines carry new-file line numbers")
expect(numbered[1].changed && !numbered[3].changed, "changed flag marks edited lines only")

let deleted = SyncEngine.parseWordDiff("""
diff --git a/b.tex b/b.tex
@@ -3,3 +3,2 @@
 Kept line.
~
-This whole line goes.
~
~
 Last line.
~
""")
expect(SyncEngine.lines(of: deleted[0]).map(\.number) == [3, 3, nil, 4, 5], "deleted line has no number, blank line keeps one")

try? FileManager.default.removeItem(at: root)
print(failures == 0 ? "\nall tests passed" : "\n\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)

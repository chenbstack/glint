import XCTest
@testable import Glint

/// Pure-logic guards for the review diff pipeline in `ReviewWindow.swift`.
/// `DiffDocument.parse` and `TreeNode.build` are plain string/JSON → tree
/// transforms with no UI/AppKit surface, so they're unit-tested directly.
///
/// `DiffDocument.parse`'s CRLF normalization (PR #33) is the highest-value
/// guard here: without it Swift treats "\r\n" as a single Character, so
/// `split(separator: "\n")` never matches a CRLF-terminated line and a
/// Windows-authored diff body parses as zero add/del lines — nothing tints.
final class ReviewDiffParsingTests: XCTestCase {

    private struct NonLocalDiffRunner: GitRunner {
        /// Return NUL-delimited fixture output. Parameters: Git args, cwd and timeout. Returns a successful result.
        func run(_ args: [String], cwd: String?, timeout: GitTimeout) async throws -> GitResult {
            if args.first == "rev-parse" {
                return GitResult(exitCode: 0, stdout: String(repeating: "a", count: 40) + "\n", stderr: "")
            }
            if args.contains("--name-status") {
                return GitResult(exitCode: 0, stdout: "M\0file.txt\0", stderr: "")
            }
            if args.contains("--numstat") {
                return GitResult(exitCode: 0, stdout: "1\t1\tfile.txt\0", stderr: "")
            }
            return GitResult(exitCode: 0, stdout: "", stderr: "")
        }

        /// Supply empty untracked counts. Parameters: repository and paths. Returns an empty map.
        func countUntrackedAdditions(repo: String, paths: [String]) async -> [String: Int] {
            [:]
        }
    }

    private struct FailedDiffRunner: GitRunner {
        let failAt: String

        /// Simulate one failed Git step. Parameters: argv, cwd, timeout. Returns fixture output or failure.
        func run(_ args: [String], cwd: String?, timeout: GitTimeout) async throws -> GitResult {
            if args.contains(failAt) {
                return GitResult(exitCode: 128, stdout: "", stderr: "fixture failure")
            }
            return try await NonLocalDiffRunner().run(args, cwd: cwd, timeout: timeout)
        }

        /// Supply empty untracked counts. Parameters: repository and paths. Returns an empty map.
        func countUntrackedAdditions(repo: String, paths: [String]) async -> [String: Int] { [:] }
    }

    /// Reject failed tracked comparisons. Parameters: none. Returns nothing; asserts both tracked list reads.
    func testChangedFilesThrowsForFailedGitRead() async {
        for step in ["--name-status", "--numstat"] {
            do {
                _ = try await GitService(runner: FailedDiffRunner(failAt: step))
                    .changedFiles(repo: "/unused", scope: .workingTree)
                XCTFail("Expected Git failure for \(step)")
            } catch { }
        }
    }

    /// Keep tracked changes when only untracked enumeration fails; no inputs; asserts partial results and warning.
    @MainActor
    func testUntrackedFailureKeepsTrackedChangesAndWarns() async throws {
        let runner = FailedDiffRunner(failAt: "ls-files")
        let result = try await GitService(runner: runner).reviewChanges(repo: "/unused", scope: .workingTree)
        XCTAssertEqual(result.files.map(\.path), ["file.txt"])
        XCTAssertTrue(result.untrackedWarning)
        XCTAssertEqual(result.baseline, String(repeating: "a", count: 40))
        let model = ReviewModel(repo: "/unused", title: "Test", scopes: [.workingTree], runner: runner)
        await model.reload()
        XCTAssertEqual(model.files.map(\.path), ["file.txt"])
        XCTAssertNotNil(model.filesWarning)
        XCTAssertNil(model.filesError)
        XCTAssertEqual(model.selected?.path, "file.txt")
    }

    /// Expose Git failures in Review rather than empty content. Parameters: none. Returns nothing; asserts model state.
    @MainActor
    func testReviewPublishesListAndDiffErrors() async {
        let model = ReviewModel(repo: "/unused", title: "Test", scopes: [.workingTree],
                                runner: FailedDiffRunner(failAt: "--name-status"))
        model.files = [file("stale.txt")]
        model.selected = model.files.first
        await model.reload()
        XCTAssertNotNil(model.filesError)
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.loadingFiles)

        let diffModel = ReviewModel(repo: "/unused", title: "Test", scopes: [.workingTree],
                                    runner: FailedDiffRunner(failAt: "--unified=1000000"))
        await diffModel.select(file("file.txt"))
        XCTAssertNotNil(diffModel.diffError)
        XCTAssertTrue(diffModel.diffText.isEmpty)
        XCTAssertFalse(diffModel.loadingDiff)
    }

    /// Preserve literal path bytes in NUL records. Parameters: none. Returns nothing; asserts counts and kinds.
    func testMergeNulRecordsPreservesSpecialFilenames() {
        let paths = ["中文.txt", "tab\tfile.txt", "line\nfile.txt", "quote\"file.txt"]
        let names = paths.map { "M\0" + $0 + "\0" }.joined()
        let nums = paths.map { "2\t1\t" + $0 + "\0" }.joined()

        let changes = GitService.mergeNameNumstat(nameStatus: names, numstat: nums)

        XCTAssertEqual(Set(changes.keys), Set(paths))
        for path in paths {
            XCTAssertEqual(changes[path]?.kind, .modified)
            XCTAssertEqual(changes[path]?.additions, 2)
            XCTAssertEqual(changes[path]?.deletions, 1)
        }
    }

    /// Keep binary and mode-only entries when merging. Parameters: none. Returns nothing; asserts metadata.
    func testMergeNulRecordsKeepsBinaryAndModeOnlyChanges() {
        let changes = GitService.mergeNameNumstat(
            nameStatus: "M\0binary.dat\0M\0mode.txt\0",
            numstat: "-\t-\tbinary.dat\0")

        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes["binary.dat"]?.isBinary, true)
        XCTAssertEqual(changes["binary.dat"]?.additions, 0)
        XCTAssertEqual(changes["mode.txt"]?.kind, .modified)
        XCTAssertEqual(changes["mode.txt"]?.deletions, 0)
    }

    /// Merge rename-as-delete/add records by their actual paths. Parameters: none. Returns nothing; asserts counts.
    func testMergeNulRecordsKeepsRenameAsDeleteAndAdd() {
        let changes = GitService.mergeNameNumstat(
            nameStatus: "D\0old.txt\0A\0new.txt\0",
            numstat: "0\t3\told.txt\03\t0\tnew.txt\0")

        XCTAssertEqual(Set(changes.keys), ["old.txt", "new.txt"])
        XCTAssertEqual(changes["old.txt"]?.kind, .deleted)
        XCTAssertEqual(changes["old.txt"]?.deletions, 3)
        XCTAssertEqual(changes["new.txt"]?.kind, .added)
        XCTAssertEqual(changes["new.txt"]?.additions, 3)
    }

    private func file(_ path: String) -> GitFileChange {
        GitFileChange(path: path, kind: .modified, additions: 1, deletions: 1, isBinary: false)
    }

    // MARK: DiffDocument.parse

    private static let hunkDiff = """
diff --git a/f.txt b/f.txt
index 111..222 100644
--- a/f.txt
+++ b/f.txt
@@ -1,3 +1,3 @@
 keep
-old
+new
"""

    /// Hunk header seeds old/new line numbers; +/-/context get the right kind
    /// and the body markers are stripped from the rendered text.
    func testParseAssignsKindsAndLineNumbers() {
        let lines = DiffDocument.parse(Self.hunkDiff)
        // Meta (diff/index/---/+++) is dropped → hunk + 3 body lines.
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].kind, .hunk)
        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[1].text, "keep")
        XCTAssertEqual(lines[1].oldNum, 1)
        XCTAssertEqual(lines[1].newNum, 1)
        XCTAssertEqual(lines[2].kind, .del)
        XCTAssertEqual(lines[2].text, "old")
        XCTAssertEqual(lines[2].oldNum, 2)
        XCTAssertNil(lines[2].newNum)
        XCTAssertEqual(lines[3].kind, .add)
        XCTAssertEqual(lines[3].text, "new")
        XCTAssertNil(lines[3].oldNum)
        XCTAssertEqual(lines[3].newNum, 2)
    }

    /// CRLF regression guard (PR #33). A Windows-authored file keeps CRLF in
    /// the diff body; it must parse exactly like the LF version. If the
    /// normalization is removed, CRLF lines merge (or keep a trailing \r) and
    /// these counts/texts break.
    func testParseNormalizesCRLFBodyLikeLF() {
        let crlf = Self.hunkDiff.replacingOccurrences(of: "\n", with: "\r\n")
        let lines = DiffDocument.parse(crlf)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].kind, .hunk)
        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[1].text, "keep")
        XCTAssertEqual(lines[2].kind, .del)
        XCTAssertEqual(lines[2].text, "old")
        XCTAssertEqual(lines[3].kind, .add)
        XCTAssertEqual(lines[3].text, "new")
        XCTAssertEqual(lines[3].newNum, 2)
    }

    /// Lone CR (classic Mac) line endings must also normalize to LF.
    func testParseNormalizesLoneCR() {
        // "@@ ...@@" + CRLF-free body using lone CR as the line separator.
        let diff = "@@ -1,1 +1,1 @@\r+a\r-b"
        let lines = DiffDocument.parse(diff)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].kind, .hunk)
        XCTAssertEqual(lines[1].kind, .add)
        XCTAssertEqual(lines[1].text, "a")
        XCTAssertEqual(lines[1].newNum, 1)
        XCTAssertEqual(lines[2].kind, .del)
        XCTAssertEqual(lines[2].text, "b")
        XCTAssertEqual(lines[2].oldNum, 1)
    }

    /// File-level meta lines and the "\ No newline at end of file" marker
    /// produce no DiffLines; only the hunk + its body survive.
    func testParseDropsMetaAndNoNewlineMarker() {
        let diff = """
diff --git a/f b/f
new file mode 100644
index 000..111
--- /dev/null
+++ b/f
@@ -0,0 +1,1 @@
+hello
\\ No newline at end of file
"""
        let lines = DiffDocument.parse(diff)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].kind, .hunk)
        XCTAssertEqual(lines[1].kind, .add)
        XCTAssertEqual(lines[1].text, "hello")
        XCTAssertEqual(lines[1].newNum, 1)
    }

    /// Meta headers NOT on the old allow-list (e.g. "dissimilarity index",
    /// "GIT binary patch") must be skipped, not leaked through as a tinted
    /// context line. Classification is by leading marker now, so any
    /// unrecognized git header drops instead of rendering as content.
    func testParseSkipsUnrecognizedMetaHeaders() {
        let diff = """
diff --git a/o b/n
dissimilarity index 60%
rename from o
rename to n
--- a/o
+++ b/n
@@ -1,1 +1,1 @@
-x
+y
"""
        let lines = DiffDocument.parse(diff)
        // hunk + 1 del + 1 add; every meta header (diff / "dissimilarity
        // index" / rename from / rename to / --- / +++) drops entirely.
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].kind, .hunk)
        XCTAssertEqual(lines[1].kind, .del)
        XCTAssertEqual(lines[1].text, "x")
        XCTAssertEqual(lines[2].kind, .add)
        XCTAssertEqual(lines[2].text, "y")
    }

    func testParseEmptyYieldsEmpty() {
        XCTAssertTrue(DiffDocument.parse("").isEmpty)
    }

    /// Old-file and new-file syntax-highlight states must walk independently:
    /// a `/*` opener removed from the OLD side must NOT leak `inBlockComment`
    /// onto the `+` and context lines that follow (they aren't inside a
    /// comment in the new file). Symmetric the other way.
    /// We can't easily assert on AttributedString tinting without a renderer
    /// here, so just lock the structural contract — `parse` returns the right
    /// kinds + bodies for a diff that previously triggered the bleed.
    func testParseTwoStateHighlightAcceptsDeletedCommentOpener() {
        let diff = """
        @@ -1,3 +1,3 @@
        -/* TODO: drop me
        +let x = 5
         let y = 6
        """
        let lines = DiffDocument.parse(diff)
        XCTAssertEqual(lines.count, 4)   // hunk + del + add + context
        XCTAssertEqual(lines[1].kind, .del)
        XCTAssertEqual(lines[1].text, "/* TODO: drop me")
        XCTAssertEqual(lines[2].kind, .add)
        XCTAssertEqual(lines[2].text, "let x = 5")
        XCTAssertEqual(lines[3].kind, .context)
        XCTAssertEqual(lines[3].text, "let y = 6")
    }

    // MARK: TreeNode.build

    /// Directories nest, folders sort before files at each level (case
    /// insensitive), and only leaf nodes carry the `GitFileChange`.
    func testBuildNestsAndSortsFoldersFirst() {
        let nodes = TreeNode.build([
            file("src/b.swift"),
            file("src/a.swift"),
            file("README.md"),
            file("src/sub/c.swift"),
        ])
        XCTAssertEqual(nodes.map(\.name), ["src", "README.md"])   // folder first
        XCTAssertTrue(nodes[0].isDir)
        XCTAssertFalse(nodes[1].isDir)
        XCTAssertNil(nodes[0].file)                                // dir carries no file
        XCTAssertEqual(nodes[1].file?.path, "README.md")

        let src = nodes[0].children
        XCTAssertEqual(src.map(\.name), ["sub", "a.swift", "b.swift"])  // folder, then files
        XCTAssertEqual(src[0].children.map(\.name), ["c.swift"])
        XCTAssertEqual(src[1].file?.path, "src/a.swift")
    }

    /// Many files under one parent share that parent node — the O(1) path
    /// lookup (PR #30). A flat dir with N files yields one shared dir with N
    /// leaves; the old linear sibling scan made this O(N²) on reload().
    func testBuildDedupesSharedParentAndScalesFlat() {
        let paths = (0..<40).map { file("flat/f\($0).txt") }
        let nodes = TreeNode.build(paths)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].name, "flat")
        XCTAssertTrue(nodes[0].isDir)
        XCTAssertEqual(nodes[0].children.count, 40)
        XCTAssertTrue(nodes[0].children.allSatisfy { !$0.isDir && $0.file != nil })
    }

    /// A path reported twice collapses to a single node (the path-keyed build
    /// reuses the first) rather than creating a duplicate leaf.
    func testBuildCollapsesDuplicatePath() {
        let nodes = TreeNode.build([file("a.txt"), file("a.txt")])
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].name, "a.txt")
    }

    func testChangedFilesDoesNotReadMtimeForNonLocalRunner() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-remote-mtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try Data("local collision".utf8).write(to: repo.appendingPathComponent("file.txt"))

        let files = try await GitService(runner: NonLocalDiffRunner())
            .changedFiles(repo: repo.path, scope: .workingTree)

        XCTAssertEqual(files.count, 1)
        XCTAssertNil(files[0].modDate)
    }

    @MainActor
    func testRevealTargetWalksUpDeletedTreeToExistingRepo() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let deleted = repo.appendingPathComponent("removed/tree/file.txt")

        let target = ReviewModel.revealTarget(fullPath: deleted.path, repo: repo.path)

        XCTAssertEqual(target.standardizedFileURL, repo.standardizedFileURL)
    }
}

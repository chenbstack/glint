import XCTest
@testable import Glint

final class GitRepositoryWatcherTests: XCTestCase {
    func testWorktreePathsIncludeGitDirAndCommonDir() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let worktree = root.appendingPathComponent("worktree")
        let gitDir = root.appendingPathComponent("main/.git/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "gitdir: ../main/.git/worktrees/feature\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(
            to: gitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = Set(GitRepositoryWatcher.watchPaths(for: worktree.path))

        XCTAssertTrue(paths.contains(worktree.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(gitDir.standardizedFileURL.path))
        XCTAssertTrue(paths.contains(root.appendingPathComponent("main/.git").standardizedFileURL.path))
    }
}

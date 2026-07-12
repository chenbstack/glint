import Foundation
import CoreServices

/// Debounced recursive filesystem watcher for one repository/worktree.
/// FSEvents supplies the broad invalidation signal; Git remains the authority.
final class GitRepositoryWatcher {
    private let queue = DispatchQueue(label: "app.glint.git-watch", qos: .utility)
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pendingRefresh: DispatchWorkItem?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<GitRepositoryWatcher>.fromOpaque(info)
                .takeUnretainedValue().scheduleRefresh()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        // `pendingRefresh` is written from `scheduleRefresh`, which runs on
        // `queue` (the FSEvent callback target). Serialize the cancel on the
        // same queue instead of touching it from the main thread that freed
        // the watcher. Safe to sync from deinit: no task on `queue` ever
        // blocks on the main thread (the debounce item hops with `main.async`,
        // fire-and-forget), so there's no lock inversion.
        queue.sync { pendingRefresh?.cancel() }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async(execute: self.onChange)
        }
        pendingRefresh = item
        queue.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Paths whose changes can affect status: the work tree plus the actual
    /// per-worktree gitdir and shared common dir referenced by `.git` files.
    static func watchPaths(for repositoryPath: String) -> [String] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: repositoryPath).standardizedFileURL
        var paths = Set([root.path])
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false

        if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                paths.insert(dotGit.path)
            } else if let gitDir = referencedPath(in: dotGit, key: "gitdir", relativeTo: root) {
                paths.insert(gitDir.path)
                let commonFile = gitDir.appendingPathComponent("commondir")
                if let commonDir = referencedPath(in: commonFile, key: nil, relativeTo: gitDir) {
                    paths.insert(commonDir.path)
                }
            }
        }
        return paths.sorted()
    }

    private static func referencedPath(in file: URL, key: String?, relativeTo base: URL) -> URL? {
        guard var value = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if let key {
            let prefix = key + ":"
            guard value.lowercased().hasPrefix(prefix) else { return nil }
            value = String(value.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let url = URL(fileURLWithPath: value, relativeTo: base).standardizedFileURL
        return url
    }
}

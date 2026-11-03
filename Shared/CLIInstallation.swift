import Foundation

enum CLIInstallation {
    enum State { case notInstalled, installed, repairable, linkedElsewhere, conflict }

    static func state(executable: URL, directory: URL) -> State {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent("glint")
        if let existing = try? fm.destinationOfSymbolicLink(atPath: destination.path) {
            let target = URL(fileURLWithPath: existing, relativeTo: directory)
                .standardizedFileURL.resolvingSymlinksInPath()
            if target == executable.standardizedFileURL.resolvingSymlinksInPath() { return .installed }
            // Only dangling Glint links are repairable. An existing Release/Debug
            // installation is a valid owner of this link and must not be replaced.
            guard target.path.hasSuffix("/Glint.app/Contents/Helpers/glint") else { return .conflict }
            return fm.fileExists(atPath: target.path) ? .linkedElsewhere : .repairable
        }
        return fm.fileExists(atPath: destination.path) ? .conflict : .notInstalled
    }

    static func install(executable: URL, directory: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw NSError(domain: "GlintCLI", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The bundled CLI is missing. Reinstall Glint.")])
        }
        switch state(executable: executable, directory: directory) {
        case .installed:
            throw NSError(domain: "GlintCLI", code: 3, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "CLI is already installed.")])
        case .conflict: throw occupiedPathError()
        case .linkedElsewhere: throw linkedElsewhereError()
        case .notInstalled: break
        case .repairable:
            try fm.removeItem(at: directory.appendingPathComponent("glint"))
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("glint")
        try fm.createSymbolicLink(at: destination, withDestinationURL: executable)
        return destination
    }

    static func uninstall(executable: URL, directory: URL) throws {
        switch state(executable: executable, directory: directory) {
        case .installed, .repairable:
            // Remove only the verified link, never the executable or another tool.
            try FileManager.default.removeItem(at: directory.appendingPathComponent("glint"))
        case .conflict: throw occupiedPathError()
        case .linkedElsewhere: throw linkedElsewhereError()
        case .notInstalled:
            throw NSError(domain: "GlintCLI", code: 4, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "CLI is not installed.")])
        }
    }

    private static func linkedElsewhereError() -> NSError {
        NSError(domain: "GlintCLI", code: 5, userInfo: [NSLocalizedDescriptionKey:
            String(localized: "The CLI is linked to another existing Glint installation. It was left unchanged.")])
    }

    private static func occupiedPathError() -> NSError {
        NSError(domain: "GlintCLI", code: 2, userInfo: [NSLocalizedDescriptionKey:
            String(localized: "The destination already contains another command. It was left unchanged.")])
    }
}

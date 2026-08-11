import Foundation

/// Scans the configured roots for project directories and resolves their colors.
///
/// A directory counts as a project when it holds a `*.code-workspace` file or a
/// `.git` entry, and a project is a leaf: the scan descends only through
/// directories that are not projects themselves. That is what the depth is for —
/// the grouping directories the user keeps (`wirenboard/`) hold no workspace and
/// no `.git`, so their children are still reached.
///
/// Results are cached and reused until the fingerprint of the tree changes: the
/// modification time of every directory that was listed, plus of every color
/// source file that was read (a directory mtime does not move when a file inside
/// it is edited in place).
///
/// `@unchecked Sendable`: `projects(config:)` is the only entry point and every
/// access to the cached state happens under `lock`.
final class WorkspaceIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedProjects: [ProjectInfo] = []
    private var cachedFingerprint: [String: Date] = [:]
    private var hasCache = false

    /// Directory names never descended into. Anything starting with a dot is
    /// skipped separately, which also covers `.git`, `.venv` and `.build`.
    private static let skippedDirectories: Set<String> = [
        "node_modules", "vendor", "venv", "target", "build", "dist",
        "Pods", "__pycache__", "DerivedData"
    ]

    /// Returns the project list, rescanning only when the tree fingerprint moved.
    ///
    /// There is no way to force a rescan and there is nothing to force: the
    /// fingerprint covers every directory the scan listed and every color file
    /// it read, so a change anywhere it looked already triggers one.
    func projects(config: Config) -> [ProjectInfo] {
        lock.lock()
        defer { lock.unlock() }

        if hasCache, fingerprintMatches(cachedFingerprint) {
            return cachedProjects
        }

        var fingerprint: [String: Date] = [:]
        var projects: [ProjectInfo] = []
        var seenPaths = Set<String>()

        for root in config.resolvedProjectRoots {
            // The root itself is depth 0, so `scanDepth: 2` reaches
            // `<root>/wirenboard/wb-mge`.
            scan(directory: root,
                 root: root,
                 depth: 0,
                 maxDepth: max(1, config.scanDepth),
                 fingerprint: &fingerprint,
                 projects: &projects,
                 seenPaths: &seenPaths)
        }

        projects.sort { $0.mtime > $1.mtime }
        cachedProjects = projects
        cachedFingerprint = fingerprint
        hasCache = true
        return projects
    }

    private func fingerprintMatches(_ fingerprint: [String: Date]) -> Bool {
        for (path, recorded) in fingerprint {
            guard let current = Self.modificationDate(atPath: path) else { return false }
            if current != recorded { return false }
        }
        return true
    }

    private func scan(directory: URL,
                      root: URL,
                      depth: Int,
                      maxDepth: Int,
                      fingerprint: inout [String: Date],
                      projects: inout [ProjectInfo],
                      seenPaths: inout Set<String>) {
        guard let directoryMtime = Self.modificationDate(atPath: directory.path) else { return }
        fingerprint[directory.path] = directoryMtime

        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }

        var subdirectories: [URL] = []
        var workspaceFile: String?
        var hasGit = false

        for entry in entries {
            if entry.hasPrefix(".") {
                if entry == ".git" { hasGit = true }
                continue
            }
            let full = directory.appendingPathComponent(entry)
            if entry.hasSuffix(".code-workspace") {
                // Deterministic pick when a directory holds several workspaces.
                let current = workspaceFile.map { ($0 as NSString).lastPathComponent }
                if current == nil || entry < current! { workspaceFile = full.path }
                continue
            }
            if Self.skippedDirectories.contains(entry) { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: full.path, isDirectory: &isDirectory), isDirectory.boolValue {
                subdirectories.append(full)
            }
        }

        // A scan root is never a project itself, however it looks: it has to be
        // descended into or nothing would be found at all.
        let isProject = (workspaceFile != nil || hasGit) && directory != root
        if isProject, seenPaths.insert(directory.path).inserted {
            projects.append(makeProject(directory: directory,
                                        root: root,
                                        workspaceFile: workspaceFile,
                                        mtime: directoryMtime,
                                        fingerprint: &fingerprint))
        }

        // Stop at a project. Descending into one turns its vendored and nested
        // repositories into rows of their own, and a nested `mqtt2influx` then
        // collides on `rootName` with the real top-level `mqtt2influx`: whichever
        // has the newer mtime wins the window match, so the other one's window
        // gets a stranger's color and path and its sessions land under a key
        // nobody reads.
        guard !isProject, depth < maxDepth else { return }
        for subdirectory in subdirectories {
            scan(directory: subdirectory,
                 root: root,
                 depth: depth + 1,
                 maxDepth: maxDepth,
                 fingerprint: &fingerprint,
                 projects: &projects,
                 seenPaths: &seenPaths)
        }
    }

    private func makeProject(directory: URL,
                             root: URL,
                             workspaceFile: String?,
                             mtime: Date,
                             fingerprint: inout [String: Date]) -> ProjectInfo {
        let directoryName = directory.lastPathComponent
        let rootName: String
        if let workspaceFile {
            // `deletingPathExtension`, not a substring replacement: the latter
            // also cuts the pattern out of the middle of a name.
            rootName = URL(fileURLWithPath: workspaceFile).deletingPathExtension().lastPathComponent
        } else {
            rootName = directoryName
        }

        // The list shows the directory, not the workspace file name: a project
        // in `noproject/` whose workspace is `ws.code-workspace` would otherwise
        // appear as "ws". Nested projects keep their grouping directory.
        let parent = directory.deletingLastPathComponent()
        let displayName = parent.standardizedFileURL == root.standardizedFileURL
            ? directoryName
            : "\(parent.lastPathComponent)/\(directoryName)"

        let settingsFile = directory.appendingPathComponent(".vscode/settings.json").path
        if let workspaceFile, let date = Self.modificationDate(atPath: workspaceFile) {
            fingerprint[workspaceFile] = date
        }
        if let date = Self.modificationDate(atPath: settingsFile) {
            fingerprint[settingsFile] = date
        }

        let color = Self.resolveColor(workspaceFile: workspaceFile,
                                      settingsFile: settingsFile,
                                      rootName: rootName)

        return ProjectInfo(path: directory.path,
                           displayName: displayName,
                           rootName: rootName,
                           colorHex: color,
                           workspaceFile: workspaceFile,
                           mtime: mtime)
    }

    // MARK: - Color resolution

    /// Peacock color, then the title bar customization, first from the workspace
    /// file and then from `.vscode/settings.json`; a hash of the name otherwise.
    static func resolveColor(workspaceFile: String?, settingsFile: String, rootName: String) -> String {
        for path in [workspaceFile, settingsFile].compactMap({ $0 }) {
            guard let root = JSONC.object(atPath: path) else { continue }
            // A `.code-workspace` nests them under "settings"; a settings file
            // has them at the top level.
            let settings = (root["settings"] as? [String: Any]) ?? root
            if let color = normalizeHex(settings["peacock.color"] as? String) {
                return color
            }
            if let customizations = settings["workbench.colorCustomizations"] as? [String: Any],
               let color = normalizeHex(customizations["titleBar.activeBackground"] as? String) {
                return color
            }
        }
        return fallbackColor(for: rootName)
    }

    /// Accepts `#rgb`, `#rrggbb` and `#rrggbbaa` with or without the hash.
    static func normalizeHex(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch value.count {
        case 3:
            return "#" + value.map { "\($0)\($0)" }.joined()
        case 6, 8:
            return "#" + String(value.prefix(6))
        default:
            return nil
        }
    }

    /// Stable pastel-ish color derived from the project name, so a project
    /// without any VSCode color still looks distinct and never changes.
    static func fallbackColor(for name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        let hue = Double(hash % 360)
        return hsvToHex(hue: hue, saturation: 0.55, value: 0.72)
    }

    private static func hsvToHex(hue: Double, saturation: Double, value: Double) -> String {
        let sector = hue / 60
        let chroma = value * saturation
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let match = value - chroma
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: (r, g, b) = (chroma, second, 0)
        case 1: (r, g, b) = (second, chroma, 0)
        case 2: (r, g, b) = (0, chroma, second)
        case 3: (r, g, b) = (0, second, chroma)
        case 4: (r, g, b) = (second, 0, chroma)
        default: (r, g, b) = (chroma, 0, second)
        }
        let components = [r, g, b].map { UInt8(max(0, min(255, ($0 + match) * 255)).rounded()) }
        return "#" + components.map { String(format: "%02x", $0) }.joined()
    }

    private static func modificationDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

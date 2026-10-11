import Foundation

/// User-tunable settings, loaded from `~/.config/vscode-switcher/config.json`.
///
/// Every field has a default, the file is optional and a malformed file is
/// ignored field by field rather than as a whole: a typo in one key must not
/// take the whole app down to defaults silently. The file is never created by
/// the app.
///
/// Unknown keys (typos, retired keys) are silently ignored: `load` walks the
/// keys it knows, and this type is read before there is any surface to warn on.
struct Config: Sendable, Equatable {
    /// Directories scanned for projects. Values may contain a leading `~`.
    var projectRoots: [String]
    /// How deep below each root a project directory may sit. 1 = direct children.
    var scanDepth: Int
    /// How far back Claude Code sessions are counted for the figure `--dump`
    /// prints beside each project. The ranking itself does not use it: the
    /// "projects" section is ordered by the time of the last session (SPEC
    /// §2.2.1), whatever its age.
    var activityWindowDays: Int
    /// How long the pointer has to rest against the screen edge before the panel opens.
    var dwellMilliseconds: Int
    /// Panel width in points.
    var panelWidth: Double
    /// Fraction of the screen's usable height the panel occupies. The same
    /// fraction defines the edge strip that opens it, so the trigger zone always
    /// lines up with where the panel will appear.
    var panelHeightFraction: Double
    /// A background subagent counts as active while its last record does not
    /// say it stopped and its transcript was touched within this many seconds.
    ///
    /// A normal stop (`end_turn`, `stop_sequence`) or an interrupt is seen in
    /// the record itself; the age only covers the rest. A thinking model can
    /// write nothing for minutes, so a tight threshold hides working subagents
    /// (17.4% of working time at 90 s against 2.3% at 600 s; SPEC §3.1).
    var subagentActiveSeconds: Double
    /// How much of a session transcript is read from the end. Transcripts reach
    /// tens of megabytes, so they are never read in full.
    var transcriptTailBytes: Int
    /// Bundle identifier of the editor whose windows are listed.
    var editorBundleID: String
    /// Base address of the claude_gw gateway the token figures come from. The
    /// default is the local launchd relay, which forwards to the gateway over
    /// WireGuard; the alternative is the gateway itself,
    /// `http://<gateway address on the WireGuard network>:8787`, for when the
    /// relay is not running. Neither takes any authentication.
    var usageBaseURL: String
    static let `default` = Config(
        projectRoots: ["~/Data/Projects"],
        scanDepth: 2,
        activityWindowDays: 30,
        dwellMilliseconds: 300,
        panelWidth: 380,
        panelHeightFraction: 0.7,
        subagentActiveSeconds: 600,
        transcriptTailBytes: 512 * 1024,
        editorBundleID: "com.microsoft.VSCode",
        usageBaseURL: "http://127.0.0.1:8788"
    )

    /// Standard location of the config file.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vscode-switcher/config.json")
    }

    /// Scan roots with `~` expanded and duplicates removed.
    var resolvedProjectRoots: [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for raw in projectRoots {
            let expanded = (raw as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
            if seen.insert(standardized.path).inserted {
                result.append(standardized)
            }
        }
        return result
    }

    /// The gateway address as a `URL`.
    ///
    /// `load` only accepts a string with a scheme and a host, so the fallback
    /// is for a `Config` assembled in code; a test checks that the default parses.
    var resolvedUsageBaseURL: URL {
        URL(string: usageBaseURL) ?? URL(fileURLWithPath: "/")
    }

    /// Loads the config, falling back to defaults for anything missing or invalid.
    static func load(from url: URL? = nil) -> Config {
        let url = url ?? Config.fileURL
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else {
            return .default
        }
        var config = Config.default
        if let roots = dict["projectRoots"] as? [String], !roots.isEmpty {
            config.projectRoots = roots
        }
        if let value = dict["scanDepth"] as? Int, value > 0 {
            config.scanDepth = value
        }
        if let value = dict["activityWindowDays"] as? Int, value > 0 {
            config.activityWindowDays = value
        }
        if let value = dict["dwellMilliseconds"] as? Int, value >= 0 {
            config.dwellMilliseconds = value
        }
        if let value = dict["panelWidth"] as? Double, value > 0 {
            config.panelWidth = value
        }
        if let value = dict["panelHeightFraction"] as? Double, value > 0, value <= 1 {
            config.panelHeightFraction = value
        }
        if let value = dict["subagentActiveSeconds"] as? Double, value > 0 {
            config.subagentActiveSeconds = value
        }
        if let value = dict["transcriptTailBytes"] as? Int, value > 0 {
            config.transcriptTailBytes = value
        }
        if let value = dict["editorBundleID"] as? String, !value.isEmpty {
            config.editorBundleID = value
        }
        // Requires an http(s) scheme and a host: `URL(string:)` accepts
        // `not a url at all` as a relative URL on macOS 14, and `ftp://` or
        // `file://` addresses would make every poll fail.
        if let value = dict["usageBaseURL"] as? String, !value.isEmpty,
           let url = URL(string: value), url.host() != nil,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            config.usageBaseURL = value
        }
        return config
    }
}

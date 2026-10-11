import AppKit
import ApplicationServices

/// Accessibility-based access to the editor's windows: enumeration, focusing and
/// opening a project in a new window.
enum VSCodeWindows {

    // MARK: - Permission

    /// Whether this process may talk to other apps through the Accessibility API.
    /// Never prompts.
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Same check, but shows the system prompt that offers to open the
    /// Accessibility pane. Returns the state as of the call, which is `false`
    /// right after the prompt appears.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        // The literal rather than `kAXTrustedCheckOptionPrompt`: that symbol is
        // an `Unmanaged<CFString>` global, which is not `Sendable` and warns
        // under strict concurrency. Its value is this string.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - Messaging timeout

    /// How long a single Accessibility request may take before it gives up.
    ///
    /// The system default is around six seconds. Every window costs four
    /// synchronous attribute reads, so one VSCode instance with a wedged
    /// extension host would otherwise stall a whole snapshot for a minute —
    /// and `snapshot()` holds its lock for the whole assembly, so the panel
    /// would stop updating altogether until that instance answered.
    private static let messagingTimeout: Float = 1.0

    /// Sets the timeout once for the whole process.
    ///
    /// It has to go on the *system-wide* element: "Pass the system-wide
    /// accessibility object if you want to set the timeout globally for this
    /// process. Setting the timeout on another accessibility object sets it
    /// only for that object." On the application element it would leave every
    /// window element, where the expensive reads happen, on the system default.
    private static let timeoutInstalled: Bool =
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout) == .success

    /// Installs the process-wide timeout, and reports whether it took. Idempotent:
    /// the work happens on the first call and the result is reused afterwards.
    @discardableResult
    static func installMessagingTimeout() -> Bool { timeoutInstalled }

    // MARK: - Enumeration

    /// All standard windows of every running instance of `bundleID`.
    ///
    /// The AX window array is in z-order, front to back, and that order is kept:
    /// it is what the list uses as an MRU ordering.
    static func listWindows(bundleID: String) -> [VSCodeWindowInfo] {
        installMessagingTimeout()
        var result: [VSCodeWindowInfo] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            guard let windows = windowElements(pid: pid) else { continue }
            for (index, window) in windows.enumerated() {
                // Dialogs and sheets are AXDialog / AXSystemDialog; only real
                // editor windows carry AXStandardWindow.
                guard let subrole = copyAttribute(window, kAXSubroleAttribute) as? String,
                      subrole == kAXStandardWindowSubrole as String
                else { continue }
                let title = (copyAttribute(window, kAXTitleAttribute) as? String) ?? ""
                let minimized = (copyAttribute(window, kAXMinimizedAttribute) as? Bool) ?? false
                let parsed = parseTitle(title)
                result.append(VSCodeWindowInfo(pid: pid,
                                               windowIndex: index,
                                               windowNumber: windowNumber(of: window),
                                               title: title,
                                               rootName: parsed.rootName,
                                               chatTopicPrefix: parsed.chatTopic,
                                               isWorkspace: parsed.isWorkspace,
                                               isMinimized: minimized))
            }
        }
        return result
    }

    /// The window elements of a process, each with the timeout applied.
    ///
    /// The per-element call is belt and braces on top of the process-wide one:
    /// it costs no IPC, and it keeps the guarantee even if a future release
    /// stops honouring the system-wide setting.
    private static func windowElements(pid: pid_t) -> [AXUIElement]? {
        installMessagingTimeout()
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let windows = copyAttribute(application, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows { AXUIElementSetMessagingTimeout(window, messagingTimeout) }
        return windows
    }

    // MARK: - Stable window identity

    private typealias GetWindowFunction =
        @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// `_AXUIElementGetWindow` — private SPI of HIServices that maps an AX
    /// window element to its `CGWindowID`.
    ///
    /// That number is the only identifier of a window that survives a raise (the
    /// index into `kAXWindowsAttribute` is the z-order). Resolved with `dlsym`
    /// rather than `@_silgen_name` so a macOS that drops the symbol makes
    /// `windowNumber(of:)` return `nil` instead of failing to launch the app.
    private static let getWindowFunction: GetWindowFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    /// Whether the private call behind `windowNumber(of:)` is available at all.
    /// When it is not, windows fall back to being identified by z-order.
    static var isWindowNumberAvailable: Bool { getWindowFunction != nil }

    /// `CGWindowID` of an AX window element: stable for the lifetime of the
    /// window and independent of its position in the z-order.
    static func windowNumber(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow = getWindowFunction else { return nil }
        var identifier: CGWindowID = 0
        guard getWindow(element, &identifier) == .success, identifier != 0 else { return nil }
        return identifier
    }

    /// Splits a VSCode window title into the active chat topic and the project.
    ///
    /// Titles look like `<chat topic, ellipsised> — <rootName> (Workspace)`. The
    /// separator is an em dash in spaces; the plain hyphen form is accepted as a
    /// fallback for non-default title templates. The split is on the *last*
    /// separator, because the chat topic itself often contains one.
    static func parseTitle(_ title: String) -> (chatTopic: String?, rootName: String?, isWorkspace: Bool) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil, false) }

        var head: String?
        var tail = trimmed
        for separator in [" \u{2014} ", " - "] {
            if let range = trimmed.range(of: separator, options: .backwards) {
                head = String(trimmed[trimmed.startIndex..<range.lowerBound])
                tail = String(trimmed[range.upperBound...])
                break
            }
        }

        let workspaceSuffix = " (Workspace)"
        var isWorkspace = false
        if tail.hasSuffix(workspaceSuffix) {
            tail.removeLast(workspaceSuffix.count)
            isWorkspace = true
        }

        let rootName = tail.trimmingCharacters(in: .whitespaces)
        let chatTopic = head?.trimmingCharacters(in: .whitespaces)
        return (chatTopic?.isEmpty == false ? chatTopic : nil,
                rootName.isEmpty ? nil : rootName,
                isWorkspace)
    }

    // MARK: - Actions

    /// Brings the editor process to the front.
    ///
    /// AppKit only, no Accessibility: it never blocks on a busy editor, and it
    /// is the half of the old `focus` that has to run on the main thread.
    @MainActor
    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }

    /// Raises one window inside its process. Accessibility only, so it is safe
    /// on any queue and should be kept off the main one — it can block for as
    /// long as `messagingTimeout`. macOS switches Spaces on its own when the
    /// window lives on another desktop.
    ///
    /// The window is found by its `windowNumber`, which nothing reshuffles; the
    /// title changes (it carries the active chat topic) and the z-order index is
    /// renumbered by every raise.
    @discardableResult
    static func raise(_ window: VSCodeWindowInfo) -> Bool {
        guard let windows = windowElements(pid: window.pid),
              let index = matchIndex(for: window, in: windows.map { windowNumber(of: $0) })
        else { return false }
        let target = windows[index]

        if (copyAttribute(target, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

    /// Position of `window` in a freshly read window list, given that list's
    /// window numbers in its current z-order.
    ///
    /// Returns `nil` rather than a guess when the recorded window is gone:
    /// raising whatever slid into its slot is exactly the "clicking row 2 raises
    /// window 4" bug. The index is used only when the private call that yields
    /// window numbers is unavailable, and then it is no better than before.
    static func matchIndex(for window: VSCodeWindowInfo, in numbers: [CGWindowID?]) -> Int? {
        if let recorded = window.windowNumber {
            return numbers.firstIndex { $0 == recorded }
        }
        return numbers.indices.contains(window.windowIndex) ? window.windowIndex : nil
    }

    /// Raises a window without activating its application.
    ///
    /// Kept for callers that already activated on the main thread before handing
    /// the Accessibility round trip to a background queue. New code should call
    /// `activate(pid:)` and `raise(_:)` explicitly.
    @discardableResult
    static func focus(_ window: VSCodeWindowInfo) -> Bool { raise(window) }

    /// Opens a project in a new editor window: the `.code-workspace` file when
    /// there is one, the directory otherwise.
    ///
    /// The bundled `code` CLI is tried first because it reliably opens a new
    /// window for a workspace file; `NSWorkspace` is the fallback when the CLI is
    /// missing or fails to launch.
    @discardableResult
    static func openProject(_ project: ProjectInfo, config: Config = .default) -> Bool {
        let targetPath = project.workspaceFile ?? project.path
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.editorBundleID)

        if let appURL {
            let cli = appURL.appendingPathComponent("Contents/Resources/app/bin/code")
            if FileManager.default.isExecutableFile(atPath: cli.path) {
                let process = Process()
                process.executableURL = cli
                process.arguments = [targetPath]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { return true }
            }
        }

        let fileURL = URL(fileURLWithPath: targetPath)
        if let appURL {
            NSWorkspace.shared.open([fileURL],
                                    withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
            return true
        }
        return NSWorkspace.shared.open(fileURL)
    }

    // MARK: - Helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

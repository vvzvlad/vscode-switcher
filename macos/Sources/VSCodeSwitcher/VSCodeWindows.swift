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
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Enumeration

    /// All standard windows of every running instance of `bundleID`.
    ///
    /// The AX window array is in z-order, front to back, and that order is kept:
    /// it is what the list uses as an MRU ordering.
    static func listWindows(bundleID: String) -> [VSCodeWindowInfo] {
        var result: [VSCodeWindowInfo] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            let element = AXUIElementCreateApplication(pid)
            guard let windows = copyAttribute(element, kAXWindowsAttribute) as? [AXUIElement] else { continue }
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
                                               title: title,
                                               rootName: parsed.rootName,
                                               chatTopicPrefix: parsed.chatTopic,
                                               isWorkspace: parsed.isWorkspace,
                                               isMinimized: minimized))
            }
        }
        return result
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

    /// Brings a window to the front. macOS switches Spaces on its own when the
    /// window lives on another desktop.
    @discardableResult
    static func focus(_ window: VSCodeWindowInfo) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return false }
        app.activate()

        let element = AXUIElementCreateApplication(window.pid)
        guard let windows = copyAttribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return false }

        // Activating the app can already have reshuffled the z-order, so the
        // title is the primary key and the recorded index only a fallback.
        var target: AXUIElement?
        for candidate in windows where (copyAttribute(candidate, kAXTitleAttribute) as? String) == window.title {
            target = candidate
            break
        }
        if target == nil, windows.indices.contains(window.windowIndex) {
            target = windows[window.windowIndex]
        }
        guard let target else { return false }

        if (copyAttribute(target, kAXMinimizedAttribute) as? Bool) == true {
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

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

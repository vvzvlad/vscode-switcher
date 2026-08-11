import Combine
import Foundation

extension SwitcherSnapshot {
    /// What the panel shows before the first background rebuild has finished.
    static let empty = SwitcherSnapshot(openWindows: [],
                                        projects: [],
                                        accessibilityTrusted: false,
                                        generatedAt: .distantPast)
}

/// Keeps one always-available copy of the switcher model.
///
/// `DataSource.snapshot()` walks the project index, the Accessibility API and a
/// pile of transcript tails, so it runs off the main thread and only the
/// finished value crosses back. The panel always has something to draw
/// immediately — the cache — and the fresh value arrives right after.
@MainActor
final class SnapshotStore: ObservableObject {

    /// Latest model. Only ever replaced on the main thread.
    @Published private(set) var snapshot: SwitcherSnapshot = .empty

    /// Poll interval while the panel is hidden.
    private static let idleInterval: TimeInterval = 2
    /// Poll interval while the panel is on screen.
    private static let activeInterval: TimeInterval = 1
    /// A burst of file system events collapses into a single rebuild.
    private static let watchDebounce: TimeInterval = 0.15

    private let source: DataSource
    private let queue = DispatchQueue(label: "xyz.vvzvlad.vscode-switcher.snapshot", qos: .userInitiated)
    private let watchedPaths: [String]

    private var timer: Timer?
    private var interval: TimeInterval = SnapshotStore.idleInterval
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var debounce: Task<Void, Never>?

    /// A rebuild is running right now; a request that arrives meanwhile is
    /// remembered instead of piling up another pass over the disk.
    private var refreshInFlight = false
    private var refreshRequested = false

    init(config: Config) {
        source = DataSource(config: config)
        watchedPaths = [ClaudeSessions.windowStatusDirectory.path,
                        ClaudeSessions.sessionsDirectory.path]
    }

    // MARK: - Lifecycle

    func start() {
        armWatchers()
        schedule(interval: Self.idleInterval)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        debounce = nil
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
    }

    /// Speeds the polling up while the panel is on screen and asks for an
    /// immediate rebuild so the visible list catches up at once.
    func setPanelVisible(_ visible: Bool) {
        schedule(interval: visible ? Self.activeInterval : Self.idleInterval)
        if visible { refresh() }
    }

    // MARK: - Refresh

    /// Requests a rebuild off the main thread. Cheap to call often.
    func refresh() {
        guard !refreshInFlight else {
            refreshRequested = true
            return
        }
        refreshInFlight = true
        let source = source
        Task { [weak self] in
            let value = await Self.build(from: source)
            guard let self else { return }
            self.apply(value)
        }
    }

    /// The blocking part, pushed off the main actor.
    private nonisolated static func build(from source: DataSource) async -> SwitcherSnapshot {
        await Task.detached(priority: .userInitiated) { source.snapshot() }.value
    }

    private func apply(_ value: SwitcherSnapshot) {
        snapshot = value
        refreshInFlight = false
        if refreshRequested {
            refreshRequested = false
            refresh()
        }
    }

    // MARK: - Timer

    private func schedule(interval: TimeInterval) {
        guard timer == nil || interval != self.interval else { return }
        self.interval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The watched directories may appear only after the hooks are
                // installed, so re-arming is retried on every tick.
                self.armWatchers()
                self.refresh()
            }
        }
        // `.common` keeps the poll alive while a menu or a resize loop is up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - File system watchers

    /// Watches `~/.claude/window-status` and `~/.claude/sessions` so a state
    /// change from a hook shows up without waiting for the next poll.
    private func armWatchers() {
        for path in watchedPaths where watchers[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
                queue: queue)
            watcher.setEventHandler {
                let events = watcher.data
                // The directory itself going away means the watcher has to be
                // dropped so the next tick can re-open it once it is recreated.
                let vanished = !events.intersection([.delete, .rename, .revoke]).isEmpty
                Task { @MainActor [weak self] in
                    self?.watcherFired(path: path, vanished: vanished)
                }
            }
            watcher.setCancelHandler { close(descriptor) }
            watcher.resume()
            watchers[path] = watcher
        }
    }

    private func watcherFired(path: String, vanished: Bool) {
        if vanished { watchers.removeValue(forKey: path)?.cancel() }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.watchDebounce * 1000)))
            guard !Task.isCancelled, let self else { return }
            self.refresh()
        }
    }
}

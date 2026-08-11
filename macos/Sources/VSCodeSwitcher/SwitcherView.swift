import AppKit
import SwiftUI

// MARK: - View model

/// One rendered group of rows.
struct SwitcherSection: Identifiable {
    var id: String { title }
    var title: String
    var rows: [SwitcherRow]
}

/// State of the panel's list: the snapshot being rendered, the search text and
/// which row is the frontmost editor window.
///
/// The sections are computed rather than stored, so a snapshot arriving
/// mid-typing cannot leave the filter and the list out of step. Filtering a few
/// hundred rows costs far less than a frame.
@MainActor
final class SwitcherViewModel: ObservableObject {

    @Published var query: String = ""
    /// `id` of the row whose window is frontmost, highlighted in the list.
    ///
    /// A row's `id` carries the window's `CGWindowID`, so it means the same row
    /// before and after a raise; keying the highlight on anything derived from
    /// the project instead would tie two windows of one project together.
    @Published private(set) var frontmostRowID: String?
    /// Set by the controller once it has taken keyboard focus for the panel.
    @Published var searchFieldFocused = false
    /// The panel is on screen — false for most of the app's life.
    ///
    /// `withAnimation(.repeatForever)` does not stop when the window is ordered
    /// out, and a row in `working` or `permission` is the normal state of this
    /// user's machine. SwiftUI therefore went on laying the whole list out and
    /// rendering its display list at display-link rate into a window nobody
    /// could see: measured at 13.6% of a core with the panel closed, against
    /// 2.0% once it stops. `StateBadge` keys its pulse on this as well as on the
    /// state.
    @Published private(set) var panelVisible = false
    @Published private(set) var snapshot: SwitcherSnapshot = .empty
    /// Row identifiers of the "open windows" section, in the order they were in
    /// when the panel appeared. `nil` until the first show.
    ///
    /// `nil` and `[]` are different states on purpose: "no order has been frozen"
    /// against "an order was frozen while no window was open". The panel is
    /// routinely summoned with the editor closed, and an empty list is then a
    /// perfectly good frozen order — the windows opened from the panel after
    /// that have to be appended to it. Told apart by emptiness alone, that case
    /// read as "no freeze": the rule that records newcomers switched itself off
    /// for the rest of the appearance and the list went back to live z-order,
    /// reshuffling under the pointer at every click.
    @Published private var windowOrder: [String]?
    /// Set when the panel appears: the order above came from the cache and is
    /// provisional until a snapshot whose sources were read after this instant
    /// arrives. Cleared by that snapshot, and by the first click.
    private var orderPendingSince: Date?

    /// How many *session-less* projects are listed when nothing is typed.
    /// Search still looks through all of them.
    static let projectLimit = 30

    /// A row was clicked: focus that window or open that project.
    var onActivate: ((SwitcherRow) -> Void)?
    /// The user clicked the search field and wants to type into it.
    var onSearchFieldTap: (() -> Void)?
    /// The user clicked the Accessibility banner.
    var onGrantAccessibility: (() -> Void)?

    // MARK: Input

    func update(snapshot: SwitcherSnapshot) {
        self.snapshot = snapshot
        // The order frozen at show time came from the cache, which is up to two
        // seconds old and has no watcher behind it — nothing tells the store
        // that a window was opened. A window opened a second before the panel
        // was summoned was therefore missing from it, counted as "appeared
        // while the panel was up" and pinned to the *bottom* of the list for as
        // long as the panel stayed open — and the newest window is usually the
        // one being looked for. So the freeze is redone once, on the first
        // snapshot that was actually read after the panel appeared. It also
        // covers the degenerate case of a panel shown before the very first
        // snapshot, where the frozen order was empty and every click reshuffled
        // the list.
        //
        // Redone by insertion, not by replacement: the assembly takes 40–180 ms
        // and the slide-in 140 ms, so this lands exactly when the panel has
        // arrived and become worth aiming at. Replacing the whole order there
        // reshuffled the list under a pointer already on its way to a row.
        if let pendingSince = orderPendingSince, snapshot.generatedAt >= pendingSince {
            windowOrder = Self.merged(windowOrder ?? [], with: snapshot.openWindows.map(\.id))
            orderPendingSince = nil
        }
        // A window opened while the panel is up joins the frozen order the first
        // time it is seen, instead of being left out of it for `ordered` to
        // append on every pass. Left out, its place was decided by live z-order:
        // clicking two projects in a row put the two new rows at the bottom, and
        // clicking either of them swapped them under the pointer — the list
        // moving from a click, which is what the freeze exists to stop. Not
        // while the re-freeze is still pending: the order is provisional until
        // then, and a newcomer belongs in the z-order slot `merged` gives it.
        // An order frozen empty counts as frozen — that is the panel summoned
        // with no editor window at all, where every row that ever appears is a
        // newcomer and this rule is the only thing holding the list still.
        if orderPendingSince == nil, let frozen = windowOrder {
            var order = frozen
            var known = Set(frozen)
            for row in snapshot.openWindows where !known.contains(row.id) {
                known.insert(row.id)
                order.append(row.id)
            }
            if order.count != frozen.count { windowOrder = order }
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let id = Self.frontmostWindowID(in: snapshot, frontmostPID: pid) { frontmostRowID = id }
    }

    /// Called when the panel opens, so every appearance starts on a clean list
    /// and a freshly frozen window order.
    func panelDidShow() {
        query = ""
        windowOrder = snapshot.openWindows.map(\.id)
        orderPendingSince = Date()
        panelVisible = true
    }

    /// Called when the panel starts going away. Only the pulse cares — see
    /// `panelVisible`.
    func panelDidHide() {
        panelVisible = false
    }

    /// A row was clicked. Moves the highlight at once — the next snapshot
    /// confirms it a beat later — and settles the window order for good.
    ///
    /// The click is about to raise a window or open a new one, and both change
    /// the z-order the next snapshot reports. Whatever the list looked like when
    /// the user aimed at it is what it has to keep looking like, so the order in
    /// force at this instant is written down and the pending re-freeze dropped.
    /// Clearing the pending flag alone was not enough: when the order was still
    /// empty — the panel's first appearance after launch, before any snapshot —
    /// the windows on screen appeared in it nowhere, so the list was laid out by
    /// raw z-order and jumped after every click, which is the defect the freeze
    /// was built for.
    ///
    /// And when there is nothing to write down, the wait stays on. The panel can
    /// be summoned with no editor window at all — the editor is closed, or the
    /// grant has only just been given — and then the only thing to click is a
    /// project. Settling an empty order there cancelled the re-freeze that was
    /// the one thing left to fix it, and every window opened from the panel
    /// afterwards was ordered by live z-order again.
    func rowActivated(_ row: SwitcherRow) {
        if orderPendingSince != nil {
            let settled = Self.ordered(snapshot.openWindows, by: windowOrder).map(\.id)
            if !settled.isEmpty {
                windowOrder = settled
                orderPendingSince = nil
            }
        }
        guard row.kind == .window else { return }
        frontmostRowID = row.id
    }

    // MARK: Derived list

    var sections: [SwitcherSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [SwitcherSection] = []

        let windows = Self.ordered(snapshot.openWindows, by: windowOrder)
            .filter { Self.matches($0, needle) }
        if !windows.isEmpty {
            result.append(SwitcherSection(title: "Открытые окна", rows: windows))
        }

        var projects = snapshot.projects.filter { Self.matches($0, needle) }
        if needle.isEmpty { projects = Self.limited(projects, to: Self.projectLimit) }
        if !projects.isEmpty {
            result.append(SwitcherSection(title: "Проекты", rows: projects))
        }
        return result
    }

    /// Caps the list of projects without ever hiding a row that has a live
    /// session behind it.
    ///
    /// `snapshot.projects` is a concatenation: first the projects with no window
    /// of their own, ordered by directory mtime, then — at the very end — the
    /// orphan `cwd:` rows for sessions running outside every scan root. A flat
    /// `prefix` therefore drops every orphan the moment the index holds more
    /// projects than the limit, which it always does. The same cut hides a
    /// project inside a root whose directory mtime is old (editing files does
    /// not move it), so an agent stuck on a permission dialog could sit there
    /// for hours without ever appearing. The data layer is deliberately total —
    /// "a working agent must never silently vanish from the list" — and the
    /// limit is not allowed to undo that.
    static func limited(_ rows: [SwitcherRow], to limit: Int) -> [SwitcherRow] {
        var remaining = limit
        return rows.filter { row in
            guard row.sessions.isEmpty else { return true }
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    /// Puts the open windows back into the order frozen at the last show.
    ///
    /// `DataSource` hands them over in z-order, which is correct of it and
    /// unusable here: raising a window is exactly what the panel is for, and the
    /// next snapshot — one second later at most — moved the row the user had
    /// just clicked to the top and shifted every other row under the pointer.
    /// Stepping through several windows in a row meant chasing a list that
    /// reshuffled after each click. Only the sequence is frozen; the contents of
    /// the rows keep updating.
    ///
    /// Matching is by `row.id`, which carries the `CGWindowID`, so a window that
    /// was closed simply drops out and leaves no hole, and one opened while the
    /// panel is up is appended rather than wedged into the middle. The order is
    /// taken afresh at every show — from the first snapshot read after that show
    /// (see `update(snapshot:)`) — so the list is back in z-order, most recently
    /// used first, as soon as the panel is reopened.
    ///
    /// `nil` means no order has been frozen yet, and only then is the raw z-order
    /// handed back untouched. An order frozen while no window was open is `[]`,
    /// which is a frozen order like any other: its rows are all newcomers and
    /// keep the sequence `update(snapshot:)` recorded them in.
    static func ordered(_ rows: [SwitcherRow], by order: [String]?) -> [SwitcherRow] {
        guard let order else { return rows }
        var position: [String: Int] = [:]
        for (index, id) in order.enumerated() where position[id] == nil { position[id] = index }

        var frozen: [(Int, SwitcherRow)] = []
        var appeared: [SwitcherRow] = []
        for row in rows {
            if let index = position[row.id] { frozen.append((index, row)) } else { appeared.append(row) }
        }
        frozen.sort { $0.0 < $1.0 }
        return frozen.map(\.1) + appeared
    }

    /// Folds a fresh z-order into an order already frozen, by inserting only the
    /// windows the frozen one has never heard of.
    ///
    /// This runs once per appearance, at the worst possible moment: the panel
    /// has just finished sliding in and the pointer is already travelling
    /// towards a row. Taking the fresh order wholesale moved every row that had
    /// been raised since the cached snapshot was read — for the sake of the one
    /// window that genuinely was missing. A new window still lands where its
    /// z-order says, so the window opened a second before the panel was summoned
    /// is still at the top; the rows below the insertion point still shift by
    /// one, which is as little as this can move at all.
    ///
    /// The insertion point is the frozen slot of the closest window in front of
    /// the newcomer, so several new windows keep their relative z-order, and one
    /// that is frontmost overall goes to the very top.
    ///
    /// Unless that slot is the last one, which would put the newest window at the
    /// very bottom of the list — the one place it must not be. It happens
    /// whenever the window in front of the newcomer is the *oldest* one in the
    /// frozen order: open a window, then click an old one, then summon the panel.
    /// The closest known window *behind* the newcomer is then the anchor instead,
    /// and the newcomer goes in just above it — the same rule seen from the other
    /// side. With nothing known behind it either, the end is where it belongs.
    static func merged(_ order: [String], with fresh: [String]) -> [String] {
        var result = order
        var anchor: Int?
        for (offset, id) in fresh.enumerated() {
            if let index = result.firstIndex(of: id) {
                anchor = index
                continue
            }
            var insertAt = anchor.map { $0 + 1 } ?? 0
            if insertAt == result.count,
               let behind = fresh[(offset + 1)...].lazy.compactMap({ result.firstIndex(of: $0) }).first {
                insertAt = behind
            }
            result.insert(id, at: insertAt)
            anchor = insertAt
        }
        return result
    }

    private static func matches(_ row: SwitcherRow, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if row.displayName.lowercased().contains(needle) { return true }
        if let topic = row.chatTopic, topic.lowercased().contains(needle) { return true }
        return false
    }

    /// The frontmost editor window, if the editor is the active application.
    ///
    /// This is the one place the z-order is still the right answer: which window
    /// is in front is precisely what `windowIndex == 0` means. The window list is
    /// built per process, so index 0 repeats for every running editor instance;
    /// only the one belonging to the active process is actually in front. When
    /// something else is active the previous highlight is kept rather than
    /// guessed at.
    static func frontmostWindowID(in snapshot: SwitcherSnapshot, frontmostPID: pid_t?) -> String? {
        guard let frontmostPID else { return nil }
        let row = snapshot.openWindows.first {
            $0.window?.pid == frontmostPID && $0.window?.windowIndex == 0
        }
        return row?.id
    }
}

// MARK: - Root view

struct SwitcherView: View {
    @ObservedObject var model: SwitcherViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if !model.snapshot.accessibilityTrusted {
                AccessibilityBanner { model.onGrantAccessibility?() }
                Divider()
            }
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel deliberately does not take keyboard focus on its own; the
        // controller flips `searchFieldFocused` only after the user clicks the
        // field, and this keeps the SwiftUI focus in step with it.
        .onChange(of: model.searchFieldFocused) { _, wanted in searchFocused = wanted }
        .onChange(of: searchFocused) { _, focused in
            if !focused { model.searchFieldFocused = false }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .medium))
                TextField("Поиск проекта или темы", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            // Until the panel holds keyboard focus the text field cannot edit
            // anything, so the first click is caught here and asks the
            // controller for focus instead of landing in a dead field. The
            // catcher spans the field only: stretched across the whole row it
            // also swallowed the clicks meant for the clear button beside it,
            // which is reachable exactly when the field is not focused but the
            // query is not empty.
            .overlay {
                if !model.searchFieldFocused {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.onSearchFieldTap?() }
                }
            }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    private var list: some View {
        // Once per pass: `sections` sorts the windows and filters both lists, and
        // reading it twice did all of that twice on every rebuild.
        let sections = model.sections
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        // Keyed on `SwitcherRow.id`, which holds the window's
                        // `CGWindowID`: raising a window reorders the rows but
                        // renames none of them, so SwiftUI keeps each row's
                        // `@State` — its hover highlight — and the scroll
                        // position across the click.
                        ForEach(section.rows) { row in
                            SwitcherRowView(row: row,
                                            isFrontmost: row.id == model.frontmostRowID,
                                            panelVisible: model.panelVisible)
                                .contentShape(Rectangle())
                                .onTapGesture { model.onActivate?(row) }
                        }
                    } header: {
                        SectionHeader(title: section.title, count: section.rows.count)
                    }
                }
                if sections.isEmpty {
                    Text(model.snapshot.generatedAt == .distantPast ? "Загрузка…" : "Ничего не найдено")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Accessibility banner

/// Clickable prompt shown when the Accessibility permission is missing: without
/// it the editor's windows cannot be enumerated at all.
private struct AccessibilityBanner: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            Text("Нет доступа к Accessibility — окна не видны, состояния агентов видны. Нажмите, чтобы выдать")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        // `push` and `pop` have to balance, and `onHover` does not guarantee it
        // on its own: it repeats `true` when SwiftUI rebuilds the row (once a
        // second here), and it never delivers `false` when the view simply
        // leaves the hierarchy — which is exactly what this banner does the
        // moment the permission is granted. Either one leaves the pointing hand
        // stuck over the whole panel until the app restarts, with nothing left
        // to pop it. Hence the state guard and the teardown.
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            guard hovering else { return }
            hovering = false
            NSCursor.pop()
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Row

struct SwitcherRowView: View {
    let row: SwitcherRow
    /// True for the row whose window is currently in front.
    let isFrontmost: Bool
    /// Passed through to `StateBadge`, which must not animate off screen.
    var panelVisible: Bool = true

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color(hex: row.colorHex) ?? .accentColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)
            metrics
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(backgroundColor))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(tooltip)
    }

    private var subtitle: String? {
        guard let topic = row.chatTopic?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces), !topic.isEmpty
        else { return nil }
        return topic
    }

    @ViewBuilder
    private var metrics: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                if row.activeSubagents > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 9))
                        Text("\(row.activeSubagents)")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                }
                if let state = row.state {
                    StateBadge(state: state, count: row.stateCount, panelVisible: panelVisible)
                }
            }
            HStack(spacing: 6) {
                if let context = Self.contextLabel(used: row.contextUsedTokens,
                                                   fraction: row.contextFraction) {
                    Text(context)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let model = Self.shortModelName(row.model) {
                    Text(model)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Hover deepens the frontmost highlight instead of replacing it: swapping
    /// the accent tint for the plain grey one made pointing at the front row
    /// *less* visible than not pointing at it, while §4 asks for the opposite.
    private var backgroundColor: Color {
        if isFrontmost { return Color.accentColor.opacity(isHovering ? 0.34 : 0.20) }
        return isHovering ? Color.primary.opacity(0.10) : .clear
    }

    private var tooltip: String {
        var lines: [String] = [row.displayName]
        if let topic = subtitle { lines.append(topic) }
        if !row.subagentDescriptions.isEmpty {
            lines.append("")
            lines.append("Фоновые агенты:")
            lines.append(contentsOf: row.subagentDescriptions.map { "• " + $0 })
        }
        // An orphan row has no indexed project, only the sessions' working
        // directory — and that is the one thing worth showing about it.
        if row.kind == .project, let path = row.project?.path ?? row.sessions.first?.cwd {
            lines.append("")
            lines.append(path)
        }
        return lines.joined(separator: "\n")
    }

    /// Context usage as a percentage, or the raw token count when the size of
    /// the window is genuinely unknown.
    ///
    /// The data layer reports `nil` rather than guessing a limit, and the UI
    /// keeps that honesty: a confidently wrong percentage — a 1M session shown
    /// at 97% because 200k was assumed — is worse than no percentage at all.
    static func contextLabel(used: Int?, fraction: Double?) -> String? {
        if let fraction { return "\(Int((fraction * 100).rounded()))%" }
        guard let used, used > 0 else { return nil }
        return used >= 1000 ? "\(used / 1000)k" : "\(used)"
    }

    /// `claude-opus-5` → `opus-5`, `claude-3-5-sonnet-20241022` → `3-5-sonnet`.
    static func shortModelName(_ raw: String?) -> String? {
        guard var name = raw, !name.isEmpty else { return nil }
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        // Drop a trailing release date such as `-20241022`.
        if let range = name.range(of: "-[0-9]{8}$", options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name.isEmpty ? nil : name
    }
}

// MARK: - State badge

struct StateBadge: View {
    let state: AgentState
    let count: Int
    /// The badge is on screen. See `pulseState`.
    var panelVisible: Bool = true

    @State private var pulsing = false

    /// The state to pulse for, or `nil` when there must be no pulse at all —
    /// including "the panel is not on screen", because `repeatForever` outlives
    /// the window it was started in (see `SwitcherViewModel.panelVisible`).
    ///
    /// Both the `task` id and the dot's own identity hang off this, and both are
    /// needed: the task decides when to start a pulse, the identity is what ends
    /// one.
    var pulseState: AgentState? {
        guard panelVisible, Self.animates(state) else { return nil }
        return state
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Self.color(for: state))
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.3 : 1)
                .scaleEffect(pulsing ? 0.78 : 1)
                // The one thing that actually *stops* a `repeatForever`. Writing
                // `pulsing = false` below only moves the value the animation
                // drives at; the cycle goes on running against a target it
                // already sits at — invisible, and every bit as expensive, since
                // SwiftUI keeps laying the list out and rendering its display
                // list once per display cycle. Probed: a single `working` row,
                // panel closed, nothing pulsing on screen, 13.6% of a core. It
                // dropped to 2.0% with this line, and to nothing more with the
                // window's content view hidden as well, which was the other
                // candidate. A new identity throws the animated attribute away
                // and the animation attached to it with it.
                .id(pulseState)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.color(for: state))
            }
        }
        // Keyed on `pulseState`, not on appearance. The badge sits in a stable
        // spot in the hierarchy, so when a row changes state SwiftUI reuses the
        // view and `onAppear` never runs again: a `working` row that received
        // `Stop` turned green and kept the endless pulse of the blue dot it
        // replaced, and a row first drawn as `idle` never started pulsing when
        // the agent began its turn. With updates once a second that is the
        // normal case, not an edge one — and §3 says the pulse means "working".
        .task(id: pulseState) {
            pulsing = false
            guard pulseState != nil else { return }
            // Let the reset land in its own transaction. Both mutations in one
            // pass would cancel out for a state change that keeps the animation
            // on (working → permission), leaving the previous rhythm running.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: state == .permission ? 0.55 : 0.9)
                .repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .help(Self.label(for: state))
    }

    /// Semantic system colours only — they follow light and dark appearance.
    static func color(for state: AgentState) -> Color {
        switch state {
        case .permission: return .orange
        case .waiting: return .green
        case .working: return .blue
        case .idle: return .secondary
        }
    }

    static func animates(_ state: AgentState) -> Bool {
        state == .permission || state == .working
    }

    static func label(for state: AgentState) -> String {
        switch state {
        case .permission: return "Ждёт разрешения"
        case .waiting: return "Ответил, ждёт реакции"
        case .working: return "Работает"
        case .idle: return "Простаивает"
        }
    }
}

// MARK: - Colour helper

extension Color {
    /// Parses the `#rrggbb` strings the project index produces.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }
}

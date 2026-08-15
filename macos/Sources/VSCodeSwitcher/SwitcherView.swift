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
    /// out, and a row with something running in it is the normal state of this
    /// user's machine. SwiftUI therefore went on laying the whole list out and
    /// rendering its display list at display-link rate into a window nobody
    /// could see: measured at 13.6% of a core with the panel closed, against
    /// 2.0% once it stops. `StatusBadge` keys its pulse on this as well as on the
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
    /// for the rest of the appearance and the list went back to the live order
    /// from the data layer, reshuffling under the pointer at every click.
    @Published private var windowOrder: [String]?
    /// Set when the panel appears: the order above came from the cache and is
    /// provisional until a snapshot whose sources were read after this instant
    /// arrives. Cleared by that snapshot, and by the first click.
    private var orderPendingSince: Date?

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
        // append on every pass. Left out, its place was decided by the live
        // order: clicking two projects in a row put both new rows at the bottom, and
        // clicking either of them swapped them under the pointer — the list
        // moving from a click, which is what the freeze exists to stop. Not
        // while the re-freeze is still pending: the order is provisional until
        // then, and a newcomer belongs in the slot `merged` gives it.
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
    /// the order the next snapshot reports. Whatever the list looked like when
    /// the user aimed at it is what it has to keep looking like, so the order in
    /// force at this instant is written down and the pending re-freeze dropped.
    /// Clearing the pending flag alone was not enough: when the order was still
    /// empty — the panel's first appearance after launch, before any snapshot —
    /// the windows on screen appeared in it nowhere, so the list was laid out by
    /// the raw order and jumped after every click, which is the defect the freeze
    /// was built for.
    ///
    /// And when there is nothing to write down, the wait stays on. The panel can
    /// be summoned with no editor window at all — the editor is closed, or the
    /// grant has only just been given — and then the only thing to click is a
    /// project. Settling an empty order there cancelled the re-freeze that was
    /// the one thing left to fix it, and every window opened from the panel
    /// afterwards was ordered by the live order again.
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

        // Every project, in the order `DataSource.ranked` put them in. There was
        // a cap of thirty here, and it cost more than it saved: the section had
        // to be read as "the top of the list" rather than "the list", and the
        // rows it dropped were exactly the ones the ranking is now good at
        // finding. `LazyVStack` builds only the rows on screen, so the length is
        // not what the list costs.
        let projects = snapshot.projects.filter { Self.matches($0, needle) }
        if !projects.isEmpty {
            result.append(SwitcherSection(title: "Проекты", rows: projects))
        }
        return result
    }

    /// Puts the open windows back into the order frozen at the last show.
    ///
    /// `DataSource` hands them over newest-message-first, which is correct of it
    /// and unusable live: the list would move whenever an agent said something,
    /// and raising a window — exactly what the panel is for — used to do the same
    /// back when the order was the z-order. Either way the next snapshot, one
    /// second later at most, shifted rows under the pointer, and stepping through
    /// several windows meant chasing a list that reshuffled after each click.
    /// Only the sequence is frozen; the contents of the rows keep updating.
    ///
    /// Matching is by `row.id`, which carries the `CGWindowID`, so a window that
    /// was closed simply drops out and leaves no hole, and one opened while the
    /// panel is up is appended rather than wedged into the middle. The order is
    /// taken afresh at every show — from the first snapshot read after that show
    /// (see `update(snapshot:)`) — so the list is fresh again, the window with the
    /// last message on top, as soon as the panel is reopened.
    ///
    /// `nil` means no order has been frozen yet, and only then is the data
    /// layer's own order handed back untouched. An order frozen while no window was open is `[]`,
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

    /// Folds a fresh order into an order already frozen, by inserting only the
    /// windows the frozen one has never heard of.
    ///
    /// This runs once per appearance, at the worst possible moment: the panel
    /// has just finished sliding in and the pointer is already travelling
    /// towards a row. Taking the fresh order wholesale moved every row that had
    /// moved since the cached snapshot was read — for the sake of the one window
    /// that genuinely was missing. A new window still lands where the fresh order
    /// puts it, so the window opened a second before the panel was summoned is
    /// still at the top; the rows below the insertion point still shift by one,
    /// which is as little as this can move at all.
    ///
    /// The insertion point is the frozen slot of the closest window ahead of the
    /// newcomer, so several new windows keep their relative order, and one that
    /// leads the fresh order overall goes to the very top.
    ///
    /// Unless that slot is the last one, which would put the newest window at the
    /// very bottom of the list — the one place it must not be. It happens
    /// whenever the window ahead of the newcomer is the *last* one in the frozen
    /// order: open a window, work in an older one, then summon the panel.
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
    /// Passed through to `StatusBadge`, which must not animate off screen.
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

    private var subtitle: String? { Self.rowSubtitle(row) }

    private var metrics: some View {
        RowMetrics(status: row.status, count: row.activeCount, panelVisible: panelVisible)
    }

    /// Hover deepens the frontmost highlight instead of replacing it: swapping
    /// the accent tint for the plain grey one made pointing at the front row
    /// *less* visible than not pointing at it, while §4 asks for the opposite.
    private var backgroundColor: Color {
        if isFrontmost { return Color.accentColor.opacity(isHovering ? 0.34 : 0.20) }
        return isHovering ? Color.primary.opacity(0.10) : .clear
    }

    private var tooltip: String { Self.tooltipText(for: row) }

    /// The row's only tooltip.
    ///
    /// There used to be a second one on the badge, so what the user read
    /// depended on which pixel the pointer had landed on. This one is on the
    /// whole row and carries everything: the icons spelled out as words, and
    /// the per-chat context and model that the row itself no longer shows.
    static func tooltipText(for row: SwitcherRow) -> String {
        var lines: [String] = [row.displayName]
        if let topic = rowSubtitle(row) { lines.append(topic) }

        if !row.sessions.isEmpty {
            lines.append("")
            lines.append("Чаты:")
            for session in row.sessions {
                var parts = [Self.stateLabel(for: session.state)]
                if let topic = shorten(session.topic, 56) { parts.append(topic) }
                if let context = contextLabel(used: session.contextUsedTokens,
                                              fraction: session.contextFraction) {
                    parts.append(context)
                }
                if let model = shortModelName(session.model) { parts.append(model) }
                lines.append("• " + parts.joined(separator: " · "))
            }
        }

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

    /// A chat's state in words. The tooltip is the only place the five states
    /// are still told apart — the row folds them into four — so this is where
    /// the vocabulary lives.
    static func stateLabel(for state: AgentState) -> String {
        switch state {
        case .question: return "Задал вопрос"
        case .permission: return "Ждёт разрешения"
        case .waiting: return "Ответил, ждёт реакции"
        case .working: return "Работает"
        case .idle: return "Простаивает"
        }
    }

    /// The chat topic as the second line of the row shows it: one line, trimmed.
    static func rowSubtitle(_ row: SwitcherRow) -> String? {
        guard let topic = row.chatTopic?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces), !topic.isEmpty
        else { return nil }
        return topic
    }

    /// One line, cut with an ellipsis. A topic falls back to the last prompt,
    /// which can be a whole paragraph.
    static func shorten(_ raw: String?, _ limit: Int) -> String? {
        guard let text = raw?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces), !text.isEmpty
        else { return nil }
        guard text.count > limit else { return text }
        return text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
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

// MARK: - Right-hand columns

/// Two fixed columns on the right of every row: how much is running, then the
/// one indicator saying what the window wants.
///
/// Both slots keep their width whether or not they have anything in them, so the
/// indicator sits at the same x in every row of the list. Chips packed side by
/// side moved it left and right from row to row depending on what each row
/// happened to hold, and a column that will not hold still cannot be scanned.
///
/// The per-state breakdown that used to be here is gone on purpose: what is
/// wanted from a window is one answer, not a census of its chats. The census is
/// in the tooltip, and so are the context percentage and the model — those
/// belong to *one* chat, and standing next to numbers that count them all was
/// exactly what confused the block.
///
/// Split out of `SwitcherRowView` so the layout test can render the block the
/// panel actually draws rather than a copy of it: the fixed columns are the
/// whole point of this round, and a test of a replica proves nothing about the
/// original.
struct RowMetrics: View {
    let status: RowStatus?
    let count: Int
    var panelVisible: Bool = true

    /// Two digits wide. The busiest window on this machine runs five or six
    /// subagents, so a third digit would widen every row in the list for a case
    /// that does not happen.
    static let countWidth: CGFloat = 15
    static let spacing: CGFloat = 5
    /// What the block measures, whatever is in it. Pinned by a test.
    static var totalWidth: CGFloat { countWidth + spacing + StatusBadge.boxWidth }

    var body: some View {
        HStack(spacing: Self.spacing) {
            // `lineLimit` and `fixedSize` together are what make a count too big
            // for the slot draw *in full*, spilling left into the gap: without
            // them the number wrapped inside the 15 pt frame instead, so a
            // hypothetical 123 came out as "12" over "3". Measured, not
            // eyeballed — see `RowMetricsLayoutTests`.
            Text(count > 0 ? "\(count)" : "")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Self.countWidth, alignment: .trailing)
            // The badge draws itself in a box of its own — empty box included,
            // for a row with nothing to report — so this slot needs no width of
            // its own: one place decides it, and the two cannot drift apart.
            StatusBadge(status: status, panelVisible: panelVisible)
        }
    }
}

// MARK: - Status badge

/// The row's single indicator: what the window wants, folded from every chat and
/// subagent in it (`SwitcherRow.status`).
///
/// A `nil` status draws an empty box of the same size. The slot is what has to
/// be fixed, not the icon: a row with no chat and no subagent has nothing to
/// report, and an icon there would say "asleep" about a project that simply has
/// no agent — the same mark on ninety-odd rows of the "projects" section,
/// distinguishing nothing.
struct StatusBadge: View {
    let status: RowStatus?
    /// The badge is on screen. See `pulseState`.
    var panelVisible: Bool = true

    /// The slot every glyph is centred in, and the empty case holds. Pinned by
    /// a test, and quoted by `RowMetrics.totalWidth`.
    static let boxWidth: CGFloat = 14
    static let boxHeight: CGFloat = 12

    @State private var pulsing = false

    /// The status to pulse for, or `nil` when there must be no pulse at all —
    /// including "the panel is not on screen", because `repeatForever` outlives
    /// the window it was started in (see `SwitcherViewModel.panelVisible`).
    ///
    /// Both the `task` id and the icon's own identity hang off this, and both
    /// are needed: the task decides when to start a pulse, the identity is what
    /// ends one.
    var pulseState: RowStatus? {
        guard panelVisible, let status, Self.animates(status) else { return nil }
        return status
    }

    var body: some View {
        Group {
            // An icon rather than a coloured dot: the dot told the user there
            // was *a* state and left the meaning to be memorised. Each of the
            // four shapes is different enough to be read without the colour,
            // and the tooltip spells the chats out in words.
            if let status {
                Image(systemName: Self.symbol(for: status))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.color(for: status))
            } else {
                Color.clear
            }
        }
        // A fixed box, because the four glyphs are not the same size — measured
        // at 11 pt semibold, the moon is the narrowest of them and also three
        // points taller than the box, which it simply overhangs — and because
        // the empty case has to hold the same ground. Without it the indicator
        // would sit at a different x in every row, which is the whole complaint
        // this answers.
        .frame(width: Self.boxWidth, height: Self.boxHeight)
        .opacity(pulsing ? 0.35 : 1)
        .scaleEffect(pulsing ? 0.86 : 1)
        // The one thing that actually *stops* a `repeatForever`. Writing
        // `pulsing = false` below only moves the value the animation drives at;
        // the cycle goes on running against a target it already sits at —
        // invisible, and every bit as expensive, since SwiftUI keeps laying the
        // list out and rendering its display list once per display cycle.
        // Probed: a single working row, panel closed, nothing pulsing on
        // screen, 13.6% of a core. It dropped to 2.0% with this line, and to
        // nothing more with the window's content view hidden as well, which was
        // the other candidate. A new identity throws the animated attribute
        // away and the animation attached to it with it.
        .id(pulseState)
        // Keyed on `pulseState`, not on appearance. The badge sits in a stable
        // spot in the hierarchy, so when a row changes status SwiftUI reuses
        // the view and `onAppear` never runs again: an `active` row that
        // received `Stop` turned green and kept the endless pulse of the blue
        // icon it replaced, and a row first drawn asleep never started pulsing
        // when the agent began its turn. With updates once a second that is the
        // normal case, not an edge one.
        .task(id: pulseState) {
            pulsing = false
            guard pulseState != nil else { return }
            // Let the reset land in its own transaction. Both mutations in one
            // pass would cancel out for a change that keeps the animation on,
            // leaving the previous rhythm running.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        // No `.help` here on purpose. The row carries one tooltip for the whole
        // line; a second one on the badge made the text the user got depend on
        // which pixel the pointer happened to be over.
    }

    /// SF Symbols, one shape per status. Three of the shapes are the ones the
    /// states they fold used to wear, so the habit carries over: the green tick
    /// of an answered chat, the turning arrows of a working one, the sleeping
    /// moon. The raised hand is the new one, and it reads as what it is — a
    /// chat that stopped mid-task and is holding its hand up.
    static func symbol(for status: RowStatus) -> String {
        switch status {
        case .blocked: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .active: return "arrow.triangle.2.circlepath"
        case .asleep: return "moon.zzz.fill"
        }
    }

    /// Semantic system colours only — they follow light and dark appearance.
    static func color(for status: RowStatus) -> Color {
        switch status {
        case .blocked: return .orange
        case .done: return .green
        case .active: return .blue
        case .asleep: return .secondary
        }
    }

    /// Only movement pulses. Neither `blocked` nor `done` does: both are states
    /// the window rests in for as long as the user takes to come back, and a
    /// list where half the rows blink is a list nothing stands out in. `blocked`
    /// is told apart by its own glyph and colour instead — that is the choice
    /// the user made when asked, over a pulse.
    static func animates(_ status: RowStatus) -> Bool { status == .active }
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

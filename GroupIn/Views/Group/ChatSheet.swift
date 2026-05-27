//
//  ChatSheet.swift
//  GroupIn
//
//  Unified group timeline — interleaves chat messages with structural
//  events (joins, removes, bans, extensions) in chronological order.
//  Reads from `AppState.eventsByGroup`, which is populated by CloudKit
//  sync, BLE gossip, and local emits alike, so the same conversation
//  renders identically on every device regardless of how each event
//  arrived.
//
//  Scroll-to-top triggers paginated history loading via
//  `AppState.loadOlderEvents(for:)`. When the response comes back
//  smaller than a page, we stop firing and surface a "Start of group"
//  marker.
//

import SwiftUI

struct ChatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @State private var isLoadingOlder = false
    @State private var didInitialFetch = false
    @State private var infoEvent: Event?
    @FocusState private var inputFocused: Bool

    private static let maxLength = 240

    /// Fixed deep cyan for my own bubbles. We can't use `.accentColor`
    /// here: in dark mode the brand accent is bright cyan, and white
    /// text on it fails contrast. This deeper tone keeps white text
    /// readable in both light and dark while still reading as brand.
    private static let myBubbleColor = Color(red: 0.0, green: 0.48, blue: 0.62)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if timeline.isEmpty {
                    emptyState
                } else {
                    timelineList
                }
                Divider()
                inputBar
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $infoEvent) { event in
            ChatMessageInfoSheet(event: event)
                .environment(appState)
        }
        .task {
            // On first appearance, if our local log for this group
            // is empty, fetch the most recent page. Subsequent opens
            // see whatever's already in eventsByGroup plus anything
            // that's synced since.
            guard !didInitialFetch,
                  let groupID = appState.currentGroup?.id else { return }
            didInitialFetch = true
            if appState.eventsByGroup[groupID]?.isEmpty ?? true {
                await appState.loadOlderEvents(for: groupID)
            }
        }
    }

    // MARK: - Data

    /// Sorted ascending by `(createdAt, id)` so the newest event sits
    /// at the bottom of the scroll — the conventional chat layout.
    private var timeline: [Event] {
        guard let group = appState.currentGroup,
              let raw = appState.eventsByGroup[group.id] else { return [] }
        return raw.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var groupID: UUID? { appState.currentGroup?.id }

    private var hasReachedStart: Bool {
        guard let id = groupID else { return true }
        return appState.groupsAtStartOfHistory.contains(id)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Group activity and messages will show up here. They sync between members over iCloud and Bluetooth.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Timeline list

    @ViewBuilder
    private var timelineList: some View {
        let events = timeline
        ScrollViewReader { proxy in
            ScrollView {
                // Spacing is controlled per-row (tight within a sender's
                // run, looser between runs), so the stack itself is 0.
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Top sentinel: appearing in the visible region
                    // means the user scrolled to the very top — kick
                    // off an older-batch fetch (unless we're already
                    // loading or have reached the start).
                    topSentinel
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        row(for: event, at: index, in: events)
                            .id(event.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .onChange(of: timeline.last?.id) { _, _ in
                guard let lastID = timeline.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onAppear {
                // On first appear, anchor to bottom (newest visible)
                // without animation so the user lands in the right
                // place. Subsequent updates animate via the onChange
                // hook above.
                if let lastID = timeline.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var topSentinel: some View {
        if hasReachedStart {
            // Start-of-history marker. Once we've fetched a sub-page
            // batch from CloudKit, we're done loading older — no more
            // requests fire even if the user keeps scrolling up.
            HStack {
                Spacer()
                Text("Start of group")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 6)
        } else if isLoadingOlder {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 6)
        } else {
            // Use `.onAppear` on a transparent strip at the top of
            // the timeline to detect scroll-to-top. As soon as the
            // user lifts the scroll to the very first item, this
            // sentinel becomes visible and fires the loader.
            Color.clear
                .frame(height: 1)
                .onAppear {
                    Task { await fetchOlder() }
                }
        }
    }

    private func fetchOlder() async {
        guard !isLoadingOlder,
              !hasReachedStart,
              let id = groupID else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        await appState.loadOlderEvents(for: id)
    }

    // MARK: - Row dispatch

    /// Avatar gutter width for incoming messages — the avatar size plus
    /// its trailing spacing. Empty (clear) on non-last bubbles of a run
    /// so a sender's clustered messages stay left-aligned under their
    /// single avatar.
    private static let avatarSize: CGFloat = 28

    @ViewBuilder
    private func row(for event: Event, at index: Int, in events: [Event]) -> some View {
        switch event.payload {
        case .chatMessage(let text):
            let first = isFirstInRun(at: index, in: events)
            let last = isLastInRun(at: index, in: events)
            chatBubble(event: event, text: text, isFirstInRun: first, isLastInRun: last)
                // Tight gap inside a run, larger gap when a new sender
                // (or a system event) starts a fresh block.
                .padding(.top, first ? 10 : 2)
        default:
            systemRow(event: event)
                .padding(.top, 10)
        }
    }

    /// Two adjacent chat events belong to the same visual cluster when
    /// they're from the same author and close in time. A system event
    /// between them naturally breaks the run (it isn't a chat message).
    private func sameRun(_ a: Event, _ b: Event) -> Bool {
        guard case .chatMessage = a.payload,
              case .chatMessage = b.payload else { return false }
        return a.authorID == b.authorID
            && abs(b.createdAt.timeIntervalSince(a.createdAt)) < 5 * 60
    }

    private func isFirstInRun(at index: Int, in events: [Event]) -> Bool {
        guard index > 0 else { return true }
        return !sameRun(events[index - 1], events[index])
    }

    private func isLastInRun(at index: Int, in events: [Event]) -> Bool {
        guard index < events.count - 1 else { return true }
        return !sameRun(events[index], events[index + 1])
    }

    @ViewBuilder
    private func chatBubble(event: Event,
                            text: String,
                            isFirstInRun: Bool,
                            isLastInRun: Bool) -> some View {
        let myID = groupID.flatMap { appState.membershipByGroupID[$0] }
        let isMe = event.authorID == myID
        let memberColor = Color.memberColor(
            for: event.authorID,
            among: appState.currentGroup?.members.map(\.id) ?? []
        )
        let member = appState.currentGroup?
            .members
            .first(where: { $0.id == event.authorID })
        // Fall back to historical events if the member already left the
        // group: walk our own event log for a `memberJoined` carrying
        // this author's displayName.
        let senderName = member?.displayName
            ?? historicalDisplayName(for: event.authorID)
            ?? "Member"

        HStack(alignment: .bottom, spacing: 8) {
            if isMe {
                Spacer(minLength: 48)
            } else {
                // Avatar appears once per run, beside the last bubble.
                if isLastInRun {
                    AvatarView(data: member?.avatarData,
                               name: senderName,
                               size: Self.avatarSize,
                               tint: memberColor)
                        .overlay(
                            Circle().strokeBorder(memberColor.opacity(0.6), lineWidth: 1)
                        )
                } else {
                    Color.clear.frame(width: Self.avatarSize, height: Self.avatarSize)
                }
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                // Sender name only at the top of an incoming run.
                if !isMe, isFirstInRun {
                    Text(senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(memberColor)
                        .padding(.leading, 4)
                }
                Text(text)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        isMe
                            ? AnyShapeStyle(Self.myBubbleColor)
                            : AnyShapeStyle(memberColor.opacity(0.18)),
                        in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                    )
                    .foregroundStyle(isMe ? Color.white : Color.primary)
                    // 500ms visibility debounce → broadcast read
                    // receipt. WhatsApp definition: a message is
                    // "read" once it's been on the receiver's screen
                    // for ≥500ms. `.task(id:)` is scoped to row
                    // presence — when the row scrolls offscreen the
                    // task is cancelled before it can fire. Only
                    // marks events not authored by us; the AppState
                    // method early-returns on our own messages.
                    .task(id: event.id) {
                        try? await Task.sleep(for: .milliseconds(500))
                        if !Task.isCancelled {
                            appState.markEventRead(event)
                        }
                    }
                    // Long-press → context menu → "Info." Only ours
                    // get the menu (only ours have receipts to show).
                    .contextMenu {
                        if isMe {
                            Button {
                                infoEvent = event
                            } label: {
                                Label("Message Info", systemImage: "info.circle")
                            }
                        }
                    }
                // Time + delivery dot only on the last bubble of a run,
                // so a burst of messages isn't repeated under each line.
                if isLastInRun {
                    HStack(spacing: 4) {
                        Text(event.createdAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if isMe,
                           let status = appState.deliveryStatus(for: event) {
                            deliveryDot(for: status)
                        }
                    }
                }
            }

            if !isMe { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
    }

    /// Four-state WhatsApp-style delivery indicator.
    ///   • Sent (✓ themed) — durable in CloudKit.
    ///   • Delivered (✓✓ themed) — every other member's device has
    ///     received and ingested the event. Themed = `.primary`,
    ///     which adapts to light/dark mode (black on light, white on
    ///     dark) per Apple HIG.
    ///   • Read (✓✓ blue) — every other member's device has actually
    ///     rendered the message on screen for ≥500ms.
    @ViewBuilder
    private func deliveryDot(for status: EventDeliveryStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Sending")
        case .cloud:
            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityLabel("Sent")
        case .delivered:
            // Two overlapping checkmarks. Apple's SF Symbols doesn't
            // ship a double-check glyph, so we compose one from two
            // single checks slightly offset — same trick WhatsApp
            // uses on iOS where the glyph isn't in the system font.
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .accessibilityLabel("Delivered")
        case .read:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.blue)
            .accessibilityLabel("Read")
        }
    }

    @ViewBuilder
    private func systemRow(event: Event) -> some View {
        // Use the active group's members + ownerID to give the event
        // a human-readable description. Falls back to a generic
        // placeholder if we can't resolve the names.
        let members = appState.currentGroup?.members ?? []
        let ownerID = appState.currentGroup?.ownerID ?? UUID()
        let description = event.displayDescription(in: members, ownerID: ownerID)
            ?? "Group activity"

        HStack {
            Spacer()
            VStack(spacing: 2) {
                Text(description)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(event.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: Capsule())
            Spacer()
        }
    }

    /// Walk our local event log for a `memberJoined` event with the
    /// given member ID, returning its displayName. Lets ex-members'
    /// chat bubbles still show a name after they've been pruned from
    /// the live members list.
    private func historicalDisplayName(for memberID: UUID) -> String? {
        guard let id = groupID,
              let log = appState.eventsByGroup[id] else { return nil }
        for event in log {
            if case .memberJoined(let mid, let displayName, _, _) = event.payload,
               mid == memberID {
                return displayName
            }
        }
        return nil
    }

    // MARK: - Input

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { send() }
                .onChange(of: draft) { _, newValue in
                    if newValue.count > Self.maxLength {
                        draft = String(newValue.prefix(Self.maxLength))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.neonIcon(tint: .accentColor, diameter: 40))
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        appState.sendChatMessage(draft)
        draft = ""
    }
}

#Preview {
    ChatSheet()
        .environment(AppState())
}

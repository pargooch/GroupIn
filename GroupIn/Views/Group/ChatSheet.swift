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
    @FocusState private var inputFocused: Bool

    private static let maxLength = 240

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                diagnosticBanner
                transportDiagnosticStrip
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

    // MARK: - Banner

    private struct BannerInfo {
        let icon: String
        let label: String
        let tint: Color
    }

    private var bannerInfo: BannerInfo {
        if appState.bleDiagnostics.serviceAddFailed {
            return BannerInfo(
                icon: "exclamationmark.triangle.fill",
                label: "Bluetooth setup failed — try toggling Bluetooth off/on.",
                tint: .red
            )
        }
        let count = appState.transportDiagnostics.connectedPeers
        if count == 0 {
            return BannerInfo(
                icon: "antenna.radiowaves.left.and.right.slash",
                label: "No nearby members yet — messages still sync via iCloud and replay when peers come into range.",
                tint: .orange
            )
        }
        return BannerInfo(
            icon: "antenna.radiowaves.left.and.right",
            label: "Connected to \(count) nearby \(count == 1 ? "member" : "members").",
            tint: .green
        )
    }

    private var diagnosticBanner: some View {
        let info = bannerInfo
        return HStack(spacing: 8) {
            Image(systemName: info.icon)
                .foregroundStyle(info.tint)
            Text(info.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(info.tint.opacity(0.08))
    }

    /// Live read-out of the payload transport stages — exposes the
    /// difference between "no one nearby", "discovered but invitation
    /// stalled", and "session up but no data". Without this strip, the
    /// "No nearby members yet" banner conflates four distinct failure
    /// modes into one message.
    ///   browsing/advertising — service started successfully?
    ///   seen — peers discovered on the same service type
    ///   invited — peers we've sent an MPC invitation to
    ///   connected — peers in a live session
    /// `seen == 0` while browsing is a strong hint that the Local
    /// Network permission was denied (Settings → Privacy → Local Network).
    private var transportDiagnosticStrip: some View {
        let diag = appState.transportDiagnostics
        let transportName = diag.selection.map(transportLabel) ?? "—"
        return HStack(spacing: 8) {
            chip(label: "via", value: transportName)
            chip(label: "br", value: diag.isBrowsing ? "on" : "off")
            chip(label: "adv", value: diag.isAdvertising ? "on" : "off")
            chip(label: "seen", value: "\(diag.discoveredPeerCount)")
            chip(label: "inv", value: "\(diag.invitedPeerCount)")
            chip(label: "live", value: "\(diag.connectedPeers)")
            Spacer()
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func transportLabel(_ selection: TransportSelection) -> String {
        switch selection {
        case .multipeer: return "MPC"
        case .wifiAware: return "WA"
        }
    }

    private func chip(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial, in: Capsule())
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // Top sentinel: appearing in the visible region
                    // means the user scrolled to the very top — kick
                    // off an older-batch fetch (unless we're already
                    // loading or have reached the start).
                    topSentinel
                    ForEach(timeline) { event in
                        row(for: event)
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

    @ViewBuilder
    private func row(for event: Event) -> some View {
        switch event.payload {
        case .chatMessage(let text):
            chatBubble(event: event, text: text)
        default:
            systemRow(event: event)
        }
    }

    @ViewBuilder
    private func chatBubble(event: Event, text: String) -> some View {
        let myID = groupID.flatMap { appState.membershipByGroupID[$0] }
        let isMe = event.authorID == myID
        let memberColor = Color.memberColor(for: event.authorID)
        let senderName = appState.currentGroup?
            .members
            .first(where: { $0.id == event.authorID })?
            .displayName
            // Fall back to historical events if the member already
            // left the group: walk our own event log for a
            // `memberJoined` carrying this author's displayName.
            ?? historicalDisplayName(for: event.authorID)
            ?? "Member"

        HStack(alignment: .bottom, spacing: 8) {
            if isMe { Spacer(minLength: 48) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                if !isMe {
                    Text(senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(memberColor)
                }
                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isMe
                            ? Color.accentColor
                            : memberColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .foregroundStyle(isMe ? Color.white : Color.primary)
                // Time + delivery dot row. Dots render only on our
                // own outgoing bubbles — others' status is not ours
                // to display.
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

            if !isMe { Spacer(minLength: 48) }
        }
    }

    /// Three-state WhatsApp-style delivery indicator. The single
    /// check matches "sent to the cloud, durable now"; the double
    /// check matches "every other member has acknowledged it."
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
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sent")
        case .delivered:
            // Two overlapping checkmarks for the "delivered" state.
            // Apple's SF Symbols doesn't ship a double-check glyph,
            // so we compose one from two single checks slightly
            // offset — same trick WhatsApp uses on iOS where the
            // glyph isn't in the system font.
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Delivered")
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
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit { send() }
                .onChange(of: draft) { _, newValue in
                    if newValue.count > Self.maxLength {
                        draft = String(newValue.prefix(Self.maxLength))
                    }
                }

            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(canSend ? Color.accentColor : Color.secondary.opacity(0.3),
                                in: Circle())
                    .foregroundStyle(.white)
            }
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

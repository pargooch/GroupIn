//
//  ChatSheet.swift
//  GroupIn
//
//  Ephemeral, BLE-only group chat. Messages are exchanged peer-to-peer
//  between in-range devices via the chat GATT characteristic; nothing
//  is persisted to CloudKit or local storage. The conversation lives
//  for the duration of the app session and the BLE link.
//

import SwiftUI

struct ChatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    private static let maxLength = 240

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                diagnosticBanner
                if appState.chatMessages.isEmpty {
                    emptyState
                } else {
                    messagesList
                }
                Divider()
                inputBar
            }
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

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
        let count = appState.bleDiagnostics.chatSubscribers
        if count == 0 {
            return BannerInfo(
                icon: "antenna.radiowaves.left.and.right.slash",
                label: "No nearby members are subscribed yet. Make sure both phones have the dashboard open and are in BLE range.",
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

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No messages yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Messages travel directly over Bluetooth to nearby members. They're not saved.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(appState.chatMessages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .onChange(of: appState.chatMessages.count) { _, _ in
                guard let last = appState.chatMessages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: ChatMessage) -> some View {
        let isMe = message.senderID == appState.currentUser.id
        let memberColor = Color.memberColor(for: message.senderID)
        let senderName = appState.currentGroup?
            .members
            .first(where: { $0.id == message.senderID })?
            .displayName ?? "Member"

        HStack(alignment: .bottom, spacing: 8) {
            if isMe { Spacer(minLength: 48) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                if !isMe {
                    Text(senderName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(memberColor)
                }
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isMe
                            ? Color.accentColor
                            : memberColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .foregroundStyle(isMe ? Color.white : Color.primary)
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isMe { Spacer(minLength: 48) }
        }
    }

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

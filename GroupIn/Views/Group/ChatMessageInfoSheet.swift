//
//  ChatMessageInfoSheet.swift
//  GroupIn
//
//  WhatsApp-style "Message Info" panel reached via long-press →
//  Message Info on an outgoing chat bubble. Renders the per-peer
//  delivered/read timestamps from `AppState.receiptInfo(for:)`,
//  plus the message's own sent timestamp. Read-only.
//

import SwiftUI

struct ChatMessageInfoSheet: View {
    let event: Event
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    timestampRow(label: "Sent",
                                 date: event.createdAt,
                                 systemImage: "paperplane.fill")
                    if let info = appState.receiptInfo(for: event),
                       info.cloudAcknowledged {
                        timestampRow(label: "On iCloud",
                                     date: nil,
                                     systemImage: "checkmark.icloud",
                                     subtitle: "Durable copy available to offline members")
                    }
                } header: {
                    Text("Message")
                }

                ForEach(otherMembers, id: \.id) { member in
                    Section {
                        receiptRow(label: "Read",
                                   date: readAt(for: member.id),
                                   systemImage: "checkmark",
                                   tint: .blue)
                        receiptRow(label: "Delivered",
                                   date: deliveredAt(for: member.id),
                                   systemImage: "checkmark",
                                   tint: .primary)
                    } header: {
                        memberHeader(member)
                    }
                }
            }
            .navigationTitle("Message Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Sections

    private var otherMembers: [User] {
        guard let group = appState.myGroups
                .first(where: { $0.id == event.groupID }) else { return [] }
        let myID = appState.membershipByGroupID[event.groupID]
        return group.members
            .filter { $0.id != myID }
            .sorted { $0.displayName < $1.displayName }
    }

    private func deliveredAt(for memberID: UUID) -> Date? {
        appState.receiptInfo(for: event)?.perPeerDelivered[memberID]
    }

    private func readAt(for memberID: UUID) -> Date? {
        appState.receiptInfo(for: event)?.perPeerRead[memberID]
    }

    // MARK: - Rows

    @ViewBuilder
    private func memberHeader(_ member: User) -> some View {
        let color = Color.memberColor(for: member.id)
        HStack(spacing: 10) {
            AvatarView(data: member.avatarData,
                       name: member.displayName,
                       size: 26,
                       tint: color)
            Text(member.displayName)
                .textCase(nil)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func receiptRow(label: String,
                            date: Date?,
                            systemImage: String,
                            tint: Color) -> some View {
        HStack(spacing: 10) {
            // Double-check icon to mirror the chat bubble indicator.
            HStack(spacing: -4) {
                Image(systemName: systemImage)
                Image(systemName: systemImage)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(date != nil ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
            .frame(width: 22)

            Text(label)
                .font(.body)
            Spacer()
            if let date {
                Text(formatted(date))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func timestampRow(label: String,
                              date: Date?,
                              systemImage: String,
                              subtitle: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let date {
                Text(formatted(date))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: date)
    }
}

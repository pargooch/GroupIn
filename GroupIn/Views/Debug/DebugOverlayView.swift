//
//  DebugOverlayView.swift
//  GroupIn
//
//  Dev-only diagnostic sheet. Visible from the Home view via a small
//  ⚙︎ button in `#if DEBUG` builds only. Renders the snapshot
//  exposed by `AppState.debugSnapshot` — retry queues, BLE health,
//  peer cursors, last events — so "is something stuck?" becomes a
//  glanceable question.
//
//  The whole file is `#if DEBUG`-gated so it doesn't ship in App
//  Store builds.
//

#if DEBUG
import SwiftUI

struct DebugOverlayView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let snapshot = appState.debugSnapshot
        NavigationStack {
            List {
                identitySection(snapshot)
                queuesSection(snapshot)
                bleSection(snapshot.bleDiagnostics)
                if let _ = snapshot.activeGroupID {
                    activeGroupSection(snapshot)
                    peerCursorsSection(snapshot)
                    recentEventsSection(snapshot)
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private func identitySection(_ snapshot: DebugSnapshot) -> some View {
        Section("Identity") {
            row("Local ID", value: snapshot.localIdentity.map { abbreviate($0) } ?? "—")
            row("Online", value: snapshot.isOnline ? "yes" : "no")
            row("iCloud", value: iCloudLabel(snapshot.iCloudStatus))
        }
    }

    private func queuesSection(_ snapshot: DebugSnapshot) -> some View {
        Section("Retry queues") {
            row("Pending emits", value: "\(snapshot.pendingEmitsCount)")
            row("Pending member publishes", value: "\(snapshot.pendingMemberPublishesCount)")
            row("Pending group saves", value: "\(snapshot.pendingGroupSavesCount)")
            if let oldest = snapshot.oldestPendingEmitAt {
                row("Oldest emit age", value: ageString(oldest))
            }
        }
    }

    private func bleSection(_ diag: BLEDiagnostics) -> some View {
        Section("BLE") {
            row("Bluetooth ready", value: diag.bluetoothReady ? "yes" : "no")
            row("Chat subscribers", value: "\(diag.chatSubscribers)")
            row("Presence subscribers", value: "\(diag.presenceSubscribers)")
            if diag.serviceAddFailed {
                row("Service add", value: "failed")
                    .foregroundStyle(.red)
            }
        }
    }

    private func activeGroupSection(_ snapshot: DebugSnapshot) -> some View {
        Section("Active group") {
            row("Name", value: snapshot.activeGroupName ?? "—")
            row("Members", value: "\(snapshot.activeGroupMemberCount)")
            row("Events in log", value: "\(snapshot.activeGroupEventCount)")
            if let cursor = snapshot.myCursor {
                row("My cursor", value: shortCursor(cursor))
            }
        }
    }

    private func peerCursorsSection(_ snapshot: DebugSnapshot) -> some View {
        Section("Peer cursors") {
            if snapshot.peerCursors.isEmpty {
                Text("No peers tracked")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.peerCursors) { peer in
                    HStack {
                        Text(peer.displayName ?? abbreviate(peer.memberID.uuidString))
                            .font(.callout)
                        Spacer()
                        if let behind = peer.behindByEvents {
                            Text(behind == 0 ? "✓ caught up" : "\(behind) behind")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(behind == 0 ? .green : .orange)
                        } else {
                            Text(shortCursor(peer.cursor))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func recentEventsSection(_ snapshot: DebugSnapshot) -> some View {
        Section("Last events") {
            if snapshot.recentEvents.isEmpty {
                Text("Empty log").foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.recentEvents) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.payload.typeIdentifier)
                            .font(.callout.monospaced())
                        Text(event.createdAt.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced())
        }
    }

    private func abbreviate(_ s: String) -> String {
        s.count <= 12 ? s : String(s.prefix(8)) + "…"
    }

    private func iCloudLabel(_ status: ICloudAccountStatus) -> String {
        switch status {
        case .available:              return "available"
        case .noAccount:              return "no account"
        case .restricted:             return "restricted"
        case .couldNotDetermine:      return "unknown"
        case .temporarilyUnavailable: return "temp unavailable"
        }
    }

    private func shortCursor(_ cursor: EventCursor) -> String {
        let time = cursor.createdAt.formatted(date: .omitted, time: .standard)
        return "\(time) #\(cursor.id.uuidString.prefix(6))"
    }

    private func ageString(_ at: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(at)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }
}
#endif

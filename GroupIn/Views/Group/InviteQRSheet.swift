//
//  InviteQRSheet.swift
//  GroupIn
//
//  Big-screen invite QR + copyable code. Shown from the dashboard so
//  the group owner can hold their phone up and friends scan it from
//  across a table — no typing, no contact exchange.
//

import SwiftUI

struct InviteQRSheet: View {
    let groupName: String
    let inviteCode: String

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Text(groupName)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                qrImage
                    .padding(.horizontal, 32)

                VStack(spacing: 8) {
                    Text("Invite code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        copy()
                    } label: {
                        HStack(spacing: 10) {
                            Text(inviteCode)
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                                .foregroundStyle(didCopy ? Color.green : Color.accentColor)
                        }
                        .padding(.horizontal, 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Invite code \(inviteCode), tap to copy")
                }

                // System share sheet — the "from anywhere" path
                // (Messages, AirDrop, copy link). The QR above stays
                // the in-person path; both now live behind this one
                // sheet instead of two separate dashboard controls.
                ShareLink(item: shareMessage) {
                    Label("Share invite…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.neon)
                .padding(.horizontal, 32)
                .accessibilityHint("Opens the share sheet to send the invite code via Messages, AirDrop, or other apps")

                Text("Scan the code in person, or tap Share to invite from anywhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var qrImage: some View {
        if let image = QRCodeGenerator.makeImage(from: inviteCode) {
            Image(uiImage: image)
                .interpolation(.none)            // keep squares crisp
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 320, maxHeight: 320)
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
                .accessibilityLabel("QR code containing invite \(inviteCode)")
        } else {
            // Should never happen with the codes our generator produces,
            // but degrade gracefully so the sheet still functions as a
            // big-text code display.
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.gray.opacity(0.15))
                .frame(maxWidth: 320, maxHeight: 320)
                .overlay(
                    Text("QR unavailable")
                        .foregroundStyle(.secondary)
                )
        }
    }

    /// Human-readable invite text for the system share sheet. We have
    /// no universal-link scheme yet, so the recipient enters the code
    /// manually in Join — the same string the QR encodes and the
    /// manual field accepts, so every path lands on identical
    /// validation.
    private var shareMessage: String {
        "Join my GroupIn group \"\(groupName)\" — open GroupIn and enter invite code \(inviteCode)"
    }

    private func copy() {
        UIPasteboard.general.string = inviteCode
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
}

#Preview {
    InviteQRSheet(groupName: "Coachella", inviteCode: "ABC234")
}

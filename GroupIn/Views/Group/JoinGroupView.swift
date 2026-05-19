//
//  JoinGroupView.swift
//  GroupIn
//
//  Fully-offline, nearby-only join screen. Uses a plain VStack rather
//  than Form — the previous Form-with-conditional-sections version hit
//  a UICollectionView assertion ("invalid number of items in section
//  N") whenever the QR-scan callback fired multiple state updates in
//  the same render pass. Plain SwiftUI containers (VStack, ScrollView)
//  are not collection-view-backed, so they can't trip that bug class.
//
//  UX:
//   • Manual entry — type the 6-char invite code, tap Join.
//   • QR scan — fills the field and shows it. User taps Join to
//     confirm. We deliberately don't auto-submit on scan so the
//     scan→state→join chain isn't all happening in one frame, and so
//     a misread QR doesn't immediately try to join a wrong group.
//   • While joining — shows a single-row status with a Cancel button.
//     Cancel terminates the BLE discovery task and returns to the
//     editable form.
//

import SwiftUI

struct JoinGroupView: View {
    @State private var viewModel: JoinGroupViewModel
    @State private var showsScanner = false
    @State private var pendingScannedCode: String?
    @FocusState private var inviteCodeFocused: Bool

    init(viewModel: JoinGroupViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                inviteCodeField($viewModel.inviteCode)
                scanQRButton
                if let message = viewModel.errorMessage {
                    errorRow(message)
                }
                statusOrJoin
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Join Group")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsScanner, onDismiss: applyPendingScan) {
            QRScannerView { scanned in
                // Stash the scanned text and let the sheet dismiss
                // itself — `onDismiss` will publish the state change
                // *after* the dismissal animation completes. Mutating
                // viewModel state inside this callback fires three
                // published changes in the same tick as the sheet's
                // own transition, which is the exact pattern that was
                // triggering the SwiftUI List-diff crash on the
                // underlying view. By the time `applyPendingScan`
                // runs the sheet is fully gone and the parent view
                // tree is settled.
                pendingScannedCode = scanned
            }
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    /// Apply the scanned QR code AFTER the scanner sheet has fully
    /// dismissed (via `.sheet`'s `onDismiss` callback). Mutating
    /// view-model state inside the scan callback fires published
    /// changes during the sheet transition, which we've seen
    /// repeatedly trigger SwiftUI's UICollectionView "invalid
    /// number of items in section N" assertion on whichever view
    /// is mounted nearby. Deferring to onDismiss puts the state
    /// changes safely outside the transition window.
    private func applyPendingScan() {
        guard let scanned = pendingScannedCode else { return }
        pendingScannedCode = nil
        viewModel.inviteCode = scanned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        viewModel.errorMessage = nil
        inviteCodeFocused = false
    }

    // MARK: - Sections

    @ViewBuilder
    private func inviteCodeField(_ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invite code")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
            TextField("ABC234", text: binding)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($inviteCodeFocused)
                .disabled(viewModel.isSubmitting)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
                .onSubmit { Task { await viewModel.joinGroup() } }
                .accessibilityLabel("Invite code")
        }
    }

    private var scanQRButton: some View {
        Button {
            showsScanner = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.body.weight(.semibold))
                Text("Scan QR code")
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the camera to scan a group's invite QR code")
        .disabled(viewModel.isSubmitting)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }

    @ViewBuilder
    private var statusOrJoin: some View {
        if viewModel.isSubmitting {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(viewModel.statusMessage ?? "Looking for nearby host…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
                .accessibilityElement(children: .combine)

                Button(role: .cancel) {
                    viewModel.cancel()
                } label: {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                        )
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                Task { await viewModel.joinGroup() }
            } label: {
                Text("Join Group")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(viewModel.canSubmit
                                  ? Color.accentColor
                                  : Color.gray.opacity(0.3))
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
        }
    }
}

#Preview {
    NavigationStack {
        JoinGroupView(viewModel: JoinGroupViewModel(appState: AppState()))
    }
    .environment(AppState())
}

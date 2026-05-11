//
//  JoinGroupView.swift
//  GroupIn
//

import SwiftUI

struct JoinGroupView: View {
    @State private var viewModel: JoinGroupViewModel
    @State private var showsScanner = false

    init(viewModel: JoinGroupViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        Form {
            Section("Invite code") {
                TextField("e.g. ABC234", text: $viewModel.inviteCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await viewModel.joinGroup() } }
                    .accessibilityLabel("Invite code")
            }

            Section {
                Button {
                    showsScanner = true
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityHint("Opens the camera to scan a group's invite QR code")
            }

            if let message = viewModel.errorMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(message)")
                }
            } else if let status = viewModel.statusMessage {
                // Silent-retry indicator. We're cycling on a transient
                // error (network blip, CloudKit hiccup) and don't want
                // to scare the user with raw error text. The hint is
                // honest about what's happening and lets them know they
                // can wait or cancel out.
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section {
                Button {
                    Task { await viewModel.joinGroup() }
                } label: {
                    HStack {
                        if viewModel.isSubmitting {
                            ProgressView()
                        }
                        Text(viewModel.isSubmitting && viewModel.statusMessage != nil
                             ? "Connecting…"
                             : "Join Group")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!viewModel.canSubmit)
            }
        }
        .navigationTitle("Join Group")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsScanner) {
            QRScannerView { scanned in
                // Reuse the manual-entry path: drop the scanned text into
                // the same field (so the user can confirm/edit if it
                // came in malformed) and immediately try to join.
                viewModel.inviteCode = scanned
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                Task { await viewModel.joinGroup() }
            }
        }
    }
}

#Preview {
    NavigationStack {
        JoinGroupView(viewModel: JoinGroupViewModel(appState: AppState()))
    }
    .environment(AppState())
}

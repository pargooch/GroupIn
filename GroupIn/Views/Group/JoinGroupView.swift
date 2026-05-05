//
//  JoinGroupView.swift
//  GroupIn
//

import SwiftUI

struct JoinGroupView: View {
    @State private var viewModel: JoinGroupViewModel

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

            if let message = viewModel.errorMessage {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(message)")
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
                        Text("Join Group")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!viewModel.canSubmit)
            }
        }
        .navigationTitle("Join Group")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        JoinGroupView(viewModel: JoinGroupViewModel(appState: AppState()))
    }
    .environment(AppState())
}

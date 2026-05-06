//
//  CreateGroupView.swift
//  GroupIn
//

import SwiftUI

struct CreateGroupView: View {
    @State private var viewModel: CreateGroupViewModel

    init(viewModel: CreateGroupViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        Form {
            Section("Group name") {
                TextField("e.g. Weekend Hike", text: $viewModel.groupName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.go)
                    .onSubmit { Task { await viewModel.createGroup() } }
                    .accessibilityLabel("Group name")
            }

            Section {
                Picker("Duration", selection: $viewModel.duration) {
                    ForEach(GroupDuration.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(viewModel.useCustomDate)

                Toggle("Custom expiry", isOn: $viewModel.useCustomDate)

                if viewModel.useCustomDate {
                    DatePicker(
                        "Expires at",
                        selection: $viewModel.customExpiresAt,
                        in: .now...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            } header: {
                Text("Expires")
            } footer: {
                Text("The group hard-deletes when it expires. As owner, you'll be prompted 30 minutes before to extend it.")
                    .font(.caption)
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
                    Task { await viewModel.createGroup() }
                } label: {
                    HStack {
                        if viewModel.isSubmitting {
                            ProgressView()
                        }
                        Text("Create Group")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!viewModel.canSubmit)
            }
        }
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        CreateGroupView(viewModel: CreateGroupViewModel(appState: AppState()))
    }
    .environment(AppState())
}

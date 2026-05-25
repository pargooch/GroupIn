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
            Section {
                categoryMenu
            } header: {
                Text("Type")
            } footer: {
                Text(viewModel.category.subtitle)
                    .font(.caption)
            }

            Section("Group name") {
                TextField(namePlaceholder, text: $viewModel.groupName)
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
                    HStack(spacing: 8) {
                        if viewModel.isSubmitting {
                            ProgressView()
                        }
                        Text("Create Group")
                    }
                }
                .buttonStyle(.neon)
                .disabled(!viewModel.canSubmit)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            }
        }
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var categoryMenu: some View {
        Menu {
            // Native iOS dropdown — each row gets the category's SF
            // Symbol on the leading edge, the user's current pick is
            // marked with a checkmark by SwiftUI automatically when we
            // bind through Picker.
            Picker(selection: $viewModel.category) {
                ForEach(GroupCategory.allCases) { cat in
                    Label(cat.label, systemImage: cat.systemImage)
                        .tag(cat)
                }
            } label: {
                EmptyView()
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(viewModel.category.tint.opacity(0.18))
                    Image(systemName: viewModel.category.systemImage)
                        .foregroundStyle(viewModel.category.tint)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

                // Text uses the same category tint as the icon so the row
                // reads as a single colored unit instead of "colored icon
                // + black text" mismatch.
                Text(viewModel.category.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(viewModel.category.tint)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.category.tint.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Type: \(viewModel.category.label)")
        .accessibilityHint("Tap to choose a different group type")
    }

    /// Suggest a placeholder name based on the picked category.
    private var namePlaceholder: String {
        switch viewModel.category {
        case .festival:  return "e.g. Coachella Crew"
        case .trip:      return "e.g. Italy Trip"
        case .tour:      return "e.g. Vatican Tour"
        case .exploring: return "e.g. Tokyo Walk"
        case .nature:    return "e.g. Yosemite Hike"
        case .other:     return "e.g. Saturday"
        }
    }
}

#Preview {
    NavigationStack {
        CreateGroupView(viewModel: CreateGroupViewModel(appState: AppState()))
    }
    .environment(AppState())
}

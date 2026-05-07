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
                categoryPicker
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
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

    @ViewBuilder
    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(GroupCategory.allCases) { cat in
                    categoryChip(cat)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func categoryChip(_ cat: GroupCategory) -> some View {
        let isSelected = viewModel.category == cat
        Button {
            viewModel.category = cat
        } label: {
            VStack(spacing: 6) {
                Image(systemName: cat.systemImage)
                    .font(.title2)
                    .foregroundStyle(cat.tint)
                Text(cat.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 84, height: 84)
            .background(
                cat.tint.opacity(isSelected ? 0.22 : 0.10),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? cat.tint : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cat.label), \(cat.subtitle)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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

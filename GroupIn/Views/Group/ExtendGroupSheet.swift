//
//  ExtendGroupSheet.swift
//  GroupIn
//
//  Owner picks a new expiry. Members will need to re-accept to stay.
//

import SwiftUI

struct ExtendGroupSheet: View {
    let currentExpiresAt: Date
    let onConfirm: (Date) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selection: ExtensionAmount = .oneHour
    @State private var customDate: Date = .now.addingTimeInterval(60 * 60)
    @State private var useCustom: Bool = false
    @State private var isSubmitting: Bool = false

    enum ExtensionAmount: Hashable, Identifiable, CaseIterable {
        case thirtyMinutes
        case oneHour
        case fourHours
        case oneDay

        var id: TimeInterval { seconds }
        var seconds: TimeInterval {
            switch self {
            case .thirtyMinutes: return 60 * 30
            case .oneHour:       return 60 * 60
            case .fourHours:     return 60 * 60 * 4
            case .oneDay:        return 60 * 60 * 24
            }
        }
        var label: String {
            switch self {
            case .thirtyMinutes: return "+30 min"
            case .oneHour:       return "+1 hour"
            case .fourHours:     return "+4 hours"
            case .oneDay:        return "+1 day"
            }
        }
    }

    var newExpiresAt: Date {
        useCustom ? customDate : currentExpiresAt.addingTimeInterval(selection.seconds)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current expiry") {
                    Text(currentExpiresAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Add", selection: $selection) {
                        ForEach(ExtensionAmount.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .disabled(useCustom)

                    Toggle("Custom date", isOn: $useCustom)

                    if useCustom {
                        DatePicker(
                            "New expiry",
                            selection: $customDate,
                            in: .now...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                } header: {
                    Text("Extension")
                } footer: {
                    Text("Members will need to accept to stay in the group. Anyone who doesn't accept by the original expiry will be removed.")
                        .font(.caption)
                }

                Section("New expiry") {
                    Text(newExpiresAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(newExpiresAt > currentExpiresAt ? Color.primary : Color.red)
                }
            }
            .navigationTitle("Extend Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Extend") {
                        let target = newExpiresAt
                        isSubmitting = true
                        Task {
                            await onConfirm(target)
                            isSubmitting = false
                            dismiss()
                        }
                    }
                    .disabled(isSubmitting || newExpiresAt <= currentExpiresAt)
                }
            }
            .overlay {
                if isSubmitting { ProgressView() }
            }
        }
    }
}

#Preview {
    ExtendGroupSheet(currentExpiresAt: .now.addingTimeInterval(3600)) { _ in }
}

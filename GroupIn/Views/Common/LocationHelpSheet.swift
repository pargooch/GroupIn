//
//  LocationHelpSheet.swift
//  GroupIn
//
//  Plain-language explanation of why GPS might be unavailable, with a
//  shortcut into iOS Settings. Shown when the dashboard's freshness
//  indicator is in the slow / stalled state.
//

import SwiftUI
import UIKit

struct LocationHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("Why your location may be unavailable")
                            .font(.headline)
                    } icon: {
                        Image(systemName: "location.slash")
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Common causes") {
                    bullet(
                        icon: "wifi.slash",
                        title: "No Wi-Fi or cellular signal",
                        body: "Indoors, your phone uses Wi-Fi and cell towers to find your position. Without them, GPS alone often can't reach you through walls."
                    )
                    bullet(
                        icon: "building.2",
                        title: "Deep inside a building",
                        body: "GPS signals come from satellites in space. Concrete, metal, and basements block them."
                    )
                    bullet(
                        icon: "airplane",
                        title: "Airplane mode is on",
                        body: "Turning everything off cuts location assistance, even when GPS itself is allowed."
                    )
                }

                Section("How to fix it") {
                    bullet(
                        icon: "sun.max",
                        title: "Move toward open sky",
                        body: "Even a window helps. Outdoors with a clear view of the sky is best."
                    )
                    bullet(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Turn on Wi-Fi or cellular",
                        body: "You don't need internet — just having Wi-Fi or cellular powered on gives your phone reference points to find itself."
                    )
                    bullet(
                        icon: "location.fill",
                        title: "Check Precise Location is on",
                        body: "In Settings → Privacy & Security → Location → GroupIn, make sure Precise Location is enabled."
                    )
                }

                Section {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link(destination: url) {
                            Label("Open Location Settings", systemImage: "gear")
                        }
                    }
                }
            }
            .navigationTitle("Location Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func bullet(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    LocationHelpSheet()
}

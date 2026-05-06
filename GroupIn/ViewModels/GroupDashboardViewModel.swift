//
//  GroupDashboardViewModel.swift
//  GroupIn
//
//  Owns map camera state and bridges extension/accept actions to AppState.
//  Group / member / coordinate data is read directly from AppState —
//  @Observable transitively tracks reads through the VM.
//

import Foundation
import SwiftUI
import MapKit
import Observation

@MainActor
@Observable
final class GroupDashboardViewModel {
    var cameraPosition: MapCameraPosition = .automatic
    var showExtendSheet: Bool = false
    var actionError: String?
    private var hasCenteredOnUser = false

    let appState: AppState
    let groupID: UUID

    init(appState: AppState, groupID: UUID) {
        self.appState = appState
        self.groupID = groupID
    }

    var group: GroupSession? {
        guard let active = appState.currentGroup, active.id == groupID else {
            return appState.myGroups.first(where: { $0.id == groupID })
        }
        return active
    }

    var currentUser: User { appState.currentUser }

    var isOwner: Bool {
        group?.ownerID == currentUser.id
    }

    /// True when there's a pending extension AND I'm not the owner AND I haven't accepted yet.
    var canAcceptExtension: Bool {
        guard let group, !isOwner else { return false }
        return group.pendingExtension != nil
            && !group.hasAcceptedExtension(currentUser.id)
    }

    /// True when expiry is within 30 minutes and I'm the owner and there's no pending extension yet.
    var shouldPromptOwnerToExtend: Bool {
        guard let group, isOwner, group.pendingExtension == nil else { return false }
        return group.expiresAt.timeIntervalSinceNow <= 30 * 60
    }

    func start() {
        appState.startLocationTracking()
    }

    func stop() {
        appState.stopLocationTracking()
    }

    func centerCameraIfNeeded(_ coordinate: Coordinate) {
        guard !hasCenteredOnUser else { return }
        hasCenteredOnUser = true
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate.clLocation,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
    }

    func proposeExtension(newExpiresAt: Date) async {
        do {
            try await appState.proposeCurrentExtension(newExpiresAt: newExpiresAt)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func acceptExtension() async {
        do {
            try await appState.acceptCurrentExtension()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

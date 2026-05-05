//
//  GroupDashboardViewModel.swift
//  GroupIn
//
//  Owns map camera state for the dashboard. Group / member / coordinate
//  data is read directly from AppState — @Observable transitively tracks
//  reads through the VM, so changes propagate without manual wiring.
//

import Foundation
import SwiftUI
import MapKit
import Observation

@MainActor
@Observable
final class GroupDashboardViewModel {
    var cameraPosition: MapCameraPosition = .automatic
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

    var membersWithCoordinates: [User] {
        (group?.members ?? []).filter { $0.coordinate != nil }
    }

    func start() {
        appState.startLocationTracking()
    }

    func stop() {
        appState.stopLocationTracking()
    }

    /// Centers the camera on the first real fix we receive.
    /// Subsequent updates leave the camera alone so the user can pan freely.
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
}

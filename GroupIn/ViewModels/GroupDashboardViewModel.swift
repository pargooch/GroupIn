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
    var cameraPosition: MapCameraPosition
    var showExtendSheet: Bool = false
    var actionError: String?
    /// Member whose map pin is currently emphasized. Cleared after a few seconds.
    var focusedMemberID: UUID?
    private var hasFitInitialMap = false
    private var focusClearTask: Task<Void, Never>?

    let appState: AppState
    let groupID: UUID

    init(appState: AppState, groupID: UUID) {
        self.appState = appState
        self.groupID = groupID
        self.cameraPosition = Self.initialCamera(appState: appState, groupID: groupID)
    }

    /// Seed the map at the most plausible nearby point so we don't flash a
    /// world view (default `.automatic` falls back to 0,0 — the middle of
    /// the Atlantic). Order of preference:
    ///  1. The local user's last-known coordinate.
    ///  2. Any cached group member's coordinate.
    ///  3. iOS's current user location, falling back to automatic.
    private static func initialCamera(appState: AppState,
                                      groupID: UUID) -> MapCameraPosition {
        let span = MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)

        if let coord = appState.currentUser.coordinate {
            return .region(MKCoordinateRegion(center: coord.clLocation, span: span))
        }

        let cached = appState.currentGroup?.id == groupID
            ? appState.currentGroup
            : appState.myGroups.first(where: { $0.id == groupID })
        if let coord = cached?.members.compactMap(\.coordinate).first {
            return .region(MKCoordinateRegion(center: coord.clLocation, span: span))
        }

        return .userLocation(fallback: .automatic)
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
        appState.startGroupRefresh()
        appState.startBLEPresence()
    }

    func stop() {
        appState.stopGroupRefresh()
    }

    /// First time we have any member coordinates, frame all of them.
    func fitInitialIfNeeded() {
        guard !hasFitInitialMap else { return }
        guard let group = group else { return }
        let coords = group.members.compactMap { $0.coordinate }
        guard !coords.isEmpty else { return }
        hasFitInitialMap = true
        fitAllMembers()
    }

    /// Frame the camera so every member with a coordinate is visible.
    /// Called by the "Fit all" button and on first appearance.
    func fitAllMembers() {
        guard let group = group else { return }
        let coords = group.members.compactMap { $0.coordinate?.clLocation }
        guard !coords.isEmpty else { return }

        if coords.count == 1 {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coords[0],
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            )
            return
        }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (lats.max()! - lats.min()!) * 1.6),
            longitudeDelta: max(0.005, (lons.max()! - lons.min()!) * 1.6)
        )
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }

    /// Tapping a member row centers the map on them and emphasizes their
    /// pin briefly. No-op if the member has no coordinate yet.
    func focus(on member: User) {
        guard let coord = member.coordinate else { return }
        focusedMemberID = member.id
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coord.clLocation,
                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            )
        )
        focusClearTask?.cancel()
        focusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.focusedMemberID = nil
        }
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

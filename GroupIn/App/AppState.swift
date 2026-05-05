//
//  AppState.swift
//  GroupIn
//
//  Global app state shared across views via the SwiftUI environment.
//  Persists active session, user identity, and the user's group list
//  to UserDefaults so the app reopens where the user left off.
//

import Foundation
import Observation

enum AppRoute: Hashable {
    case createGroup
    case joinGroup
    case groupDashboard(groupID: UUID)
}

@MainActor
@Observable
final class AppState {
    var currentUser: User {
        didSet { Self.persistUser(currentUser, defaults: defaults) }
    }
    var currentGroup: GroupSession? {
        didSet { persistCurrentGroup() }
    }
    var myGroups: [GroupSession] = [] {
        didSet { persistMyGroups() }
    }
    var path: [AppRoute] = []

    let groupService: CloudKitServicing
    let locationService: LocationServicing

    private let defaults: UserDefaults
    private var locationTask: Task<Void, Never>?

    private static let userIDKey = "GroupIn.AppState.userID"
    private static let userNameKey = "GroupIn.AppState.userName"
    private static let currentGroupKey = "GroupIn.AppState.currentGroup"
    private static let myGroupsKey = "GroupIn.AppState.myGroups"

    var isInGroup: Bool { currentGroup != nil }

    init(currentUser: User? = nil,
         groupService: CloudKitServicing? = nil,
         locationService: LocationServicing? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.currentUser = currentUser ?? Self.loadUser(defaults: defaults)
        self.groupService = groupService ?? LocalGroupService(defaults: defaults)
        self.locationService = locationService ?? LocationService()

        if let data = defaults.data(forKey: Self.myGroupsKey),
           let decoded = try? JSONDecoder().decode([GroupSession].self, from: data) {
            self.myGroups = decoded
        }

        if let data = defaults.data(forKey: Self.currentGroupKey),
           let restored = try? JSONDecoder().decode(GroupSession.self, from: data) {
            self.currentGroup = restored
            self.path = [.groupDashboard(groupID: restored.id)]
        }
    }

    // MARK: - Group management

    func addOrUpdate(group: GroupSession) {
        if let idx = myGroups.firstIndex(where: { $0.id == group.id }) {
            myGroups[idx] = group
        } else {
            myGroups.append(group)
        }
    }

    func remove(group: GroupSession) {
        myGroups.removeAll { $0.id == group.id }
        if currentGroup?.id == group.id {
            currentGroup = nil
        }
    }

    func open(group: GroupSession) {
        addOrUpdate(group: group)
        currentGroup = group
        let route = AppRoute.groupDashboard(groupID: group.id)
        if path.last != route {
            path.append(route)
        }
    }

    func leaveGroup() {
        currentGroup = nil
        path.removeAll()
    }

    // MARK: - Location lifecycle
    //
    // The consuming Task is created lazily and lives for the rest of the
    // app's lifetime. Stopping just halts CLLocationManager updates — the
    // AsyncStream stays open so we can resume cleanly.

    func startLocationTracking() {
        locationService.requestAuthorization()
        locationService.startUpdating()

        guard locationTask == nil else { return }
        locationTask = Task { [weak self] in
            guard let self else { return }
            for await coordinate in self.locationService.locationUpdates {
                self.currentUser.coordinate = coordinate
                if var group = self.currentGroup,
                   let idx = group.members.firstIndex(where: { $0.id == self.currentUser.id }) {
                    group.members[idx].coordinate = coordinate
                    group.members[idx].lastSeen = .now
                    self.currentGroup = group
                    self.addOrUpdate(group: group)
                }
            }
        }
    }

    func stopLocationTracking() {
        locationService.stopUpdating()
    }

    // MARK: - Persistence

    private func persistCurrentGroup() {
        if let group = currentGroup,
           let data = try? JSONEncoder().encode(group) {
            defaults.set(data, forKey: Self.currentGroupKey)
        } else {
            defaults.removeObject(forKey: Self.currentGroupKey)
        }
    }

    private func persistMyGroups() {
        if let data = try? JSONEncoder().encode(myGroups) {
            defaults.set(data, forKey: Self.myGroupsKey)
        }
    }

    private static func loadUser(defaults: UserDefaults) -> User {
        let id = defaults.string(forKey: userIDKey)
            .flatMap(UUID.init(uuidString:)) ?? UUID()
        let name = defaults.string(forKey: userNameKey) ?? "Me"
        let user = User(id: id, displayName: name)
        persistUser(user, defaults: defaults)
        return user
    }

    private static func persistUser(_ user: User, defaults: UserDefaults) {
        defaults.set(user.id.uuidString, forKey: userIDKey)
        defaults.set(user.displayName, forKey: userNameKey)
    }
}

//
//  CloudKitService.swift
//  GroupIn
//
//  Protocol stub — concrete CloudKit implementation arrives in a later step.
//

import Foundation

protocol CloudKitServicing {
    func createGroup(named name: String) async throws -> GroupSession
    func joinGroup(inviteCode: String) async throws -> GroupSession
    func publish(user: User, in group: GroupSession) async throws
}

final class CloudKitService: CloudKitServicing {
    func createGroup(named name: String) async throws -> GroupSession {
        fatalError("Not implemented yet")
    }

    func joinGroup(inviteCode: String) async throws -> GroupSession {
        fatalError("Not implemented yet")
    }

    func publish(user: User, in group: GroupSession) async throws {
        fatalError("Not implemented yet")
    }
}

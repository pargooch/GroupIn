//
//  GroupSession.swift
//  GroupIn
//

import Foundation

struct GroupSession: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var inviteCode: String
    var createdAt: Date
    var members: [User]

    init(id: UUID = UUID(),
         name: String,
         inviteCode: String,
         createdAt: Date = .now,
         members: [User] = []) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode
        self.createdAt = createdAt
        self.members = members
    }
}

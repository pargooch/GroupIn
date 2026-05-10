//
//  ChatMessage.swift
//  GroupIn
//
//  Short text exchanged between in-range BLE peers via GATT. Ephemeral
//  by design — no CloudKit persistence, no message history. The format
//  is JSON-encoded and lives in a notify-able characteristic; the
//  receiving device gets a fresh value each time anyone in their group
//  sends. We keep messages small (~240 char text limit) to fit
//  comfortably inside a BLE characteristic write.
//

import Foundation

struct ChatMessage: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let groupHash: UInt32
    let senderID: UUID
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(),
         groupHash: UInt32,
         senderID: UUID,
         text: String,
         timestamp: Date = .now) {
        self.id = id
        self.groupHash = groupHash
        self.senderID = senderID
        self.text = text
        self.timestamp = timestamp
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) -> ChatMessage? {
        try? JSONDecoder().decode(ChatMessage.self, from: data)
    }
}

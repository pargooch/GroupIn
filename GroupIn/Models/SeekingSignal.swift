//
//  SeekingSignal.swift
//  GroupIn
//
//  Wire format the seeker writes to a sought peer's GATT to say "I'm
//  actively trying to find you right now." The sought side uses this
//  to ramp its BLE presence broadcast cadence — from the default
//  GPS-fix-driven schedule up to ~10 Hz for ten seconds, then 2 Hz
//  for another twenty, then back to baseline. The faster cadence
//  gives the seeker's compass smooth, near-realtime tracking of the
//  peer's location without keeping every member broadcasting at 10 Hz
//  forever (which would crush battery).
//
//  The signal has an explicit `expiresAt` rather than a one-shot
//  flag: a clean disconnect can drop a "stop seeking" packet on the
//  floor, but `expiresAt` self-heals after a few seconds without a
//  fresh write. Seekers refresh the signal on a timer while the
//  compass is open.
//

import Foundation

struct SeekingSignal: Codable, Hashable, Sendable {
    /// Per-group membership ID of the seeker, so the sought side can
    /// log who's looking (and the responder-side UI can show "X is
    /// looking for you" without leaking other identity bits).
    let requesterMemberID: UUID
    /// Wall-clock time after which this signal is no longer
    /// considered active. The sought side compares against its own
    /// clock and ignores stale signals — so a packet that arrives
    /// late, or a Bluetooth flake that delays delivery for many
    /// seconds, doesn't keep the cadence ramp running.
    let expiresAt: Date

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) -> SeekingSignal? {
        try? JSONDecoder().decode(SeekingSignal.self, from: data)
    }
}

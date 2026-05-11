//
//  PendingEmit.swift
//  GroupIn
//
//  An event that failed to land on CloudKit on first attempt and is
//  waiting for retry. Persisted to UserDefaults so a kill-and-relaunch
//  doesn't drop unflushed events — the queue rehydrates on launch and
//  retry resumes.
//
//  Backoff schedule (cap 60s) means a transient network blip resolves
//  fast and a longer outage doesn't hammer the radio:
//
//    retry 1 → 5s
//    retry 2 → 10s
//    retry 3 → 20s
//    retry 4 → 40s
//    retry 5+ → 60s
//
//  We never give up. CloudKit will eventually accept the write; until
//  it does, the corresponding chat bubble stays at the ⏰ pending
//  indicator so the user knows the message hasn't made it out yet.
//

import Foundation

struct PendingEmit: Codable, Hashable, Sendable {
    let event: Event
    var retryCount: Int
    var nextRetryAt: Date

    /// Exponential backoff schedule with a 60-second ceiling.
    /// retry 1 → 5s, 2 → 10s, 3 → 20s, 4 → 40s, 5+ → 60s.
    static func backoff(after retryCount: Int) -> TimeInterval {
        let raw = 5.0 * pow(2.0, Double(retryCount))
        return min(60.0, raw)
    }

    /// Returns a copy with `retryCount` bumped and `nextRetryAt`
    /// advanced by the corresponding backoff. Used when a retry
    /// attempt fails — caller writes the new value back into the
    /// persisted queue.
    func bumpedRetry(now: Date = .now) -> PendingEmit {
        let next = retryCount + 1
        return PendingEmit(
            event: event,
            retryCount: next,
            nextRetryAt: now.addingTimeInterval(Self.backoff(after: next))
        )
    }
}

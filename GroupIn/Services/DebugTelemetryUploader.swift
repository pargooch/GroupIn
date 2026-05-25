//
//  DebugTelemetryUploader.swift
//  GroupIn
//
//  DEBUG-ONLY. Streams the indoor-compass debug telemetry off the device
//  to a collector running on a Mac on the same LAN, so the whole signal
//  pipeline (RSSI flow, position spread, gradient status, heading
//  reliability, EKF estimate, per-channel temperature) can be diagnosed
//  live across two phones instead of read off a screen one value at a
//  time.
//
//  The ENTIRE file is wrapped in `#if DEBUG`, so it is compiled out of
//  release / App Store builds — no uploader, no networking, nothing.
//  Reaching a LAN IP also trips iOS 14+ Local Network privacy, which is
//  why debug builds carry `NSLocalNetworkUsageDescription` +
//  `NSAllowsLocalNetworking`; the user grants a one-time prompt per
//  device. Fire-and-forget: every failure is swallowed, nothing blocks
//  the main actor, nothing retries.
//

#if DEBUG
import Foundation
import UIKit

final class DebugTelemetryUploader {

    /// Set to the Mac collector's LAN IP. When nil/empty the uploader is
    /// inert (no-ops), so leaving it unset is safe.
    static let host: String? = "192.168.1.2"
    static let port: Int = 8899

    private let endpoint: URL?
    private let session: URLSession
    /// Stable per-launch device label so the collector can split phones
    /// into separate logs.
    let deviceName: String

    init() {
        if let host = Self.host, !host.isEmpty {
            self.endpoint = URL(string: "http://\(host):\(Self.port)/t")
        } else {
            self.endpoint = nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.deviceName = UIDevice.current.name
    }

    var isActive: Bool { endpoint != nil }

    /// POST one JSON snapshot. Non-finite doubles must already be
    /// sanitized by the caller (JSONSerialization throws on NaN/Inf).
    func send(_ payload: [String: Any]) {
        guard let endpoint,
              JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req).resume()
    }
}
#endif

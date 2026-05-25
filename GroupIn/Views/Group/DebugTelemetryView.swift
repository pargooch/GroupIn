//
//  DebugTelemetryView.swift
//  GroupIn
//
//  Full read-out of every indoor / GPS / motion signal we can measure,
//  shown when the compass seeker-mode picker is set to "Debug". Refreshes
//  at 2 Hz via a TimelineView so live values tick without driving the
//  rest of the compass at frame rate.
//
//  Sections:
//    • Channels — UWB / Wi-Fi Aware / BLE, all engaged concurrently,
//      each with its own temperature (RSSI), distance, direction flag,
//      sample count, and freshness.
//    • Motion — CLHeading, attitude heading + reliability, PCA motion-
//      heading + confidence, gyro (rotationRate), userAcceleration,
//      gravity, activity classification.
//    • Steps — live session steps/metres, calibrated stride, CMPedometer
//      vs HealthKit daily totals.
//    • Gradient — RSSI sample count, position count, spread, status,
//      computed bearing + confidence.
//    • BLE pipeline — seen / conn / svc / map counts.
//

import SwiftUI

struct DebugTelemetryView: View {
    @Environment(AppState.self) private var appState
    let memberID: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fusionSection
                    channelsSection
                    motionSection
                    stepsSection
                    gradientSection
                    blePipelineSection
                }
                .padding(16)
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    // MARK: - Fusion (EKF)

    @ViewBuilder
    private var fusionSection: some View {
        let est = appState.relativePoseFilter.estimate
        let vio = appState.visualOdometry
        section("FUSION (EKF + VIO)") {
            row("ekf state", appState.relativePoseFilter.isInitialized ? "tracking" : "uninitialized")
            row("ekf bearing", est.map { String(format: "%.0f°", $0.bearingDegrees) } ?? "—")
            row("ekf distance", est.map { String(format: "%.1f m", $0.distanceMetres) } ?? "—")
            row("ekf σ (pos)", est.map { String(format: "%.1f m %@", $0.positionStdDevMetres, $0.isConverged ? "(converged)" : "(settling)") } ?? "—")
            row("vio status", vio.statusText)
            row("vio tracking", vio.isTracking ? "yes" : "no")
            row("vio position", vio.position.map(vec) ?? "—")
        }
    }

    // MARK: - Channels

    @ViewBuilder
    private var channelsSection: some View {
        let diag = appState.seekingDiagnostics
        section("CHANNELS (all engaged concurrently)") {
            channelRow("UWB", diag.telemetryByChannel[.uwb])
            channelRow("BLE", diag.telemetryByChannel[.bleRanging])
            // Wi-Fi Aware intentionally omitted: iOS 26's WiFiAware
            // framework exposes discovery + data transport only — NO
            // ranging/distance API — so this channel can never produce a
            // sample. Showing it just looked broken.
            row("active", labelForChannel(diag.activeChannel))
        }
    }

    @ViewBuilder
    private func channelRow(_ name: String, _ t: ChannelTelemetry?) -> some View {
        if let t {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.primary).bold()
                HStack(spacing: 12) {
                    Text("temp " + (t.rssi.map { String(format: "%.0f dBm", $0) } ?? "—"))
                    Text("dist " + (t.distance.map { String(format: "%.2f m", $0) } ?? "—"))
                    Text(t.hasDirection ? "dir ✓" : "dir —")
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text("n \(t.sampleCount)")
                    Text("age " + ageString(t.lastSample))
                }
                .foregroundStyle(.tertiary)
            }
        } else {
            HStack {
                Text(name).foregroundStyle(.primary).bold()
                Spacer()
                Text("no samples").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Motion

    @ViewBuilder
    private var motionSection: some View {
        let m = appState.orientationService.debugSnapshot()
        section("MOTION") {
            row("CLHeading", appState.currentUser.heading.map { String(format: "%.0f°", $0) } ?? "—")
            row("attitude hdg", m.attitudeHeading.map { String(format: "%.0f° %@", $0, m.headingReliable ? "(reliable)" : "(unreliable)") } ?? "—")
            row("motion hdg", m.motionHeading.map { deg in
                let conf = m.motionConfidence.map { String(format: "%.2f", $0) } ?? "—"
                return String(format: "%.0f° conf %@", deg, conf)
            } ?? "—")
            row("gyro rad/s", vec(m.rotationRate))
            row("user accel", vec(m.userAcceleration))
            row("gravity", vec(m.gravity))
            row("activity", "\(m.activity) (\(m.activityConfidence))")
            row("attitude buf", "\(m.bufferCount) samples")
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepsSection: some View {
        let hk = appState.healthKitService
        section("STEPS / DISTANCE") {
            row("session steps", "\(appState.debugSessionSteps)")
            row("session metres", String(format: "%.1f m", appState.debugSessionMeters))
            row("calibrated stride", String(format: "%.2f m", appState.deadReckoningService.calibratedStepLength))
            row("HK today steps", hk.todaySteps.map { "\($0)" } ?? "—")
            row("HK today metres", hk.todayMeters.map { String(format: "%.0f m", $0) } ?? "—")
            row("HK status", hk.status)
        }
    }

    // MARK: - Gradient

    @ViewBuilder
    private var gradientSection: some View {
        let engine = appState.compassEngine
        let status = engine.gradientStatus(toMember: memberID)
        let bearing = engine.gradientBearing(toMember: memberID)
        section("GRADIENT (BLE RSSI)") {
            row("rssi samples", "\(engine.rssiSampleCount(for: memberID))")
            row("positions", "\(engine.positionSampleCount)")
            row("spread", String(format: "%.1f m", engine.positionSpreadMetres))
            row("status", statusText(status))
            row("bearing", bearing.map { String(format: "%.0f° (R² %.2f)", $0.bearing, $0.confidence) } ?? "nil")
            row("latest rssi", engine.latestRSSI(for: memberID).map { String(format: "%.0f dBm", $0) } ?? "—")
        }
    }

    // MARK: - BLE pipeline

    @ViewBuilder
    private var blePipelineSection: some View {
        let d = appState.bleDiagnostics
        section("BLE PIPELINE") {
            row("seen", "\(d.discoveredPeripheralCount)")
            row("connected", "\(d.connectedPeripheralCount)")
            row("svc discovered", "\(d.servicesDiscoveredCount)")
            row("mapped members", "\(d.mappedMemberCount)")
            row("bluetooth ready", d.bluetoothReady ? "yes" : "NO")
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section(_ title: String,
                         @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(.tint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.6))
        )
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func vec(_ v: SIMD3<Double>) -> String {
        String(format: "x%.2f y%.2f z%.2f", v.x, v.y, v.z)
    }

    private func ageString(_ date: Date?) -> String {
        guard let date else { return "—" }
        let age = Date().timeIntervalSince(date)
        if age < 1 { return "now" }
        if age < 60 { return "\(Int(age))s" }
        return "\(Int(age / 60))m"
    }

    private func labelForChannel(_ k: SeekingChannelKind?) -> String {
        switch k {
        case .uwb: return "uwb"
        case .wifiAwareRanging: return "wifi-aware"
        case .bleRanging: return "ble"
        case .none: return "—"
        }
    }

    private func statusText(_ s: CompassEngine.GradientStatus) -> String {
        switch s {
        case .ready: return "ready"
        case .needSamples(let have): return "need samples (have \(have))"
        case .needPositions: return "need positions"
        case .needMovement(let m): return String(format: "need movement (%.1f m)", m)
        case .singular: return "collinear"
        case .degenerate: return "degenerate"
        case .multipathHeavy: return "multipath heavy"
        }
    }
}

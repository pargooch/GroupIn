//
//  NeonRouteLayer.swift
//  GroupIn
//
//  Reusable glowing route renderer for MapLibre. A focused-peer route
//  is drawn as three style layers stacked over one shape source:
//    1. Wide soft halo  (15pt, low opacity)
//    2. Mid bloom layer (7pt,  med opacity)
//    3. Sharp core line (2.5pt, full opacity, dashed)
//
//  The dash phase on the core line is updated each frame via
//  `CADisplayLink`, scrolling the dashes so the line feels alive
//  without animating geometry every frame.
//

import UIKit
import MapLibre

final class NeonRouteLayer {
    private let sourceID = "neon-route-source"
    private let haloLayerID = "neon-route-halo"
    private let bloomLayerID = "neon-route-bloom"
    private let coreLayerID = "neon-route-core"

    private weak var style: MLNStyle?
    private let source: MLNShapeSource
    private let haloLayer: MLNLineStyleLayer
    private let bloomLayer: MLNLineStyleLayer
    private let coreLayer: MLNLineStyleLayer

    private var displayLink: CADisplayLink?
    private var dashPhase: CGFloat = 0
    private var visible: Bool = false

    init(style: MLNStyle) {
        self.style = style

        let emptyFeature = MLNShapeCollectionFeature(shapes: [])
        let source = MLNShapeSource(identifier: sourceID, shape: emptyFeature, options: nil)
        self.source = source

        let halo = MLNLineStyleLayer(identifier: haloLayerID, source: source)
        halo.lineWidth = NSExpression(forConstantValue: 15)
        halo.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.18))
        halo.lineOpacity = NSExpression(forConstantValue: 0.55)
        halo.lineBlur = NSExpression(forConstantValue: 8)
        halo.lineCap = NSExpression(forConstantValue: "round")
        halo.lineJoin = NSExpression(forConstantValue: "round")
        self.haloLayer = halo

        let bloom = MLNLineStyleLayer(identifier: bloomLayerID, source: source)
        bloom.lineWidth = NSExpression(forConstantValue: 7)
        bloom.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.6))
        bloom.lineOpacity = NSExpression(forConstantValue: 0.7)
        bloom.lineBlur = NSExpression(forConstantValue: 3)
        bloom.lineCap = NSExpression(forConstantValue: "round")
        bloom.lineJoin = NSExpression(forConstantValue: "round")
        self.bloomLayer = bloom

        let core = MLNLineStyleLayer(identifier: coreLayerID, source: source)
        core.lineWidth = NSExpression(forConstantValue: 2.5)
        core.lineColor = NSExpression(forConstantValue: UIColor.white)
        core.lineOpacity = NSExpression(forConstantValue: 0.95)
        core.lineCap = NSExpression(forConstantValue: "round")
        core.lineJoin = NSExpression(forConstantValue: "round")
        core.lineDashPattern = NSExpression(forConstantValue: [3, 2])
        self.coreLayer = core

        style.addSource(source)
        style.addLayer(halo)
        style.addLayer(bloom)
        style.addLayer(core)
    }

    deinit {
        stopFlow()
    }

    func update(start: CLLocationCoordinate2D,
                end: CLLocationCoordinate2D,
                color: UIColor) {
        let line = MLNPolylineFeature(coordinates: [start, end], count: 2)
        source.shape = line

        haloLayer.lineColor = NSExpression(forConstantValue: color.withAlphaComponent(0.4))
        bloomLayer.lineColor = NSExpression(forConstantValue: color.withAlphaComponent(0.85))
        coreLayer.lineColor = NSExpression(forConstantValue: color)

        haloLayer.isVisible = true
        bloomLayer.isVisible = true
        coreLayer.isVisible = true
        visible = true
        startFlow()
    }

    func clear() {
        source.shape = MLNShapeCollectionFeature(shapes: [])
        haloLayer.isVisible = false
        bloomLayer.isVisible = false
        coreLayer.isVisible = false
        visible = false
        stopFlow()
    }

    // MARK: Flow animation

    private func startFlow() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopFlow() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard visible else { return }
        // Cycle pattern length to scroll the dashes. MapLibre's
        // line-dash-pattern doesn't expose a phase property directly,
        // so we approximate motion by alternating the on/off lengths.
        dashPhase += 0.04
        if dashPhase > 5 { dashPhase = 0 }
        let on = 2.5 + sin(dashPhase * .pi) * 0.8
        let off = 1.5 + cos(dashPhase * .pi) * 0.5
        coreLayer.lineDashPattern = NSExpression(forConstantValue: [on, off])
    }
}

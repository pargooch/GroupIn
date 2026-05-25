//
//  MapLibreMapView.swift
//  GroupIn
//
//  MapLibre Native–backed map. Drop-in replacement for the old
//  MKMapView-based `NeonMapView`: same prop surface, same parent
//  contract. The map renders the custom MapTiler vector style for
//  a minimal dark backdrop; everything visually loud (avatars, halo,
//  beam, route) is drawn on top via MapLibre annotation views and
//  shape sources.
//
//  Architecture:
//    • `MapLibreMapView` is a thin SwiftUI shell.
//    • `Coordinator` owns all mutable map state (annotation diff,
//      route source, fit gating) so SwiftUI re-renders never wipe
//      the user's pan/zoom.
//    • `NeonAvatarMarkerView` (annotation view) handles per-peer
//      visuals (avatar, halo, pulse, directional beam).
//    • `NeonRouteLayer` owns the focused-peer glow line: a wide
//      blurred halo layer + a sharp core line + a CADisplayLink
//      that scrolls the dash phase so the route feels alive.
//

import SwiftUI
import MapLibre
import CoreLocation

struct MapLibreMapView: UIViewRepresentable {
    let members: [User]
    let currentMemberID: UUID
    let now: Date
    @Binding var focusedMemberID: UUID?
    @Binding var fitAllTrigger: Int
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero,
                             styleURL: MapTilerConfig.styleURL(for: colorScheme))
        context.coordinator.lastColorScheme = colorScheme
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButton.tintColor = UIColor.white.withAlphaComponent(0.35)
        map.compassView.isHidden = true
        map.showsUserLocation = false
        map.allowsRotating = false
        map.allowsTilting = false
        map.backgroundColor = .black
        // Hide MapLibre's stock annotation interaction; we drive
        // selection through our own gesture so the focus state in
        // SwiftUI stays the single source of truth.
        map.allowsScrolling = true
        map.allowsZooming = true
        // Pin a sensible default zoom so the map never opens at the
        // null-island world view while we're waiting for the first
        // coordinate. The user's last-known location would be better
        // but we don't have it on the SwiftUI thread here.
        map.minimumZoomLevel = 4
        map.setCenter(
            CLLocationCoordinate2D(latitude: 41.9, longitude: 12.5),
            zoomLevel: 11,
            animated: false
        )

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleBackgroundTap(_:))
        )
        tap.delegate = context.coordinator
        // Defer to MapLibre's own taps when they hit an annotation.
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)

        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyColorSchemeIfNeeded(on: map, colorScheme: colorScheme)
        coordinator.syncAnnotations(on: map)
        coordinator.syncFocusedRoute(on: map)
        coordinator.handleFitAllIfNeeded(on: map, trigger: fitAllTrigger)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapLibreMapView

        private var annotationsByMember: [UUID: NeonPointAnnotation] = [:]
        private var routeLayer: NeonRouteLayer?
        private var lastFitTrigger: Int = -1
        private var hasFitInitial = false
        private weak var mapRef: MLNMapView?
        /// Last appearance applied to the map — set in `makeUIView` and
        /// compared on every update so we only reload the style when
        /// the user actually flips light/dark mode.
        var lastColorScheme: ColorScheme?

        init(_ parent: MapLibreMapView) {
            self.parent = parent
        }

        // MARK: Light / dark style

        func applyColorSchemeIfNeeded(on map: MLNMapView,
                                      colorScheme: ColorScheme) {
            guard lastColorScheme != colorScheme else { return }
            lastColorScheme = colorScheme
            guard let url = MapTilerConfig.styleURL(for: colorScheme) else { return }
            // Reloading the style drops custom style layers (the neon
            // route line). Clear our reference so `didFinishLoading`
            // rebuilds it against the freshly-loaded style. Annotations
            // (member pins) are map-managed and survive the reload.
            routeLayer = nil
            map.styleURL = url
        }

        // MARK: Annotation diffing

        func syncAnnotations(on map: MLNMapView) {
            mapRef = map
            let renderable = parent.members.compactMap { m -> (User, CLLocationCoordinate2D)? in
                guard m.coordinate != nil,
                      let est = m.renderablePosition(now: parent.now),
                      est.source != .hypothetical else { return nil }
                return (m, est.coordinate.clLocation)
            }
            let liveIDs = Set(renderable.map(\.0.id))

            // Remove departures.
            for (id, anno) in annotationsByMember where !liveIDs.contains(id) {
                map.removeAnnotation(anno)
                annotationsByMember.removeValue(forKey: id)
            }

            // Add / update.
            for (member, coord) in renderable {
                let color = UIColor(Color.memberColor(for: member.id,
                                                       among: parent.members.map(\.id)))
                if let existing = annotationsByMember[member.id] {
                    if !coordinatesAreEqual(existing.coordinate, coord) {
                        UIView.animate(withDuration: 0.45,
                                       delay: 0,
                                       options: [.curveEaseInOut]) {
                            existing.coordinate = coord
                        }
                    }
                    existing.displayName = member.displayName
                    existing.avatarData = member.avatarData
                    existing.heading = member.heading
                    existing.memberColor = color
                    existing.isLocalUser = member.id == parent.currentMemberID
                    if let view = map.view(for: existing) as? NeonAvatarMarkerView {
                        view.apply(annotation: existing,
                                   focused: existing.memberID == parent.focusedMemberID)
                    }
                } else {
                    let anno = NeonPointAnnotation(
                        memberID: member.id,
                        coordinate: coord,
                        displayName: member.displayName,
                        avatarData: member.avatarData,
                        heading: member.heading,
                        memberColor: color,
                        isLocalUser: member.id == parent.currentMemberID
                    )
                    annotationsByMember[member.id] = anno
                    map.addAnnotation(anno)
                }
            }

            // Refresh focus highlight on every sync.
            for (id, anno) in annotationsByMember {
                if let view = map.view(for: anno) as? NeonAvatarMarkerView {
                    view.apply(annotation: anno,
                               focused: id == parent.focusedMemberID)
                }
            }

            // First-ever sync: frame the group.
            if !hasFitInitial, !renderable.isEmpty {
                fitAll(on: map, animated: false)
                hasFitInitial = true
            }
        }

        // MARK: Route layer

        func syncFocusedRoute(on map: MLNMapView) {
            guard let style = map.style else { return }
            let layer = ensureRouteLayer(style: style)
            guard let me = annotationsByMember[parent.currentMemberID],
                  let focusID = parent.focusedMemberID,
                  let peer = annotationsByMember[focusID],
                  focusID != parent.currentMemberID else {
                layer.clear()
                return
            }
            layer.update(start: me.coordinate,
                         end: peer.coordinate,
                         color: peer.memberColor)
            // Cinematic ease-in on the focused peer.
            let camera = MLNMapCamera(
                lookingAtCenter: midpoint(a: me.coordinate, b: peer.coordinate),
                acrossDistance: max(200, distanceMeters(me.coordinate, peer.coordinate) * 2.2),
                pitch: 0,
                heading: 0
            )
            map.setCamera(camera,
                          withDuration: 0.9,
                          animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
        }

        private func ensureRouteLayer(style: MLNStyle) -> NeonRouteLayer {
            if let layer = routeLayer { return layer }
            let layer = NeonRouteLayer(style: style)
            routeLayer = layer
            return layer
        }

        // MARK: Fit-all

        func handleFitAllIfNeeded(on map: MLNMapView, trigger: Int) {
            guard trigger != lastFitTrigger else { return }
            lastFitTrigger = trigger
            if hasFitInitial {
                fitAll(on: map, animated: true)
            }
        }

        private func fitAll(on map: MLNMapView, animated: Bool) {
            let allCoords = annotationsByMember.values.map(\.coordinate)
            guard !allCoords.isEmpty else { return }

            // Focus on where most members are. Outliers (a friend who
            // left for the airport, a cached old fix in another city)
            // shouldn't pull the camera out to "see all of Italy."
            let coords = clusterFocused(coords: allCoords)

            if coords.count == 1, let only = coords.first {
                let camera = MLNMapCamera(
                    lookingAtCenter: only,
                    acrossDistance: 130,
                    pitch: 0,
                    heading: 0
                )
                map.setCamera(camera,
                              withDuration: animated ? 0.7 : 0,
                              animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
                return
            }

            let bounds = MLNCoordinateBounds.from(coords: coords)
            let insets = UIEdgeInsets(top: 70, left: 44, bottom: 170, right: 44)

            // Hard zoom-out cap: if fitting the cluster would mean
            // pulling back farther than 30 km across, bail out of the
            // bounds-fit and use a camera centered on the cluster's
            // centroid at a fixed 30 km. Outliers stay off-screen.
            let extent = boundsExtentMeters(bounds)
            if extent > 30_000 {
                let centroid = CLLocationCoordinate2D(
                    latitude: coords.map(\.latitude).reduce(0, +) / Double(coords.count),
                    longitude: coords.map(\.longitude).reduce(0, +) / Double(coords.count)
                )
                let camera = MLNMapCamera(
                    lookingAtCenter: centroid,
                    acrossDistance: 30_000,
                    pitch: 0,
                    heading: 0
                )
                map.setCamera(camera,
                              withDuration: animated ? 0.7 : 0,
                              animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
                return
            }

            map.setVisibleCoordinateBounds(bounds,
                                           edgePadding: insets,
                                           animated: animated,
                                           completionHandler: nil)
        }

        /// Diagonal of the bounding box in meters. Used as a rough
        /// "how big is this fit going to be" check before we hand it
        /// to MapLibre.
        private func boundsExtentMeters(_ b: MLNCoordinateBounds) -> Double {
            let sw = CLLocation(latitude: b.sw.latitude, longitude: b.sw.longitude)
            let ne = CLLocation(latitude: b.ne.latitude, longitude: b.ne.longitude)
            return sw.distance(from: ne)
        }

        /// Drop outliers so the camera zooms to where the majority of
        /// the group actually is. Anyone whose distance from the
        /// centroid exceeds `max(2 × median, 150 m)` is excluded.
        /// The 150 m floor protects tight clusters (everyone in one
        /// bar) from accidentally rejecting a member three tables away.
        private func clusterFocused(coords: [CLLocationCoordinate2D])
            -> [CLLocationCoordinate2D] {
            guard coords.count > 2 else { return coords }
            let centroid = CLLocationCoordinate2D(
                latitude: coords.map(\.latitude).reduce(0, +) / Double(coords.count),
                longitude: coords.map(\.longitude).reduce(0, +) / Double(coords.count)
            )
            let center = CLLocation(latitude: centroid.latitude,
                                    longitude: centroid.longitude)
            let distances = coords.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: center)
            }
            let sorted = distances.sorted()
            let median = sorted[sorted.count / 2]
            let threshold = max(median * 2, 150)
            let kept = zip(coords, distances).compactMap { $1 <= threshold ? $0 : nil }
            // If the heuristic somehow drops everyone, fall back to the
            // full set so the user still sees their group.
            return kept.isEmpty ? coords : kept
        }

        // MARK: Delegate

        func mapView(_ mapView: MLNMapView,
                     viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let neon = annotation as? NeonPointAnnotation else { return nil }
            let reuseID = NeonAvatarMarkerView.reuseIdentifier
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                        as? NeonAvatarMarkerView)
                ?? NeonAvatarMarkerView(reuseIdentifier: reuseID)
            view.apply(annotation: neon,
                       focused: neon.memberID == parent.focusedMemberID)
            view.onTap = { [weak self] in
                self?.handleAnnotationTap(memberID: neon.memberID,
                                          isLocalUser: neon.isLocalUser)
            }
            return view
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            _ = ensureRouteLayer(style: style)
        }

        private func handleAnnotationTap(memberID: UUID, isLocalUser: Bool) {
            if isLocalUser {
                parent.focusedMemberID = nil
                return
            }
            if parent.focusedMemberID == memberID {
                parent.focusedMemberID = nil
            } else {
                parent.focusedMemberID = memberID
            }
        }

        // MARK: Background tap

        @objc func handleBackgroundTap(_ recognizer: UITapGestureRecognizer) {
            parent.focusedMemberID = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            // Don't fire background-tap if the touch landed on a marker view.
            var v = touch.view
            while let view = v {
                if view is NeonAvatarMarkerView { return false }
                v = view.superview
            }
            return true
        }

        // MARK: Geometry helpers

        private func coordinatesAreEqual(_ a: CLLocationCoordinate2D,
                                         _ b: CLLocationCoordinate2D) -> Bool {
            abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7
        }

        private func midpoint(a: CLLocationCoordinate2D,
                              b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: (a.latitude + b.latitude) / 2,
                longitude: (a.longitude + b.longitude) / 2
            )
        }

        private func distanceMeters(_ a: CLLocationCoordinate2D,
                                    _ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
    }
}

// MARK: - Annotation model

final class NeonPointAnnotation: NSObject, MLNAnnotation {
    let memberID: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var displayName: String
    var avatarData: Data?
    var heading: Double?
    var memberColor: UIColor
    var isLocalUser: Bool

    init(memberID: UUID,
         coordinate: CLLocationCoordinate2D,
         displayName: String,
         avatarData: Data?,
         heading: Double?,
         memberColor: UIColor,
         isLocalUser: Bool) {
        self.memberID = memberID
        self.coordinate = coordinate
        self.displayName = displayName
        self.avatarData = avatarData
        self.heading = heading
        self.memberColor = memberColor
        self.isLocalUser = isLocalUser
    }
}

// MARK: - Bounds helper

private extension MLNCoordinateBounds {
    static func from(coords: [CLLocationCoordinate2D]) -> MLNCoordinateBounds {
        var minLat = coords[0].latitude
        var maxLat = coords[0].latitude
        var minLon = coords[0].longitude
        var maxLon = coords[0].longitude
        for c in coords {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }
        // Tiny pad so single-cluster groups don't render at max zoom.
        let pad = 0.00015
        return MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: minLat - pad, longitude: minLon - pad),
            ne: CLLocationCoordinate2D(latitude: maxLat + pad, longitude: maxLon + pad)
        )
    }
}

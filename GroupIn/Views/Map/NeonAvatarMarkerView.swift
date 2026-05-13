//
//  NeonAvatarMarkerView.swift
//  GroupIn
//
//  MapLibre annotation view rendering a member as:
//    • Soft blurred shadow (drop)
//    • Pulsing glow halo in the member's neon color
//    • Directional beam (local user only) rotated by their heading
//    • Circular avatar (initials when no photo)
//    • Name plate below the avatar
//    • Tighter highlight ring when focused
//
//  All layers are CALayers driven by `CABasicAnimation` —
//  GPU-backed and battery-efficient. We size the annotation view at
//  120pt square so the halo / beam can extend beyond the avatar
//  without clipping.
//

import UIKit
import MapLibre

final class NeonAvatarMarkerView: MLNAnnotationView {
    static let reuseIdentifier = "NeonAvatarMarkerView"

    var onTap: (() -> Void)?

    private let beamLayer = CAShapeLayer()
    private let haloLayer = CALayer()
    private let shadowLayer = CALayer()
    private let avatarContainer = UIView()
    private let avatarImageView = UIImageView()
    private let initialsLabel = UILabel()
    private let ringLayer = CAShapeLayer()
    private let nameLabel = UILabel()

    private var currentColor: UIColor = .white
    private var currentHeading: Double = .nan
    private var isPeerFocused = false
    private var isLocalUser = false

    init(reuseIdentifier: String) {
        super.init(reuseIdentifier: reuseIdentifier)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        let size: CGFloat = 120
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        // MapLibre anchors annotation views at their center on the
        // coordinate; centerOffset stays zero so the avatar visually
        // sits on the geographic point.
        backgroundColor = .clear
        isUserInteractionEnabled = true

        // Beam (behind everything, only shown for local user).
        beamLayer.fillColor = UIColor.white.withAlphaComponent(0.0).cgColor
        beamLayer.opacity = 0
        layer.addSublayer(beamLayer)

        // Halo: blurred radial via two layers (outer wide blur,
        // inner softer ring). One CALayer with a shadow does the
        // heavy lifting; pulse animation lives here.
        haloLayer.frame = CGRect(x: size/2 - 28, y: size/2 - 28, width: 56, height: 56)
        haloLayer.cornerRadius = 28
        haloLayer.backgroundColor = UIColor.clear.cgColor
        haloLayer.shadowRadius = 18
        haloLayer.shadowOpacity = 0.9
        haloLayer.shadowOffset = .zero
        layer.addSublayer(haloLayer)

        // Soft drop shadow puddle under the avatar — adds depth.
        shadowLayer.frame = CGRect(x: size/2 - 22, y: size/2 - 14, width: 44, height: 18)
        shadowLayer.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
        shadowLayer.cornerRadius = 9
        shadowLayer.shadowColor = UIColor.black.cgColor
        shadowLayer.shadowRadius = 8
        shadowLayer.shadowOpacity = 0.45
        shadowLayer.shadowOffset = CGSize(width: 0, height: 6)
        layer.insertSublayer(shadowLayer, below: haloLayer)

        // Avatar.
        avatarContainer.frame = CGRect(x: size/2 - 22, y: size/2 - 22, width: 44, height: 44)
        avatarContainer.backgroundColor = UIColor(white: 0.08, alpha: 1)
        avatarContainer.layer.cornerRadius = 22
        avatarContainer.layer.masksToBounds = true
        addSubview(avatarContainer)

        avatarImageView.frame = avatarContainer.bounds
        avatarImageView.contentMode = .scaleAspectFill
        avatarContainer.addSubview(avatarImageView)

        initialsLabel.frame = avatarContainer.bounds
        initialsLabel.textAlignment = .center
        initialsLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        initialsLabel.textColor = .white
        avatarContainer.addSubview(initialsLabel)

        // Ring on top of the avatar — colored stroke, thicker when focused.
        ringLayer.frame = CGRect(x: size/2 - 23, y: size/2 - 23, width: 46, height: 46)
        ringLayer.path = UIBezierPath(ovalIn: ringLayer.bounds).cgPath
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.lineWidth = 2
        layer.addSublayer(ringLayer)

        // Name plate.
        nameLabel.frame = CGRect(x: 0, y: size/2 + 26, width: size, height: 18)
        nameLabel.textAlignment = .center
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.shadowColor = .black
        nameLabel.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(nameLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        // VoiceOver treats the whole marker as a single element so a
        // user can swipe to it and hear the peer's name + state in
        // one breath. Decorative subviews stay hidden from a11y.
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        avatarContainer.isAccessibilityElement = false
        avatarImageView.isAccessibilityElement = false
        initialsLabel.isAccessibilityElement = false
        nameLabel.isAccessibilityElement = false

        startPulse()
    }

    // MARK: - State

    func apply(annotation: NeonPointAnnotation, focused: Bool) {
        currentColor = annotation.memberColor
        currentHeading = annotation.heading ?? .nan
        isPeerFocused = focused
        isLocalUser = annotation.isLocalUser

        haloLayer.shadowColor = annotation.memberColor.cgColor
        ringLayer.strokeColor = annotation.memberColor.cgColor
        ringLayer.lineWidth = focused ? 3 : 2

        nameLabel.text = annotation.isLocalUser ? "You" : annotation.displayName
        nameLabel.textColor = focused
            ? .white
            : UIColor.white.withAlphaComponent(0.85)

        if let data = annotation.avatarData, let img = UIImage(data: data) {
            avatarImageView.image = img
            initialsLabel.isHidden = true
        } else {
            avatarImageView.image = nil
            initialsLabel.text = Self.initials(from: annotation.displayName)
            initialsLabel.isHidden = false
            avatarContainer.backgroundColor = annotation.memberColor
                .withAlphaComponent(0.85)
        }

        updateBeam()

        // Focus = larger pulse amplitude. Re-add animation so the new
        // amplitude takes effect immediately.
        startPulse()

        // Refresh the VoiceOver label so it reflects the latest peer
        // state (name, focus, local-user marker).
        let suffix = annotation.isLocalUser ? "your location" : "group member"
        if focused {
            accessibilityLabel = "\(annotation.displayName), \(suffix), route drawn"
        } else {
            accessibilityLabel = "\(annotation.displayName), \(suffix)"
        }
        accessibilityHint = annotation.isLocalUser
            ? ""
            : "Double tap to draw a route to this person."
    }

    private func updateBeam() {
        // Beam only for local user with a valid compass heading.
        guard isLocalUser, currentHeading.isFinite else {
            beamLayer.opacity = 0
            return
        }
        let size = bounds.width
        let center = CGPoint(x: size / 2, y: size / 2)
        let length: CGFloat = 56
        let spread: CGFloat = 0.35 // radians half-angle
        let headingRad = CGFloat(currentHeading * .pi / 180)
        // 0° heading = north = up = -Y in view space.
        let upAngle = -CGFloat.pi / 2 + headingRad
        let path = UIBezierPath()
        path.move(to: center)
        path.addArc(withCenter: center,
                    radius: length,
                    startAngle: upAngle - spread,
                    endAngle: upAngle + spread,
                    clockwise: true)
        path.close()
        beamLayer.path = path.cgPath
        beamLayer.fillColor = currentColor.withAlphaComponent(0.35).cgColor
        beamLayer.shadowColor = currentColor.cgColor
        beamLayer.shadowOpacity = 0.6
        beamLayer.shadowRadius = 14
        beamLayer.shadowOffset = .zero
        beamLayer.opacity = 1
    }

    private func startPulse() {
        haloLayer.removeAnimation(forKey: "pulse")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = isPeerFocused ? 0.85 : 0.9
        scale.toValue = isPeerFocused ? 1.35 : 1.18
        scale.duration = 1.6
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let opacity = CABasicAnimation(keyPath: "shadowOpacity")
        opacity.fromValue = isPeerFocused ? 1.0 : 0.7
        opacity.toValue = 0.25
        opacity.duration = 1.6
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.6
        group.repeatCount = .infinity
        group.autoreverses = false
        haloLayer.add(group, forKey: "pulse")
    }

    @objc private func handleTap() {
        onTap?()
    }

    // MARK: - Helpers

    private static func initials(from name: String) -> String {
        let parts = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        if parts.isEmpty { return "?" }
        if parts.count == 1 { return String(parts[0].prefix(1)).uppercased() }
        let a = parts[0].first.map { String($0) } ?? ""
        let b = parts.last?.first.map { String($0) } ?? ""
        return (a + b).uppercased()
    }
}

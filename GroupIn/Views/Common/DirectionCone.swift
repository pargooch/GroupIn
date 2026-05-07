//
//  DirectionCone.swift
//  GroupIn
//
//  A fan-shaped "field of view" indicator for member pins, similar to
//  Google Maps' user-facing arc. Drawn with the cone pointing UP by
//  default; rotate via `.rotationEffect(.degrees(heading))` where heading
//  is degrees clockwise from true north.
//

import SwiftUI

struct DirectionCone: Shape {
    /// Total spread of the cone in degrees. 60° feels close to Google Maps.
    var spreadDegrees: Double = 60

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let half = spreadDegrees / 2
        // -90° in SwiftUI angle space is straight up.
        let start = Angle.degrees(-90 - half)
        let end = Angle.degrees(-90 + half)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

#Preview {
    VStack(spacing: 32) {
        ZStack {
            DirectionCone()
                .fill(LinearGradient(
                    colors: [Color.blue.opacity(0.5), Color.blue.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 90, height: 90)
            Circle().fill(.blue).frame(width: 32, height: 32)
        }
        .rotationEffect(.degrees(0))

        ZStack {
            DirectionCone()
                .fill(LinearGradient(
                    colors: [Color.green.opacity(0.5), Color.green.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 90, height: 90)
            Circle().fill(.green).frame(width: 32, height: 32)
        }
        .rotationEffect(.degrees(45))
    }
    .padding()
}

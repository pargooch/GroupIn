//
//  AvatarCropperView.swift
//  GroupIn
//
//  Circular crop UI presented after picking a photo. Pinch to zoom,
//  drag to position. On Done, the visible region inside the circle
//  is rendered to JPEG data and returned via the callback.
//

import SwiftUI
import UIKit

/// Wrapper so we can use `.sheet(item:)` / `.fullScreenCover(item:)` with a
/// UIImage payload (UIImage isn't `Identifiable` itself).
struct CropperSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct AvatarCropperView: View {
    let sourceImage: UIImage
    let onCommit: (Data?) -> Void

    @Environment(\.dismiss) private var dismiss

    // Active gesture state
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    // Committed values that gestures build on
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    /// Set from the GeometryReader so the renderer uses the same coordinate
    /// system as the live UI.
    @State private var liveContainerSize: CGFloat = 0

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let containerSize = side
                let cropDiameter = side * 0.85

                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: sourceImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: containerSize, height: containerSize)
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: containerSize, height: containerSize)
                        .clipped()
                        .gesture(combinedGesture)

                    // Dim everything outside the circle.
                    Color.black.opacity(0.55)
                        .frame(width: containerSize, height: containerSize)
                        .mask {
                            Rectangle()
                                .overlay {
                                    Circle()
                                        .frame(width: cropDiameter, height: cropDiameter)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)

                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: cropDiameter, height: cropDiameter)
                        .allowsHitTesting(false)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .onAppear { liveContainerSize = containerSize }
                .onChange(of: containerSize) { _, new in liveContainerSize = new }
            }
            .navigationTitle("Adjust photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCommit(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let data = renderCropped()
                        onCommit(data)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - Gestures

    private var combinedGesture: some Gesture {
        SimultaneousGesture(
            DragGesture()
                .onChanged { value in
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    lastOffset = offset
                },
            MagnificationGesture()
                .onChanged { value in
                    scale = min(maxScale, max(minScale, lastScale * value))
                }
                .onEnded { _ in
                    lastScale = scale
                }
        )
    }

    // MARK: - Render

    /// Replay the user's transform on a 512×512 bitmap, clipped to a circle.
    private func renderCropped() -> Data? {
        guard liveContainerSize > 0 else { return nil }

        let outputSize = CGSize(width: 512, height: 512)
        let containerSize = liveContainerSize
        let cropDiameter = containerSize * 0.85
        let outputScale = outputSize.width / cropDiameter

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext

            // Clip to circle so the saved asset is pre-rounded.
            cg.addEllipse(in: CGRect(origin: .zero, size: outputSize))
            cg.clip()

            // Origin = center of output. Then map container points to output px.
            cg.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            cg.scaleBy(x: outputScale, y: outputScale)

            // Apply user's pan + zoom (in container points, scaled from center).
            cg.translateBy(x: offset.width, y: offset.height)
            cg.scaleBy(x: scale, y: scale)

            // Draw scaledToFill image centered at the origin.
            let imgAspect = sourceImage.size.width / sourceImage.size.height
            let drawWidth: CGFloat
            let drawHeight: CGFloat
            if imgAspect >= 1 {
                drawHeight = containerSize
                drawWidth = drawHeight * imgAspect
            } else {
                drawWidth = containerSize
                drawHeight = drawWidth / imgAspect
            }
            sourceImage.draw(in: CGRect(
                x: -drawWidth / 2,
                y: -drawHeight / 2,
                width: drawWidth,
                height: drawHeight
            ))
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}

#Preview {
    AvatarCropperView(
        sourceImage: UIImage(systemName: "photo")!
    ) { _ in }
}

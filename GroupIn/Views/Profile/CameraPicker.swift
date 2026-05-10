//
//  CameraPicker.swift
//  GroupIn
//
//  Thin SwiftUI wrapper around UIImagePickerController in camera mode.
//  Captured photos are handed back via `onCapture(UIImage)` which the
//  profile editor then routes through the same cropper used by the
//  Photos library path — so the camera flow ends up in identical
//  shape to a hand-picked photo.
//

import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    /// Fires once with the captured image, then the sheet dismisses.
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Defensive guard — Simulator and iPad without a camera report
        // .camera as unavailable. Fall back to the photo library so we
        // don't crash; the surrounding flow still works.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera
            : .photoLibrary
        picker.cameraDevice = .front          // selfie default; user can flip
        picker.allowsEditing = false          // we have our own cropper
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject,
                             UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void
        private var didFinish = false

        init(onCapture: @escaping (UIImage) -> Void,
             onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Original is fine — we crop on the next screen anyway.
            guard !didFinish,
                  let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            didFinish = true
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !didFinish else { return }
            didFinish = true
            onCancel()
        }
    }
}

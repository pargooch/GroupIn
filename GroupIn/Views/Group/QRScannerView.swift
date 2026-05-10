//
//  QRScannerView.swift
//  GroupIn
//
//  Live camera QR scanner wrapped in a SwiftUI sheet. Uses AVFoundation
//  directly (no AVCaptureMetadataOutput abstractions on top) so we can
//  control framing, dim the rest of the screen, and stop scanning the
//  moment we get a usable code — preventing the same QR firing the
//  callback dozens of times per second.
//

import SwiftUI
import AVFoundation

struct QRScannerView: View {
    /// Fires once with the scanned string, then the sheet dismisses.
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if permissionDenied {
                    permissionDeniedView
                } else {
                    QRCameraView { code in
                        onScan(code)
                        dismiss()
                    } onPermissionDenied: {
                        permissionDenied = true
                    }
                    .ignoresSafeArea()

                    overlayFrame
                }
            }
            .navigationTitle("Scan invite QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var overlayFrame: some View {
        VStack {
            Spacer()
            // Sight reticle. Doesn't constrain detection (AVFoundation
            // scans the whole frame), purely a visual aid so users know
            // where to point.
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.85), lineWidth: 3)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.5), radius: 20)
            Spacer()
            Text("Point your camera at a GroupIn QR code.")
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 60))
                .foregroundStyle(.white)
            Text("Camera access is off")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Enable Camera access in Settings to scan QR codes.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
    }
}

// MARK: - UIKit camera bridge

/// Thin UIViewControllerRepresentable that runs an AVCaptureSession with
/// a metadata output filtered to QR codes. The hosting VC handles its own
/// lifecycle (start on appear, stop on disappear) so the camera doesn't
/// stay live in the background.
private struct QRCameraView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onPermissionDenied: () -> Void

    func makeUIViewController(context: Context) -> QRCameraViewController {
        let controller = QRCameraViewController()
        controller.onScan = onScan
        controller.onPermissionDenied = onPermissionDenied
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCameraViewController, context: Context) {}
}

private final class QRCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var hasFired = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
           !session.isRunning {
            // AVCaptureSession.startRunning blocks the calling thread, so
            // it has to live off the main queue.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.stopRunning()
            }
        }
    }

    private func configureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            buildPipeline()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.buildPipeline()
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            self?.session.startRunning()
                        }
                    } else {
                        self?.onPermissionDenied?()
                    }
                }
            }
        default:
            onPermissionDenied?()
        }
    }

    private func buildPipeline() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // First valid hit wins. Subsequent metadata in the same frame
        // would otherwise re-fire the callback while we're still
        // dismissing the sheet.
        guard !hasFired else { return }
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue,
              !value.isEmpty else { return }
        hasFired = true
        // Light haptic so the scan feels responsive even before the
        // sheet animation kicks in.
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(value)
    }
}

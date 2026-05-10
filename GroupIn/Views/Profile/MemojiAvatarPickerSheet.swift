//
//  MemojiAvatarPickerSheet.swift
//  GroupIn
//
//  Lets the user set their own Memoji as a profile picture without
//  first saving it to Photos. Memoji stickers are images (not text), so
//  we use a UITextView that accepts attachment inserts and listen for:
//
//    1. NSAdaptiveImageGlyph (iOS 18+) — the modern path used by
//       Memoji and Genmoji stickers in the system keyboard.
//    2. NSTextAttachment (iOS 17) — the older path Memoji stickers
//       arrive through when inserted from the keyboard's stickers tab.
//
//  The first inserted image is captured, rendered to JPEG, and handed
//  back through `onPick`. The sheet then dismisses.
//

import SwiftUI
import UIKit

struct MemojiAvatarPickerSheet: View {
    /// Fires once with the rendered avatar data. Sheet dismisses on its own.
    let onPick: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var capturedImage: UIImage?
    @State private var isFirstResponder: Bool = true

    var body: some View {
        NavigationStack {
            ZStack {
                // Background tap layer — taps anywhere outside the
                // capture field flip `isFirstResponder` off, which the
                // UIView bridge translates into resignFirstResponder()
                // and dismisses the keyboard.
                Color(.systemBackground)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isFirstResponder = false
                    }

                VStack(spacing: 24) {
                    preview

                    MemojiCaptureField(
                        capturedImage: $capturedImage,
                        isFirstResponder: $isFirstResponder
                    )
                    .frame(height: 60)
                    .padding(.horizontal, 16)
                    .background(Color.secondary.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)
                    .onTapGesture {
                        // Tap on the field itself re-opens the keyboard.
                        isFirstResponder = true
                    }

                    instructions

                    Spacer()
                }
                .padding(.top, 24)
            }
            .navigationTitle("Pick your Memoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let image = capturedImage,
                           let data = renderToAvatar(image) {
                            onPick(data)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(capturedImage == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 200, height: 200)

            if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .clipShape(Circle())
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("Memoji preview")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var instructions: some View {
        VStack(spacing: 6) {
            Text(capturedImage == nil
                 ? "Open the stickers tab in your keyboard and tap your Memoji."
                 : "Looks good? Tap Use this to save it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if capturedImage == nil {
                Label("Sticker keyboard → Memoji",
                      systemImage: "smiley")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 24)
    }

    /// Resize + JPEG-compress the captured Memoji to the same shape as
    /// other avatars so the rest of the pipeline (CloudKit publish, BLE
    /// broadcast, AvatarView rendering) doesn't need to special-case it.
    private func renderToAvatar(_ image: UIImage) -> Data? {
        let target = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { ctx in
            // Soft tinted background so transparent Memoji stickers
            // (most are PNG with alpha) don't render with a blank halo.
            UIColor.systemGray6.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))

            // Aspect-fit, centered.
            let imgSize = image.size
            let scale = min(target.width / imgSize.width,
                            target.height / imgSize.height)
            let drawSize = CGSize(width: imgSize.width * scale,
                                  height: imgSize.height * scale)
            let origin = CGPoint(
                x: (target.width - drawSize.width) / 2,
                y: (target.height - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return resized.jpegData(compressionQuality: 0.9)
    }
}

// MARK: - UIKit capture field

/// SwiftUI bridge to a UITextView that listens for Memoji / Genmoji
/// insertion. We don't show typed text — the field exists purely to
/// receive an image attachment from the system keyboard's stickers
/// tab. As soon as one arrives, we hand it up via `capturedImage`
/// and reset the field so the user can try a different Memoji.
private struct MemojiCaptureField: UIViewRepresentable {
    @Binding var capturedImage: UIImage?
    @Binding var isFirstResponder: Bool

    func makeUIView(context: Context) -> UITextView {
        let tv = MemojiTextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.systemFont(ofSize: 40)
        tv.textAlignment = .center
        tv.allowsEditingTextAttributes = true
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false

        // iOS 18 introduced "adaptive image glyphs" — the new way Memoji
        // and Genmoji are inserted as inline content. Opting in is a
        // single property; without it, stickers can't be inserted at
        // all in iOS 18+.
        if #available(iOS 18.0, *) {
            tv.supportsAdaptiveImageGlyph = true
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if isFirstResponder, !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(capturedImage: $capturedImage)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var capturedImage: UIImage?

        init(capturedImage: Binding<UIImage?>) {
            _capturedImage = capturedImage
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let extracted = extractFirstImage(from: textView.attributedText)
            else { return }

            capturedImage = extracted
            // Wipe the field so a second insertion lets the user swap
            // Memoji without manually deleting first.
            textView.text = ""
        }

        /// Walk the attributed string looking for either an adaptive
        /// image glyph (iOS 18+ Memoji/Genmoji) or a classic text
        /// attachment (iOS 17 sticker insertion).
        private func extractFirstImage(from attributed: NSAttributedString) -> UIImage? {
            let fullRange = NSRange(location: 0, length: attributed.length)

            if #available(iOS 18.0, *) {
                var foundData: Data?
                attributed.enumerateAttribute(
                    .adaptiveImageGlyph,
                    in: fullRange
                ) { value, _, stop in
                    if let glyph = value as? NSAdaptiveImageGlyph {
                        foundData = glyph.imageContent
                        stop.pointee = true
                    }
                }
                if let data = foundData, let image = UIImage(data: data) {
                    return image
                }
            }

            // Fallback path: NSTextAttachment with an embedded image.
            // Memoji stickers from the iOS 17 stickers keyboard land
            // here.
            var fallback: UIImage?
            attributed.enumerateAttribute(
                .attachment,
                in: fullRange
            ) { value, _, stop in
                if let attachment = value as? NSTextAttachment,
                   let image = attachment.image
                    ?? attachment.image(forBounds: .zero,
                                        textContainer: nil,
                                        characterIndex: 0) {
                    fallback = image
                    stop.pointee = true
                }
            }
            return fallback
        }
    }
}

/// UITextView subclass that pins its `textInputMode` to the user's
/// emoji/stickers keyboard. The Memoji stickers tab lives inside the
/// emoji keyboard, so forcing emoji input cuts straight to the right
/// place — no globe-icon hunt.
private final class MemojiTextView: UITextView {
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes
        where mode.primaryLanguage == "emoji" {
            return mode
        }
        return super.textInputMode
    }

    override var textInputContextIdentifier: String? { "" }
}

#Preview {
    MemojiAvatarPickerSheet { _ in }
}

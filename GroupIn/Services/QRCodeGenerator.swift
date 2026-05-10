//
//  QRCodeGenerator.swift
//  GroupIn
//
//  Tiny wrapper around Core Image's QR generator. We render the raw
//  invite code as the QR payload — the join flow already accepts the
//  same string from the manual-entry text field, so QR-scanned and
//  hand-typed codes go through identical validation.
//

import CoreImage.CIFilterBuiltins
import UIKit

enum QRCodeGenerator {
    /// Renders a high-correction QR image from a string.
    /// Returns nil only if the string can't be encoded (empty / invalid),
    /// which the caller can treat as "skip the QR section."
    static func makeImage(from string: String,
                          scale: CGFloat = 12) -> UIImage? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // High correction so the code still scans even if part of it is
        // covered (a finger, glare on the screen). Costs a tiny bit of
        // density — fine at the sizes we render.
        filter.correctionLevel = "H"

        guard let output = filter.outputImage else { return nil }

        // The raw CIImage is tiny (~25×25 pixels). Scale it up using a
        // nearest-neighbor transform so the squares stay crisp instead of
        // blurring into each other.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

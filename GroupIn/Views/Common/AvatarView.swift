//
//  AvatarView.swift
//  GroupIn
//
//  Renders an avatar from raw image data, falling back to colored initials.
//

import SwiftUI
import UIKit

struct AvatarView: View {
    let data: Data?
    let name: String
    let size: CGFloat

    init(data: Data?, name: String, size: CGFloat = 44) {
        self.data = data
        self.name = name
        self.size = size
    }

    var body: some View {
        ZStack {
            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(name)
    }

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }
}

#Preview {
    VStack(spacing: 16) {
        AvatarView(data: nil, name: "Kian Pargooch", size: 80)
        AvatarView(data: nil, name: "Alex", size: 44)
        AvatarView(data: nil, name: "", size: 44)
    }
    .padding()
}

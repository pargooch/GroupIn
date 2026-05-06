//
//  AvatarView.swift
//  GroupIn
//
//  Renders an avatar from raw image data, falling back to a solid
//  colored circle showing the first letter of the name.
//

import SwiftUI
import UIKit

struct AvatarView: View {
    let data: Data?
    let name: String
    let size: CGFloat
    let tint: Color

    init(data: Data?,
         name: String,
         size: CGFloat = 44,
         tint: Color = .accentColor) {
        self.data = data
        self.name = name
        self.size = size
        self.tint = tint
    }

    var body: some View {
        ZStack {
            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(tint)
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel(name)
    }

    private var initials: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

#Preview {
    VStack(spacing: 16) {
        AvatarView(data: nil, name: "Kian", size: 80, tint: .blue)
        AvatarView(data: nil, name: "Alex", size: 44, tint: .orange)
        AvatarView(data: nil, name: "Sara", size: 44, tint: .pink)
        AvatarView(data: nil, name: "", size: 44, tint: .green)
    }
    .padding()
}

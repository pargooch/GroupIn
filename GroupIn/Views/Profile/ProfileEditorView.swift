//
//  ProfileEditorView.swift
//  GroupIn
//
//  Edits the device-side profile. Saving propagates the new name and
//  avatar into every existing group membership.
//

import SwiftUI
import PhotosUI
import UIKit

struct ProfileEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var avatarData: Data?
    @State private var photoSelection: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var cropperSource: CropperSource?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    AvatarView(data: avatarData, name: name, size: 80)

                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $photoSelection,
                                     matching: .images,
                                     photoLibrary: .shared()) {
                            Label(avatarData == nil ? "Choose photo" : "Change photo",
                                  systemImage: "photo")
                        }
                        .disabled(loadingPhoto)
                        .accessibilityHint("Pick a photo or memoji from your library")

                        if avatarData != nil {
                            Button(role: .destructive) {
                                avatarData = nil
                                photoSelection = nil
                            } label: {
                                Label("Remove photo", systemImage: "trash")
                            }
                        }

                        if loadingPhoto {
                            ProgressView()
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Photo")
            } footer: {
                Text("Tip: save a memoji as a sticker in Photos to use it here.")
                    .font(.caption)
            }

            Section("Display name") {
                TextField("e.g. Alex", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .accessibilityLabel("Display name")
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                }
                .disabled(trimmedName.isEmpty)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = appState.localProfile.displayName
            avatarData = appState.localProfile.avatarData
        }
        .onChange(of: photoSelection) { _, newItem in
            guard let newItem else { return }
            loadingPhoto = true
            Task {
                defer { loadingPhoto = false }
                if let raw = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: raw) {
                    cropperSource = CropperSource(image: img)
                }
            }
        }
        .fullScreenCover(item: $cropperSource) { src in
            AvatarCropperView(sourceImage: src.image) { cropped in
                if let cropped {
                    avatarData = cropped
                }
                cropperSource = nil
                photoSelection = nil
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        appState.localProfile = LocalProfile(
            displayName: trimmedName,
            avatarData: avatarData
        )
        dismiss()
    }

    /// Resize + JPEG-compress so the encoded blob stays small enough for
    /// UserDefaults / future CloudKit assets without exploding storage.
    static func compressForAvatar(_ data: Data,
                                  maxDimension: CGFloat = 256,
                                  quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        let largest = max(size.width, size.height)
        guard largest > maxDimension else {
            return image.jpegData(compressionQuality: quality) ?? data
        }
        let scale = maxDimension / largest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let resized = image.preparingThumbnail(of: target) ?? image
        return resized.jpegData(compressionQuality: quality)
    }
}

#Preview {
    NavigationStack {
        ProfileEditorView()
    }
    .environment(AppState())
}

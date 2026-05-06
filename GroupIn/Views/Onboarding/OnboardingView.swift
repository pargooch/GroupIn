//
//  OnboardingView.swift
//  GroupIn
//
//  Shown until the user picks a display name. Once saved, RootView
//  swaps to the main NavigationStack. There's no skip or back —
//  this is a hard gate before any group action.
//

import SwiftUI
import PhotosUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    @State private var name: String = ""
    @State private var avatarData: Data?
    @State private var photoSelection: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var cropperSource: CropperSource?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        AvatarView(data: avatarData, name: name, size: 96)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }

                Section {
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
                } header: {
                    Text("Photo (optional)")
                } footer: {
                    Text("Tip: save a memoji as a sticker in Photos to use it here.")
                        .font(.caption)
                }

                Section("What should others see?") {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityLabel("Display name")
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(trimmedName.isEmpty)
                } footer: {
                    Text("This is the name members of your groups will see. You can change it later in your profile.")
                        .font(.caption)
                }
            }
            .navigationTitle("Welcome to GroupIn")
            .navigationBarTitleDisplayMode(.inline)
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
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        appState.localProfile = LocalProfile(
            displayName: trimmedName,
            avatarData: avatarData
        )
    }
}

#Preview {
    OnboardingView()
        .environment(AppState())
}

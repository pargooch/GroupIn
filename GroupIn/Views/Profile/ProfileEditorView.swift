//
//  ProfileEditorView.swift
//  GroupIn
//
//  Edits the device-side profile. Saving propagates the new name and
//  avatar into every existing group membership.
//
//  Layout follows iOS Contacts/Settings convention: a big circular
//  avatar with a camera-icon overlay that opens an action sheet of
//  edit options. The avatar only updates when the user explicitly
//  confirms a new pick (cropper "Done" or emoji "Use this") — canceling
//  any step leaves the existing avatar untouched.
//

import SwiftUI
import PhotosUI
import UIKit

struct ProfileEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var name: String = ""
    @State private var avatarData: Data?
    @State private var hapticsEnabled: Bool = HapticEngine.isUserEnabled
    @State private var voiceGuidanceEnabled: Bool = VoiceGuidance.isUserEnabled

    @State private var photoSelection: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var cropperSource: CropperSource?

    @State private var showsActionSheet = false
    @State private var showsPhotosPicker = false
    @State private var showsMemojiPicker = false
    @State private var showsCameraPicker = false
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            avatarSection

            Section("Display name") {
                TextField("e.g. Alex", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .accessibilityLabel("Display name")
            }

            Section {
                Toggle(isOn: $hapticsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vibration Guidance")
                        Text("GroupIn's own taps and a heartbeat that gets stronger as you walk toward a friend you're finding.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: hapticsEnabled) { _, newValue in
                    HapticEngine.setUserEnabled(newValue)
                    if newValue { HapticEngine.shared.tick() }
                }

                Toggle(isOn: $voiceGuidanceEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spoken Updates")
                        Text("With VoiceOver on, GroupIn speaks its own updates — who joined, when a friend gets closer, and live distance while you're finding someone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: voiceGuidanceEnabled) { _, newValue in
                    VoiceGuidance.setUserEnabled(newValue)
                    if newValue {
                        VoiceGuidance.shared.announce("Spoken updates on.")
                    }
                }
            } header: {
                Text("GroupIn Feedback")
            } footer: {
                Text("These are GroupIn's own cues — separate from iOS's system haptics and VoiceOver settings.")
                    .font(.caption)
            }

            safetySection

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
        // Action sheet — what to do with the avatar.
        .confirmationDialog("Profile picture",
                            isPresented: $showsActionSheet,
                            titleVisibility: .hidden) {
            Button("Take Photo") { showsCameraPicker = true }
            Button("Choose Photo") { showsPhotosPicker = true }
            Button("Use Memoji") { showsMemojiPicker = true }
            if avatarData != nil {
                Button("Remove Photo", role: .destructive) {
                    confirmingRemoval = true
                }
            }
        }
        // Removing is destructive — confirm before clearing.
        .alert("Remove profile photo?",
               isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                avatarData = nil
                photoSelection = nil
            }
        } message: {
            Text("Your avatar will fall back to your initial.")
        }
        // Photos library picker.
        .photosPicker(
            isPresented: $showsPhotosPicker,
            selection: $photoSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        // Memoji sticker capture sheet.
        .sheet(isPresented: $showsMemojiPicker) {
            MemojiAvatarPickerSheet { data in
                avatarData = data
            }
        }
        // Live camera capture — routes back through the cropper so the
        // captured photo gets the same circular framing/zoom as a
        // library pick.
        .fullScreenCover(isPresented: $showsCameraPicker) {
            CameraPicker { image in
                showsCameraPicker = false
                cropperSource = CropperSource(image: image)
            } onCancel: {
                showsCameraPicker = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoSelection) { _, newItem in
            // Only react when a real selection arrives. nil happens when
            // we reset the picker after a successful crop, and must NOT
            // touch avatarData.
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
                // Cropper Cancel returns nil — leave avatar untouched.
                // Only a confirmed crop replaces the existing avatar.
                if let cropped {
                    avatarData = cropped
                }
                cropperSource = nil
                photoSelection = nil
            }
        }
    }

    // MARK: - Safety / Find My handoff

    @ViewBuilder
    private var safetySection: some View {
        Section {
            Button {
                openFindMy()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.18))
                        Image(systemName: "location.viewfinder")
                            .foregroundStyle(.green)
                    }
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set up Find My backup")
                            .foregroundStyle(.primary)
                            .font(.body.weight(.medium))
                        Text("Apple's separate network — works at longer range when GroupIn can't reach.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Find My app so you can share your location as a backup")
        } header: {
            Text("Safety")
        } footer: {
            Text("GroupIn handles real-time group awareness. Find My runs through Apple's network — useful as a long-range backup when our signal can't reach.")
                .font(.caption)
        }
    }

    private func openFindMy() {
        // Try the native scheme first; fall back to the universal link
        // (which iOS routes into the Find My app on devices that have it,
        // and to the iCloud web UI otherwise).
        guard let scheme = URL(string: "findmy://"),
              let universal = URL(string: "https://www.icloud.com/findmy") else {
            return
        }
        openURL(scheme) { accepted in
            if !accepted {
                openURL(universal)
            }
        }
    }

    // MARK: - Avatar section

    @ViewBuilder
    private var avatarSection: some View {
        Section {
            VStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(data: avatarData, name: name, size: 140)
                        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

                    Button {
                        showsActionSheet = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 38, height: 38)
                                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .overlay(
                            // White ring so the badge separates cleanly
                            // from the avatar behind it.
                            Circle()
                                .stroke(Color(.systemBackground), lineWidth: 3)
                        )
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change profile picture")
                }
                // Whole avatar is also tappable — large hit target.
                .contentShape(Circle())
                .onTapGesture { showsActionSheet = true }

                if loadingPhoto {
                    ProgressView()
                        .padding(.top, 4)
                } else {
                    Text("Tap to change")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .listRowBackground(Color.clear)
        } footer: {
            Text("Photos, Memoji stickers, and emoji all work.")
                .font(.caption)
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

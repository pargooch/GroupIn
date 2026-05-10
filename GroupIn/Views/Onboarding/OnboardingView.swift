//
//  OnboardingView.swift
//  GroupIn
//
//  First-launch welcome screen. Replaces the previous Settings-style
//  Form with a hero icon, a tagline, and a compact "tap to set your
//  avatar + type your name" layout. Once the user saves, RootView
//  detects the cleared `needsOnboarding` flag and swaps this view
//  out for the main NavigationStack — no manual transition needed.
//
//  Avatar interactions mirror ProfileEditorView (Take Photo / Choose
//  Photo / Use Memoji), so the muscle memory is identical from the
//  first run onward.
//

import SwiftUI
import PhotosUI
import UIKit

struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    @State private var name: String = ""
    @State private var avatarData: Data?

    @State private var photoSelection: PhotosPickerItem?
    @State private var loadingPhoto = false
    @State private var cropperSource: CropperSource?

    @State private var showsActionSheet = false
    @State private var showsPhotosPicker = false
    @State private var showsMemojiPicker = false
    @State private var showsCameraPicker = false

    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            backdrop

            ScrollView {
                VStack(spacing: 24) {
                    hero
                        .padding(.top, 32)

                    avatarBlock

                    nameBlock

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack {
                Spacer()
                getStartedButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .background(
                        // Soft top fade so content scrolling under the
                        // pinned button doesn't visually slam into it.
                        LinearGradient(
                            colors: [
                                Color(.systemBackground).opacity(0),
                                Color(.systemBackground).opacity(0.95),
                                Color(.systemBackground)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    )
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .confirmationDialog("Profile picture",
                            isPresented: $showsActionSheet,
                            titleVisibility: .hidden) {
            Button("Take Photo") { showsCameraPicker = true }
            Button("Choose Photo") { showsPhotosPicker = true }
            Button("Use Memoji") { showsMemojiPicker = true }
            if avatarData != nil {
                Button("Remove Photo", role: .destructive) {
                    avatarData = nil
                }
            }
        }
        .photosPicker(
            isPresented: $showsPhotosPicker,
            selection: $photoSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        .sheet(isPresented: $showsMemojiPicker) {
            MemojiAvatarPickerSheet { data in
                avatarData = data
            }
        }
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

    // MARK: - Background

    @ViewBuilder
    private var backdrop: some View {
        // Soft accent halo at the top, fading into the system
        // background. Gives the screen a sense of warmth without
        // committing to a heavy custom palette.
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.18),
                Color.accentColor.opacity(0.05),
                Color(.systemBackground)
            ],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 120, height: 120)
                Image(systemName: "person.3.sequence.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .shadow(color: Color.accentColor.opacity(0.25), radius: 20, y: 10)
            .accessibilityHidden(true)

            Text("Welcome to GroupIn")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            Text("Find your friends in any crowd — online or off.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Avatar block

    @ViewBuilder
    private var avatarBlock: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(data: avatarData, name: name, size: 110)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

                Button {
                    showsActionSheet = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .overlay(
                        Circle().stroke(Color(.systemBackground), lineWidth: 3)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose profile picture")
            }
            .contentShape(Circle())
            .onTapGesture { showsActionSheet = true }

            if loadingPhoto {
                ProgressView().padding(.top, 4)
            } else {
                Text(avatarData == nil ? "Add a photo (optional)" : "Tap to change")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Name block

    @ViewBuilder
    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should friends call you?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            TextField("Your name", text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($nameFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                )
                .accessibilityLabel("Display name")

            Text("This is the name members of your groups will see. You can change it later in your profile.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Get Started button

    @ViewBuilder
    private var getStartedButton: some View {
        Button {
            save()
        } label: {
            Text("Get Started")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(trimmedName.isEmpty
                              ? Color.accentColor.opacity(0.4)
                              : Color.accentColor)
                )
                .foregroundStyle(.white)
        }
        .disabled(trimmedName.isEmpty)
        .accessibilityHint("Saves your profile and opens the home screen")
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

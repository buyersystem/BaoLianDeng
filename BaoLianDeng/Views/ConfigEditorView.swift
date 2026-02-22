// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import SwiftUI

enum ConfigSource: Hashable {
    case local
    case subscription(UUID)
}

struct ConfigEditorView: View {
    @State private var configText: String = ""
    @State private var subscriptionText: String = ""
    @State private var validationErrors: [YAMLError] = []
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSaving = false
    @State private var showSaved = false
    @State private var showErrors = false
    @State private var source: ConfigSource = .local
    @State private var selectedSubscription: Subscription?

    var isSubscriptionSource: Bool {
        if case .subscription = source { return true }
        return false
    }

    private var activeText: Binding<String> {
        isSubscriptionSource ? $subscriptionText : $configText
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if selectedSubscription != nil {
                    sourcePicker
                }
                configHeader
                YAMLEditor(text: activeText, validationErrors: $validationErrors)
                if !validationErrors.isEmpty {
                    errorBar
                }
            }
            .navigationTitle("Config")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        isSubscriptionSource ? saveSubscription() : saveConfig()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        if isSubscriptionSource {
                            Button("Reset to Fetched", role: .destructive) { resetSubscription() }
                        } else {
                            Button("Reset Default", role: .destructive) { resetConfig() }
                        }
                        Spacer()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .sheet(isPresented: $showErrors) {
                errorListSheet
            }
            .overlay {
                if showSaved {
                    savedToast
                }
            }
            .onAppear {
                loadConfig()
                validationErrors = YAMLValidator.validate(configText)
                loadSelectedSubscription()
            }
            .onChange(of: source) { _, _ in
                validationErrors = YAMLValidator.validate(isSubscriptionSource ? subscriptionText : configText)
            }
        }
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $source) {
            Text("Local Config").tag(ConfigSource.local)
            if let sub = selectedSubscription {
                Text(sub.name).tag(ConfigSource.subscription(sub.id))
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var configHeader: some View {
        HStack {
            Image(systemName: isSubscriptionSource ? "cloud.fill" : "doc.text")
            if isSubscriptionSource, let sub = selectedSubscription {
                Text(sub.url)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("config.yaml")
                    .font(.caption)
            }
            Spacer()
            Text("\(isSubscriptionSource ? subscriptionText.count : configText.count) chars")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var errorBar: some View {
        Button(action: { showErrors = true }) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("\(validationErrors.count) issue\(validationErrors.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .buttonStyle(.plain)
    }

    private var errorListSheet: some View {
        NavigationStack {
            List(validationErrors) { error in
                HStack(alignment: .top, spacing: 10) {
                    Text("L\(error.line)")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 40, alignment: .trailing)
                    Text(error.message)
                        .font(.caption)
                }
            }
            .navigationTitle("YAML Issues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showErrors = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var savedToast: some View {
        VStack {
            Spacer()
            Text("Saved")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.thinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 80)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func loadSelectedSubscription() {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let data = defaults?.data(forKey: "subscriptions"),
              let subs = try? JSONDecoder().decode([Subscription].self, from: data),
              let idString = defaults?.string(forKey: "selectedSubscriptionID"),
              let id = UUID(uuidString: idString),
              let sub = subs.first(where: { $0.id == id }) else {
            selectedSubscription = nil
            return
        }
        selectedSubscription = sub
        subscriptionText = sub.rawContent ?? ""
        if subscriptionText.isEmpty {
            source = .local
        }
    }

    private func loadConfig() {
        if ConfigManager.shared.configExists() {
            do {
                configText = try ConfigManager.shared.loadConfig()
            } catch {
                configText = ConfigManager.shared.defaultConfig()
            }
        } else {
            configText = ConfigManager.shared.defaultConfig()
        }
    }

    private func saveConfig() {
        isSaving = true
        do {
            try ConfigManager.shared.saveConfig(configText)
            withAnimation { showSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { showSaved = false }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSaving = false
    }

    private func resetConfig() {
        configText = ConfigManager.shared.defaultConfig()
        validationErrors = YAMLValidator.validate(configText)
    }

    private func saveSubscription() {
        guard let sub = selectedSubscription else { return }
        isSaving = true

        // Persist edited rawContent back to UserDefaults
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        if var subs = defaults?.data(forKey: "subscriptions")
            .flatMap({ try? JSONDecoder().decode([Subscription].self, from: $0) }),
           let i = subs.firstIndex(where: { $0.id == sub.id }) {
            subs[i].rawContent = subscriptionText
            selectedSubscription = subs[i]
            if let encoded = try? JSONEncoder().encode(subs) {
                defaults?.set(encoded, forKey: "subscriptions")
            }
        }

        // Apply edited YAML as the active config
        do {
            try ConfigManager.shared.applySubscriptionConfig(subscriptionText)
            Task { await ConfigManager.shared.downloadGeoDataIfNeeded() }
            withAnimation { showSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { showSaved = false }
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSaving = false
    }

    private func resetSubscription() {
        subscriptionText = selectedSubscription?.rawContent ?? ""
        validationErrors = YAMLValidator.validate(subscriptionText)
    }
}

#Preview {
    ConfigEditorView()
}

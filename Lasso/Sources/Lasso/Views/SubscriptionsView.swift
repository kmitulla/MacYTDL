import SwiftUI

struct SubscriptionsView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @EnvironmentObject private var prefs: Preferences
    @State private var newURL = ""
    @State private var newPreset: QualityPreset = .best
    @State private var onlyNew = true
    @State private var isAdding = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Subscriptions", subtitle: "Channels and playlists are checked automatically – new videos land in your download folder.") {
                    Button {
                        store.checkAll()
                    } label: {
                        Label("Check all now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .glassButtonStyle()
                    .controlSize(.large)
                    .disabled(store.subscriptions.isEmpty)
                }

                addBar

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                if store.subscriptions.isEmpty {
                    ContentUnavailableView {
                        Label("No subscriptions yet", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Add a YouTube channel (e.g. youtube.com/@channel), a playlist or a podcast feed. Lasso checks it in the background while it's running – also from the menu bar.")
                    }
                    .padding(.top, 30)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(store.subscriptions) { sub in
                            SubscriptionRow(subscription: sub)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(.tint)
                TextField("Channel or playlist link…", text: $newURL)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit(add)
                Picker("", selection: $newPreset) {
                    Section("Video") { ForEach(QualityPreset.videoPresets) { Text($0.title).tag($0) } }
                    Section("Audio") { ForEach(QualityPreset.audioPresets) { Text($0.title).tag($0) } }
                }
                .labelsHidden()
                .frame(width: 160)
                if isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Subscribe", action: add)
                        .glassButtonStyle(prominent: true)
                        .controlSize(.large)
                        .disabled(newURL.isEmpty)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .glassCapsule(interactive: true)
            Toggle("Only download videos published from now on (recommended)", isOn: $onlyNew)
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.leading, 18)
        }
    }

    private func add() {
        let url = URLTools.normalize(newURL)
        guard URLTools.isLikelyMediaURL(url) else {
            error = String(localized: "Please paste a valid link (https://…).")
            return
        }
        error = nil
        isAdding = true
        Task {
            do {
                let info = try await MetadataService.fetch(url: url, playlist: true)
                store.add(url: url, info: info, preset: newPreset, onlyNew: onlyNew)
                newURL = ""
                ToastCenter.shared.show(String(localized: "Subscribed to “\(info.title)”"), symbol: "bell.badge.fill")
            } catch {
                self.error = error.localizedDescription
            }
            isAdding = false
        }
    }
}

private struct SubscriptionRow: View {
    let subscription: Subscription
    @EnvironmentObject private var store: SubscriptionStore
    @EnvironmentObject private var prefs: Preferences

    private let intervals = [1, 3, 6, 12, 24, 48, 168]

    var body: some View {
        HStack(spacing: 16) {
            Thumbnail(url: subscription.thumbnail, cornerRadius: 12, symbol: "dot.radiowaves.left.and.right")
                .frame(width: 120, height: 68)
                .opacity(subscription.enabled ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(subscription.title).font(.headline).lineLimit(1)
                    if store.checking.contains(subscription.id) {
                        ProgressView().controlSize(.mini)
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(URLTools.displayHost(subscription.url) + " · " + subscription.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                FlowRow(spacing: 6) {
                    Pill(text: String(localized: "Checked \(Format.relative(subscription.lastChecked))"), symbol: "clock")
                    if subscription.lastNewCount > 0 {
                        Pill(text: String(localized: "\(subscription.lastNewCount) new"), symbol: "sparkles", color: .green)
                    }
                    Pill(text: String(localized: "\(subscription.totalDownloaded) total"), symbol: "tray.full")
                    if let error = subscription.lastError {
                        Pill(text: error.components(separatedBy: "\n").first ?? error, symbol: "exclamationmark.triangle", color: .orange)
                            .help(error)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("", selection: binding(\.preset)) {
                        Section("Video") { ForEach(QualityPreset.videoPresets) { Text($0.title).tag($0) } }
                        Section("Audio") { ForEach(QualityPreset.audioPresets) { Text($0.title).tag($0) } }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Picker("", selection: binding(\.intervalHours)) {
                        ForEach(intervals, id: \.self) { hours in
                            Text(intervalLabel(hours)).tag(hours)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                HStack(spacing: 8) {
                    Toggle("Active", isOn: binding(\.enabled))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Button {
                        store.check(subscription)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .glassButtonStyle()
                    .help("Check now")
                    .disabled(store.checking.contains(subscription.id))
                    Button {
                        if let url = URL(string: subscription.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        Image(systemName: "safari")
                    }
                    .glassButtonStyle()
                    .help("Open in browser")
                    Button(role: .destructive) {
                        store.remove(subscription)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .glassButtonStyle()
                    .help("Remove subscription")
                }
            }
        }
        .padding(14)
        .acrylic(cornerRadius: 18)
    }

    private func intervalLabel(_ hours: Int) -> String {
        switch hours {
        case 1: return String(localized: "Every hour")
        case 24: return String(localized: "Daily")
        case 48: return String(localized: "Every 2 days")
        case 168: return String(localized: "Weekly")
        default: return String(localized: "Every \(hours) hours")
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Subscription, T>) -> Binding<T> {
        Binding(
            get: { store.subscriptions.first(where: { $0.id == subscription.id })?[keyPath: keyPath] ?? subscription[keyPath: keyPath] },
            set: { value in
                var updated = store.subscriptions.first(where: { $0.id == subscription.id }) ?? subscription
                updated[keyPath: keyPath] = value
                store.update(updated)
            }
        )
    }
}

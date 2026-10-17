import SwiftUI
import AppKit

// MARK: - Liquid Glass with graceful fallback

extension View {
    /// Liquid Glass on macOS 26+, frosted "acrylic" material with a hairline border before that.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 18, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if Preferences.shared.glassStyle != .liquid {
            self.acrylic(cornerRadius: cornerRadius, tint: tint)
        } else if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive),
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.acrylic(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        self.acrylic(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if Preferences.shared.glassStyle == .solid {
            self.background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        } else if Preferences.shared.glassStyle == .frosted {
            self.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        } else if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .background(Capsule().fill(tint?.opacity(0.18) ?? .clear))
        }
        #else
        self.background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        #endif
    }

    func acrylic(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        let solid = Preferences.shared.glassStyle == .solid
        return self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(solid ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint?.opacity(0.12) ?? .clear)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.35), Color.primary.opacity(0.06)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.07), radius: 12, y: 5)
    }

    /// Fluent-style content card ("layer") used for lists and panels.
    func card(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        self.padding(Preferences.shared.compactMode ? padding * 0.7 : padding).acrylic(cornerRadius: cornerRadius)
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if Preferences.shared.glassStyle != .liquid {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        } else if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }
}

/// Groups glass shapes so they blend/morph together on macOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

// MARK: - Ambient background (Mica-like)

struct AmbientBackground: View {
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let accent = prefs.accent.color ?? Color.accentColor
        let companion = prefs.accent.companion
        let k = prefs.ambientIntensity
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Circle()
                    .fill(accent.opacity((scheme == .dark ? 0.30 : 0.20) * k))
                    .frame(width: geo.size.width * 0.9, height: geo.size.width * 0.9)
                    .blur(radius: 140)
                    .offset(x: -geo.size.width * 0.35, y: -geo.size.height * 0.45)
                Circle()
                    .fill(companion.opacity((scheme == .dark ? 0.24 : 0.16) * k))
                    .frame(width: geo.size.width * 0.8, height: geo.size.width * 0.8)
                    .blur(radius: 160)
                    .offset(x: geo.size.width * 0.45, y: geo.size.height * 0.35)
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Reusable pieces

struct SectionHeader: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

struct PageHeader<Trailing: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Async thumbnail with a soft placeholder.
struct Thumbnail: View {
    var url: String?
    var cornerRadius: CGFloat = 12
    var symbol: String = "play.rectangle.fill"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.purple.opacity(0.25)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.white.opacity(0.85))
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}

struct Pill: View {
    var text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Slim progress bar in Fluent style with an animated gradient.
struct SlimProgressBar: View {
    var value: Double
    var indeterminate: Bool = false
    var color: Color = .accentColor

    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if indeterminate {
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: phase * geo.size.width)
                        .onAppear {
                            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * CGFloat(min(1, max(0, value)))))
                        .animation(.easeOut(duration: 0.35), value: value)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }
}

// MARK: - Toasts

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var symbol: String
    }

    @Published var current: Toast?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, symbol: String = "info.circle") {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            current = Toast(message: message, symbol: symbol)
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.easeInOut(duration: 0.3)) { self?.current = nil }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }
}

struct ToastOverlay: View {
    @ObservedObject var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer()
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.symbol).foregroundStyle(.tint)
                    Text(toast.message).lineLimit(3)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassCapsule()
                .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { center.current = nil }
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(center.current != nil)
    }
}

// MARK: - Misc helpers

@MainActor
enum Finder {
    static func reveal(_ path: String) {
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            let folder = (path as NSString).deletingLastPathComponent
            NSWorkspace.shared.open(URL(fileURLWithPath: folder))
        }
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func openFolder(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func chooseFolder(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static var freeDiskSpace: Int64? { DiskSpaceMonitor.shared.free }
}

/// Free space on the home volume, measured in the background (the "important usage" query can take
/// seconds because it asks the system how much purgeable space it could free). Deliberately doesn't
/// touch ~/Downloads, which would trigger a privacy prompt at launch.
@MainActor
final class DiskSpaceMonitor: ObservableObject {
    static let shared = DiskSpaceMonitor()
    @Published private(set) var free: Int64?
    private var timer: Timer?
    private var running = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !running else { return }
        running = true
        Task.detached(priority: .utility) {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let quick = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
            await MainActor.run { if DiskSpaceMonitor.shared.free == nil { DiskSpaceMonitor.shared.free = quick } }
            let important = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            await MainActor.run {
                DiskSpaceMonitor.shared.free = important ?? quick
                DiskSpaceMonitor.shared.running = false
            }
        }
    }
}

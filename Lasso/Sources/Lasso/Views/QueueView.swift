import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var prefs: Preferences
    @State private var filter: QueueFilter = .all

    enum QueueFilter: String, CaseIterable, Identifiable {
        case all, active, finished, failed
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .active: return "Active"
            case .finished: return "Finished"
            case .failed: return "Failed"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Downloads", subtitle: subtitle) {
                GlassGroup {
                    HStack(spacing: 8) {
                        Button { downloads.pauseAll() } label: { Label("Pause all", systemImage: "pause.fill") }
                            .disabled(downloads.pendingCount == 0)
                        Button { downloads.resumeAll() } label: { Label("Resume all", systemImage: "play.fill") }
                            .disabled(!downloads.tasks.contains { $0.state == .paused })
                        Button { downloads.retryFailed() } label: { Label("Retry failed", systemImage: "arrow.clockwise") }
                            .disabled(!downloads.tasks.contains { $0.state == .failed })
                        Button { downloads.clearFinished() } label: { Label("Clear", systemImage: "checkmark.circle.badge.xmark") }
                            .disabled(downloads.finishedCount == 0)
                    }
                    .glassButtonStyle()
                    .labelStyle(.iconOnly)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 14)

            HStack(spacing: 14) {
                Picker("", selection: $filter) {
                    ForEach(QueueFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                Spacer()
                Stepper(value: $prefs.maxConcurrent, in: 1...8) {
                    Text("Parallel: \(prefs.maxConcurrent)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: prefs.maxConcurrent) { _, _ in downloads.pump() }
                .help("How many downloads run at the same time")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 12)

            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(filter == .all ? LocalizedStringKey("No downloads yet") : LocalizedStringKey("Nothing here"), systemImage: "arrow.down.circle.dotted")
                } description: {
                    Text("Paste a link on the New Download page, drop it into the window or press ⇧⌘V.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    let pending = filtered.filter { !$0.state.isFinished }
                    let done = filtered.filter { $0.state.isFinished }
                    if !pending.isEmpty {
                        Section {
                            ForEach(pending) { task in
                                TaskRow(task: task)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 32, bottom: 5, trailing: 32))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                            .onMove { source, destination in
                                guard filter == .all || filter == .active else { return }
                                downloads.movePending(fromOffsets: source, toOffset: destination)
                            }
                        } header: {
                            HStack {
                                Text("Active & waiting")
                                Text("– drag to change the order").foregroundStyle(.tertiary)
                                Spacer()
                                Menu("Sort") {
                                    Button("Title") { downloads.sortPending { $0.title } }
                                    Button("Website") { downloads.sortPending { URLTools.displayHost($0.request.url) } }
                                    Button("Audio first") { downloads.sortPending { $0.request.options.preset.isAudio ? "0" : "1" } }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    if !done.isEmpty {
                        Section {
                            ForEach(done.sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }) { task in
                                TaskRow(task: task)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 32, bottom: 5, trailing: 32))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text("Done").padding(.horizontal, 20)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: downloads.tasks.map(\.id))
            }
        }
    }

    private var subtitle: LocalizedStringKey {
        let active = downloads.activeCount
        let waiting = downloads.tasks.filter { $0.state == .queued }.count
        if active == 0 && waiting == 0 {
            return downloads.tasks.isEmpty ? "Your queue is empty." : "All done. \(downloads.finishedCount) finished."
        }
        return "\(active) active · \(waiting) waiting · \(Format.speed(downloads.totalSpeed))"
    }

    /// Queue order (top = runs next) for pending tasks.
    private var filtered: [DownloadTask] {
        switch filter {
        case .all: return downloads.tasks
        case .active: return downloads.tasks.filter { !$0.state.isFinished }
        case .finished: return downloads.tasks.filter { $0.state == .completed }
        case .failed: return downloads.tasks.filter { $0.state == .failed || $0.state == .cancelled }
        }
    }
}

struct TaskRow: View {
    @ObservedObject var task: DownloadTask
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var appState: AppState
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Thumbnail(url: task.thumbnail, cornerRadius: 10,
                      symbol: task.isSubscriptionCheck ? "dot.radiowaves.left.and.right" : (task.request.options.preset.isAudio ? "music.note" : "play.rectangle.fill"))
                .frame(width: 128, height: 72)
                .overlay(alignment: .topLeading) {
                    if task.state == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .padding(5)
                    }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(1)
                    if task.isSubscriptionCheck {
                        Pill(text: String(localized: "Subscription"), symbol: "bell", color: .purple)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: task.state.symbol)
                        .foregroundStyle(task.state.color)
                    Text(task.statusLine)
                        .lineLimit(2)
                        .foregroundStyle(task.state == .failed ? Color.red : Color.secondary)
                        .contentTransition(.numericText())
                }
                .font(.callout)
                if !task.state.isFinished || task.state == .completed {
                    SlimProgressBar(value: task.progress,
                                    indeterminate: task.state == .preparing || task.state == .processing,
                                    color: task.state == .completed ? .green : (task.state == .paused ? .gray : .accentColor))
                        .frame(maxWidth: 520)
                }
                HStack(spacing: 6) {
                    Pill(text: task.request.options.preset.isAudio || !task.isMusic ? task.request.options.preset.title : QualityPreset.audioMP3.title,
                         symbol: task.request.options.preset.symbol)
                    if let group = task.request.group, group.total > 1 {
                        Pill(text: "\(group.name) · \(group.index)/\(group.total)", symbol: task.isMusic ? "music.note.list" : "list.number")
                    }
                    if task.isMusic && task.musicAttempt > 0 {
                        Pill(text: String(localized: "Source \(task.musicAttempt + 1)"), symbol: "arrow.triangle.branch", color: .orange)
                    }
                    if let uploader = task.uploader { Pill(text: uploader, symbol: "person") }
                    if task.request.options.hasClip { Pill(text: CommandBuilder.clipLabel(task.request.options), symbol: "scissors") }
                    if task.attempts > 1 { Pill(text: String(localized: "Attempt \(task.attempts)"), symbol: "arrow.clockwise", color: .orange) }
                }
            }

            Spacer(minLength: 8)

            if task.state.isActive || task.state == .queued {
                Text(verbatim: "\(Int((task.progress * 100).rounded())) %")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            actions
        }
        .padding(14)
        .acrylic(cornerRadius: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(task.state == .failed ? Color.red.opacity(0.35) : Color.clear)
        )
        .scaleEffect(hovering ? 1.004 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu { menu }
        .onTapGesture(count: 2) {
            if let file = task.outputFiles.last { Finder.open(file) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch task.state {
            case .queued, .preparing, .downloading, .processing:
                iconButton("pause.fill", help: "Pause") { downloads.pause(task) }
                iconButton("xmark", help: "Cancel") { downloads.cancel(task) }
            case .paused:
                iconButton("play.fill", help: "Resume") { downloads.resume(task) }
                iconButton("xmark", help: "Cancel") { downloads.cancel(task) }
            case .failed, .cancelled:
                iconButton("arrow.clockwise", help: "Try again") { downloads.retry(task) }
                iconButton("doc.text.magnifyingglass", help: "Show log") { appState.logTask = task }
            case .completed:
                if let file = task.outputFiles.last {
                    iconButton("play.circle", help: "Play") {
                        if let item = LibraryStore.shared.items.first(where: { $0.filePath == file }) {
                            LibraryActions.play([item])
                        } else {
                            Finder.open(file)
                        }
                    }
                    iconButton("magnifyingglass", help: "Show in Finder") { Finder.reveal(file) }
                }
            }
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
        }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .glassButtonStyle()
        .buttonBorderShape(.circle)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        if let file = task.outputFiles.last {
            Button("Open") { Finder.open(file) }
            Button("Show in Finder") { Finder.reveal(file) }
            Divider()
        }
        Button("Copy Link") { Finder.copy(task.request.url) }
        Button("Open Link in Browser") {
            if let url = URL(string: task.request.url) { NSWorkspace.shared.open(url) }
        }
        Button("Show Log") { appState.logTask = task }
        Button("Copy yt-dlp Command") { Finder.copy(task.commandLine) }
            .disabled(task.commandLine.isEmpty)
        Divider()
        if task.state == .queued || task.state == .paused {
            Button("Download Next") { downloads.prioritize(task) }
            Button("Download Last") { downloads.moveToEnd(task) }
        }
        if let file = task.outputFiles.last, let item = LibraryStore.shared.items.first(where: { $0.filePath == file }) {
            Button("Play in Lasso") { LibraryActions.play([item]) }
        }
        if task.state.isFinished {
            Button("Download Again") { downloads.retry(task) }
        }
        Button("Remove from List", role: .destructive) { downloads.remove(task) }
    }
}

struct LogView: View {
    @ObservedObject var task: DownloadTask
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Log").font(.title2.weight(.bold))
                    Text(task.title).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Copy Command") { Finder.copy(task.commandLine) }
                Button("Copy Log") { Finder.copy(text) }
                Button("Show in Finder") { Finder.reveal(task.logFile.path) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error = task.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text(error).textSelection(.enabled)
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { text = task.fullLog }
    }
}

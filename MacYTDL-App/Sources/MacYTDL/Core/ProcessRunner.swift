import Foundation
import Darwin

/// Runs a child process in its own process group so that it - and every helper it starts
/// (ffmpeg, deno, ...) - can be interrupted or killed as a unit.
///
/// Output is delivered line by line on a background queue.
final class ProcessRunner: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    let executable: String
    let arguments: [String]
    let environment: [String: String]

    /// Called for every complete output line (background thread).
    var onLine: ((String, Stream) -> Void)?
    /// Called once when the process has exited and all output was delivered (background thread).
    var onExit: ((Int32) -> Void)?

    private(set) var pid: pid_t = 0
    private let lock = NSLock()
    private var exited = false
    private var pendingReaders = 2
    private var exitStatus: Int32 = 0
    private var exitReported = false

    init(executable: String, arguments: [String], environment: [String: String] = ProcessRunner.defaultEnvironment()) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    static func defaultEnvironment(extraPath: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let base = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extraPath + base).joined(separator: ":")
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["NO_COLOR"] = "1"
        // Static FFmpeg builds use OpenSSL, which doesn't know where macOS keeps its CA certificates.
        if env["SSL_CERT_FILE"] == nil, let bundle = ToolManager.certificateBundle {
            env["SSL_CERT_FILE"] = bundle
        }
        if env["SSL_CERT_DIR"] == nil, FileManager.default.fileExists(atPath: "/etc/ssl/certs") {
            env["SSL_CERT_DIR"] = "/etc/ssl/certs"
        }
        return env
    }

    func start() throws {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw RunnerError.spawnFailed(errno)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group (pgid == pid), only the descriptors above are inherited.
        let flags = Int32(POSIX_SPAWN_SETPGROUP) | Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
            | Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for sig in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaultSignals, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let argv = CStringArray([executable] + arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, executable, &fileActions, &attributes, argv.pointers, envp.pointers)
        close(outPipe[1])
        close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw RunnerError.spawnFailed(rc)
        }
        pid = childPID

        startReader(fd: outPipe[0], stream: .stdout)
        startReader(fd: errPipe[0], stream: .stderr)

        let waitPID = childPID
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(waitPID, &status, 0) == -1 && errno == EINTR {}
            let code: Int32
            if (status & 0x7f) == 0 { // WIFEXITED
                code = (status >> 8) & 0xff
            } else {                  // signalled
                code = 128 + (status & 0x7f)
            }
            self?.markExited(code)
        }
    }

    private func startReader(fd: Int32, stream: Stream) {
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            let chunkSize = 64 * 1024
            let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 1)
            defer { chunk.deallocate() }
            while true {
                let n = read(fd, chunk, chunkSize)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                buffer.append(chunk.assumingMemoryBound(to: UInt8.self), count: n)
                while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = buffer[buffer.startIndex..<idx]
                    buffer.removeSubrange(buffer.startIndex...idx)
                    if lineData.isEmpty { continue }
                    self?.onLine?(String(decoding: lineData, as: UTF8.self), stream)
                }
            }
            if !buffer.isEmpty {
                self?.onLine?(String(decoding: buffer, as: UTF8.self), stream)
            }
            close(fd)
            self?.readerFinished()
        }
    }

    private func readerFinished() {
        lock.lock()
        pendingReaders -= 1
        lock.unlock()
        reportExitIfDone()
    }

    private func markExited(_ status: Int32) {
        lock.lock()
        exited = true
        exitStatus = status
        lock.unlock()
        reportExitIfDone()
        // Helpers that inherited the pipes could keep the readers alive; give them a moment.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.forceReportExit()
        }
    }

    private func reportExitIfDone() {
        lock.lock()
        let done = exited && pendingReaders <= 0 && !exitReported
        if done { exitReported = true }
        let status = exitStatus
        lock.unlock()
        if done { onExit?(status) }
    }

    private func forceReportExit() {
        lock.lock()
        let shouldReport = !exitReported
        exitReported = true
        let status = exitStatus
        lock.unlock()
        if shouldReport { onExit?(status) }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return pid != 0 && !exited
    }

    /// Sends a signal to the whole process group.
    func signal(_ sig: Int32) {
        guard pid > 0 else { return }
        if killpg(pid, sig) != 0 {
            kill(pid, sig)
        }
    }

    /// Graceful stop: SIGINT (lets yt-dlp keep partial files), then SIGTERM, then SIGKILL.
    func stop() {
        guard isRunning else { return }
        signal(SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.isRunning else { return }
            self.signal(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.isRunning else { return }
                self.signal(SIGKILL)
            }
        }
    }

    enum RunnerError: LocalizedError {
        case spawnFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .spawnFailed(let code):
                return String(localized: "Could not start process: \(String(cString: strerror(code)))")
            }
        }
    }
}

extension ProcessRunner {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    /// Runs a process to completion and collects its output.
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String] = ProcessRunner.defaultEnvironment(),
                    timeout: TimeInterval = 120) async -> Result {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let runner = ProcessRunner(executable: executable, arguments: arguments, environment: environment)
            let collector = OutputCollector()
            runner.onLine = { line, stream in collector.append(line, stream) }
            // The closure keeps the runner alive until the process has exited; the cycle is broken below.
            runner.onExit = { status in
                let (out, err, timedOut) = collector.snapshot()
                collector.finish {
                    continuation.resume(returning: Result(status: status, stdout: out, stderr: err, timedOut: timedOut))
                }
                runner.onExit = nil
            }
            do {
                try runner.start()
            } catch {
                collector.finish {
                    continuation.resume(returning: Result(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false))
                }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if runner.isRunning {
                    collector.markTimedOut()
                    runner.signal(SIGKILL)
                }
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var out: [String] = []
        private var err: [String] = []
        private var timedOut = false
        private var finished = false

        func append(_ line: String, _ stream: Stream) {
            lock.lock(); defer { lock.unlock() }
            if stream == .stdout { out.append(line) } else { err.append(line) }
        }
        func markTimedOut() {
            lock.lock(); timedOut = true; lock.unlock()
        }
        func snapshot() -> (String, String, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (out.joined(separator: "\n"), err.joined(separator: "\n"), timedOut)
        }
        /// Ensures the continuation is resumed exactly once.
        func finish(_ body: () -> Void) {
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            if first { body() }
        }
    }
}

/// NULL-terminated C string array for posix_spawn.
private final class CStringArray {
    let pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { strdup($0) } + [nil]
    }

    deinit {
        for pointer in pointers { free(pointer) }
    }
}

import Foundation

/// Where Grab's command-line tools live, and how to run them.
@MainActor
enum Tools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    // MARK: - Locating tools

    static var ytdlp: URL? {
        let defaults = UserDefaults.standard
        let custom = defaults.string(forKey: Prefs.ytdlpPath) ?? ""
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if defaults.bool(forKey: Prefs.autoUpdate), Updater.isInstalled {
            return Updater.binaryURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in searchPaths + ["\(home)/.local/bin"] {
            let path = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Grab's own tools come first when auto-update is on, then the usual install locations.
    static var directories: [String] {
        (UserDefaults.standard.bool(forKey: Prefs.autoUpdate) ? [Updater.directory.path] : []) + searchPaths
    }

    /// The full path of ffmpeg, ffprobe… if it's installed.
    static func path(_ name: String) -> String? {
        directories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// yt-dlp needs ffmpeg to merge video and audio and to convert audio.
    static var ffmpegMissing: Bool { path("ffmpeg") == nil }

    /// Apps launched from Finder get a minimal PATH, so add the usual places ffmpeg lives.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (directories + [existing]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        // Grab's static ffmpeg doesn't use the macOS keychain for HTTPS certificates; without a
        // bundle it can't fetch anything itself (clips, some streams). Use the system's.
        if env["SSL_CERT_FILE"] == nil, FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") {
            env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
        return env
    }

    // MARK: - Running tools

    struct Output {
        var status: Int32
        var stdout: Data
        /// The process ran past its timeout and was stopped.
        var timedOut = false
    }

    /// Collects a process's output and exit without blocking a thread: the pipe is read as data
    /// arrives, and the result is delivered once the process has exited and the pipe has closed.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var pending = 2
        private var status: Int32 = 0
        private var timedOut = false
        var finish: ((Output) -> Void)?

        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }

        func part(done status: Int32? = nil) {
            lock.lock()
            if let status { self.status = status }
            pending -= 1
            let result = pending == 0 ? Output(status: self.status, stdout: data, timedOut: timedOut) : nil
            lock.unlock()
            if let result { finish?(result) }
        }
    }

    /// Runs a tool to completion and returns its exit status and standard output (standard error
    /// is discarded), or nil if it couldn't be started. `onStart` gets the running process, so
    /// the caller can cancel it; `timeout` stops a process that runs too long.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    onStart: ((Process) -> Void)? = nil, timeout: Duration? = nil) async -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let collector = Collector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collector.part()
            } else {
                collector.append(chunk)
            }
        }
        process.terminationHandler = { collector.part(done: $0.terminationStatus) }
        var timer: Task<Void, Never>?
        return await withCheckedContinuation { continuation in
            collector.finish = { timer?.cancel(); continuation.resume(returning: $0) }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: nil)
                return
            }
            onStart?(process)
            if let timeout {
                timer = Task {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning {
                        collector.markTimedOut()
                        process.terminate()
                    }
                }
            }
        }
    }

    /// A way to wait for a process's exit status, without blocking. Call before `run()`.
    static func exitStatus(of process: Process) -> @Sendable () async -> Int32 {
        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        return { await stream.first { _ in true } ?? -1 }
    }
}

/// Lines from a pipe as they arrive. This deliberately avoids `FileHandle.bytes`: two of those
/// reading at once (yt-dlp's stdout and stderr) block each other, so progress only reached the
/// app when yt-dlp exited. `readabilityHandler` reads each pipe independently.
enum PipeLines {
    private final class Buffer: @unchecked Sendable { var data = Data() }

    static func stream(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = Buffer()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    if !buffer.data.isEmpty { continuation.yield(String(decoding: buffer.data, as: UTF8.self)) }
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.data.append(chunk)
                while let newline = buffer.data.firstIndex(of: 0x0A) {
                    var line = buffer.data[buffer.data.startIndex..<newline]
                    if line.last == 0x0D { line = line.dropLast() }
                    continuation.yield(String(decoding: line, as: UTF8.self))
                    buffer.data.removeSubrange(buffer.data.startIndex...newline)
                }
            }
        }
    }
}

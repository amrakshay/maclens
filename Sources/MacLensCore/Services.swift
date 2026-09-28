import Foundation

/// Optional third-party services MacLens can start and stop on demand ("Additional Services" tab).
/// Everything runs as the user through the service's own CLI; nothing needs root.
public enum ServiceState: Equatable, Sendable {
    case notInstalled
    case stopped
    /// Listening on its port. `pid` is the listening process.
    case running(pid: Int32)
    /// Something that is not this service holds its port.
    case portInUse(pid: Int32, name: String)

    public var isRunning: Bool { if case .running = self { return true }; return false }
}

public struct ServiceActionResult: Sendable {
    public let ok: Bool
    /// The CLI's own message (stdout + stderr), trimmed.
    public let output: String
}

/// VoiceMode (https://github.com/mbailey/voicemode): local Whisper STT and Kokoro TTS servers, managed with
/// `voicemode service start|stop|enable|disable <name>`.
/// Status is derived from listening sockets, not from `voicemode service status`, which takes ~3 s and ~1.3 s of CPU per call.
public enum VoiceMode {
    public struct Component: Identifiable, Hashable, Sendable {
        /// Name the CLI takes (`voicemode service start <id>`).
        public let id: String
        public let title: String
        public let summary: String
        public let port: Int
        /// Any of these existing means the component is installed (paths relative to home).
        let installMarkers: [String]
        /// launchd label suffix: `enable` writes ~/Library/LaunchAgents/com.voicemode.<plistName>.plist.
        let plistName: String
    }

    public static let components: [Component] = [
        Component(id: "whisper", title: "Whisper", summary: "Speech-to-text", port: 2022,
                  installMarkers: [".voicemode/services/whisper"], plistName: "whisper"),
        Component(id: "kokoro", title: "Kokoro", summary: "Text-to-speech", port: 8880,
                  installMarkers: [".voicemode/services/kokoro", ".voicemode/kokoro-fastapi"], plistName: "kokoro"),
        Component(id: "mlx-audio", title: "MLX-Audio", summary: "Unified STT + TTS for Apple Silicon", port: 8890,
                  installMarkers: [".local/bin/mlx_audio.server"], plistName: "mlx-audio"),
    ]

    /// Where `uv tool install voice-mode` and pipx put the CLI. GUI apps don't inherit the shell's PATH, so look explicitly.
    public static func locate(home: String = PathUtil.home, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        var dirs = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in (path ?? "").split(separator: ":").map(String.init) where !dirs.contains(d) { dirs.append(d) }
        return dirs.map { $0 + "/voicemode" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func isInstalled(_ c: Component, home: String = PathUtil.home) -> Bool {
        c.installMarkers.contains { FileManager.default.fileExists(atPath: home + "/" + $0) }
    }

    public static func plistPath(_ c: Component, home: String = PathUtil.home) -> String {
        home + "/Library/LaunchAgents/com.voicemode.\(c.plistName).plist"
    }

    /// `voicemode service enable` installs a LaunchAgent, which launchd starts at every login.
    public static func startsAtLogin(_ c: Component, home: String = PathUtil.home) -> Bool {
        FileManager.default.fileExists(atPath: plistPath(c, home: home))
    }

    /// State from listening sockets. A listener counts as ours only if its command line points into ~/.voicemode or
    /// names the service, so an unrelated server on 8880 shows as "port in use" instead of "running".
    public static func state(of c: Component, installed: Bool, listeners: [PortEntry],
                             arguments: (Int32) -> [String]?, name: (Int32) -> String) -> ServiceState {
        guard let owner = listeners.first(where: { $0.port == c.port && $0.proto == "TCP" }) else {
            return installed ? .stopped : .notInstalled
        }
        let cmd = (arguments(owner.pid) ?? []).joined(separator: " ")
        let markers = [".voicemode", "whisper-server", "mlx_audio", "api.src.main:app"]
        if markers.contains(where: cmd.contains) { return .running(pid: owner.pid) }
        return .portInUse(pid: owner.pid, name: name(owner.pid))
    }

    public enum Action: String, Sendable { case start, stop, enable, disable }

    /// Runs `voicemode service <action> <component>`. Blocks (start waits for the server, up to ~5 s); call off the main thread.
    public static func run(_ action: Action, _ c: Component, executable: String, timeout: TimeInterval = 90) -> ServiceActionResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["service", action.rawValue, c.id]
        var env = ProcessInfo.processInfo.environment
        // The start scripts call uv, bash and friends: give them the PATH a login shell would have.
        let dir = PathUtil.parent(executable)
        env["PATH"] = [dir, PathUtil.home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: PathUtil.home)
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return ServiceActionResult(ok: false, output: "Could not run \(executable): \(error.localizedDescription)") }
        let deadline = DispatchTime.now() + timeout
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: deadline)
        timer.setEventHandler { if p.isRunning { p.terminate() } }
        timer.resume()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ServiceActionResult(ok: p.terminationStatus == 0 && !looksFailed(text), output: text)
    }

    /// The CLI exits 0 even when it fails, and reports the outcome with ❌ / ⚠️ (e.g. "❌ Failed to start kokoro: …").
    public static func looksFailed(_ output: String) -> Bool {
        output.contains("❌") || output.lowercased().hasPrefix("error")
    }
}

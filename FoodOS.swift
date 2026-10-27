// foodOS — say what you ate, anywhere; get a meal entry in your Obsidian calorie counter.
//
// Option+Shift+F → ● record → Option+Shift+F → transcribe locally (whisper.cpp)
// → estimate nutrition with a coding agent (claude -p, JSON out)
// → write <vault>/<folder>/Meals/<date> <time> <title>.md
//
// Sibling of noteOS (⌥⇧N), everywhisper (⌥⇧W), and optionai (⌥A+I). Same
// skeleton: one Swift file, a menu-bar item, a LaunchAgent. Like noteOS, it
// never pastes and never taps the keyboard. Microphone is the only permission.
//
// The agent estimates each item. Swift sums the totals, so the totals are
// always the exact sum of the rows. The agent never does the arithmetic.
//
// Failure is never data loss: a pending meal note with the raw transcript is
// written BEFORE the agent runs. If claude fails, the pending note stays and
// shows up in the "Pending" view of the base.
//
// Build:   ./build.sh
// Install: ./install.sh

import AppKit
import AVFoundation
import Carbon
import Foundation
import WebKit

// MARK: - Config

struct Config {
    var whisperBinary: String
    var modelPath: String
    var language: String
    var threads: Int
    var claudeBinary: String
    var claudeModel: String?
    var timeoutSeconds: Double
    var mealsDir: URL
    var profileURL: URL
    var baseURL: URL
    var orbDir: URL?

    /// ~/.config/foodos/config holds KEY=VALUE lines (written by install.sh).
    /// Process environment wins over the file.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/foodos/config")

    static func load() throws -> Config {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var env = readConfigFile()
        env.merge(ProcessInfo.processInfo.environment) { _, process in process }

        let whisper =
            env["WHISPER_CLI"]
            ?? which("whisper-cli")
            ?? "/opt/homebrew/bin/whisper-cli"

        let model =
            env["WHISPER_MODEL"]
            ?? firstExisting([
                "\(home.path)/models/whisper/ggml-base.en.bin",
                "\(home.path)/.cache/whisper/ggml-base.en.bin",
                "/opt/homebrew/share/whisper-cpp/ggml-base.en.bin",
            ])
            ?? "\(home.path)/models/whisper/ggml-base.en.bin"

        let claude =
            env["CLAUDE_CLI"]
            ?? which("claude")
            ?? firstExisting([
                "\(home.path)/.local/bin/claude",
                "\(home.path)/.claude/local/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ])
            ?? "claude"

        // The nutrition folder inside the vault. Meals, the profile, and the
        // base all live here. There is no default vault: fail loud instead.
        guard let vault = env["FOODOS_VAULT"], !vault.isEmpty else {
            throw NSError(
                domain: "foodos", code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "FOODOS_VAULT is not set. Run ./install.sh, or add FOODOS_VAULT=/path/to/vault to \(fileURL.path)."
                ]
            )
        }
        let folder = env["FOODOS_FOLDER"].flatMap { $0.isEmpty ? nil : $0 } ?? "Nutrition"
        let nutritionDir = URL(fileURLWithPath: (vault as NSString).expandingTildeInPath)
            .appendingPathComponent(folder)

        let orbDir =
            env["FOODOS_ORB_DIR"].map { URL(fileURLWithPath: $0) }
            ?? firstExisting([
                "\(home.path)/.local/share/foodos/orb",
            ]).map { URL(fileURLWithPath: $0) }

        // Empty env values (e.g. an unset plist key) mean "not set".
        let claudeModel = env["FOODOS_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Config(
            whisperBinary: whisper,
            modelPath: model,
            language: env["WHISPER_LANGUAGE"] ?? "en",
            threads: Int(env["WHISPER_THREADS"] ?? "")
                ?? max(2, ProcessInfo.processInfo.processorCount / 2),
            claudeBinary: claude,
            claudeModel: (claudeModel?.isEmpty == false) ? claudeModel : "sonnet",
            timeoutSeconds: Double(env["FOODOS_TIMEOUT"] ?? "") ?? 120,
            mealsDir: nutritionDir.appendingPathComponent("Meals"),
            profileURL: nutritionDir.appendingPathComponent("Food profile.md"),
            baseURL: nutritionDir.appendingPathComponent("Calorie Counter.base"),
            orbDir: orbDir
        )
    }

    private static func readConfigFile() -> [String: String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            out[String(t[..<eq])] = String(t[t.index(after: eq)...])
        }
        return out
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func which(_ cmd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Recorder + Whisper (from noteOS)

final class Recorder {
    private let config: Config
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private(set) var isRecording = false

    init(config: Config) {
        self.config = config
    }

    /// Start capturing 16 kHz mono WAV. Returns false when the mic is denied
    /// or the recorder cannot start.
    func start() -> Bool {
        guard requestMicAccessSync() else {
            fputs(
                "foodos: microphone denied. Enable it in System Settings → Privacy & Security → Microphone.\n",
                stderr
            )
            return false
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foodos-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else { return false }
            recorder = rec
            recordingURL = url
            isRecording = true
            return true
        } catch {
            fputs("foodos: recording failed: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    /// Stop and return the WAV file for transcription.
    func stop() -> URL? {
        guard let rec = recorder, let url = recordingURL else { return nil }
        rec.stop()
        recorder = nil
        recordingURL = nil
        isRecording = false
        return url
    }

    func transcribe(wav: URL) throws -> String {
        defer {
            try? FileManager.default.removeItem(at: wav)
            let txt = wav.deletingPathExtension().appendingPathExtension("txt")
            try? FileManager.default.removeItem(at: txt)
        }

        guard FileManager.default.fileExists(atPath: config.whisperBinary) else {
            throw err("whisper-cli not found at \(config.whisperBinary). Install whisper.cpp or set WHISPER_CLI.")
        }
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw err("Model not found at \(config.modelPath). Set WHISPER_MODEL to a ggml model file.")
        }

        let outBase = wav.deletingPathExtension().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperBinary)
        process.arguments = [
            "-m", config.modelPath,
            "-f", wav.path,
            "-l", config.language,
            "-t", String(config.threads),
            "-otxt",
            "-of", outBase,
            "-np",
        ]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            throw err("whisper-cli exited \(process.terminationStatus): \(errText)")
        }

        let raw = try String(
            contentsOf: URL(fileURLWithPath: outBase + ".txt"), encoding: .utf8
        )
        return raw
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func requestMicAccessSync() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 60)
            return granted
        default:
            return false
        }
    }

    private func err(_ message: String) -> NSError {
        NSError(
            domain: "foodos", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

// MARK: - Agent (claude -p, from noteOS)

final class AgentEngine {
    private let config: Config
    private var process: Process?
    private var generation = 0
    private(set) var isBusy = false

    init(config: Config) {
        self.config = config
    }

    static let instruction = """
        You are foodOS, a nutrition-logging agent. The input on stdin is a raw \
        voice-dictation transcript, captured with local speech-to-text, in \
        which the user says what they ate or drank. Estimate the nutrition of \
        each item and reply with ONE JSON object and nothing else: no prose, \
        no code fence.

        Shape:
        {"meals": [{
          "title": "2-6 word name of the meal",
          "date": "YYYY-MM-DD",
          "time": "HH:MM (24-hour)",
          "meal": "breakfast" | "lunch" | "dinner" | "snack" | "drink",
          "confidence": "high" | "medium" | "low",
          "items": [{"name": "...", "amount": "portion in plain words",
                     "calories": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0,
                     "fiber_g": 0, "sugar_g": 0, "sat_fat_g": 0, "sodium_mg": 0}],
          "assumptions": ["each portion or recipe you had to guess"]
        }]}

        Rules:
        - Every nutrient field is a plain number, never null, never a string. \
        Round calories and sodium to whole numbers, grams to one decimal.
        - Use typical USDA FoodData Central values. For branded or restaurant \
        items, use the chain's published values when you know them.
        - The user's food profile below overrides your defaults. When the user \
        names a food that the profile defines, use the profile's portion and \
        values exactly.
        - When the user gives no portion, assume a typical adult portion, \
        scaled to the person the profile describes, and record the guess in \
        assumptions.
        - Resolve relative times ("this morning", "last night", "yesterday at \
        lunch") against the current time below. With no time stated, use the \
        current time. With no meal stated, infer it from the time of day.
        - Make one entry in "meals" per distinct eating occasion. A single \
        dictation about one meal gives exactly one entry.
        - Fix obvious speech-to-text errors in food names.
        - confidence is "high" when portions are stated or come from the \
        profile, "medium" when you had to guess typical portions, and "low" \
        when the description is vague.
        - If the transcript names no food or drink at all, reply {"meals": []}.
        """

    func run(
        transcript: String,
        context: String,
        onDone: @escaping (Result<String, Error>) -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        generation += 1
        let gen = generation

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.claudeBinary)
        var args = ["-p", Self.instruction + "\n\n" + context, "--output-format", "text"]
        if let model = config.claudeModel {
            args += ["--model", model]
        }
        p.arguments = args
        // Neutral cwd so no project CLAUDE.md leaks into the context.
        p.currentDirectoryURL = FileManager.default.temporaryDirectory

        var env = ProcessInfo.processInfo.environment
        let basePATH = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePATH
        p.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderrPipe

        do {
            try p.run()
        } catch {
            isBusy = false
            onDone(.failure(error))
            return
        }
        process = p

        if let data = transcript.data(using: .utf8) {
            stdin.fileHandleForWriting.write(data)
        }
        try? stdin.fileHandleForWriting.close()

        let timeout = config.timeoutSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.generation == gen, p.isRunning else { return }
            p.terminate()
            fputs("foodos: agent timed out after \(Int(timeout))s\n", stderr)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()

            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.isBusy = false
                self.process = nil

                let status = p.terminationStatus
                let text = String(data: outData, encoding: .utf8) ?? ""
                let errText = String(data: errData, encoding: .utf8) ?? ""

                guard status == 0 else {
                    onDone(
                        .failure(
                            NSError(
                                domain: "foodos", code: Int(status),
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "claude exited \(status): \(errText)"
                                ]
                            )
                        )
                    )
                    return
                }
                onDone(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        generation += 1
        process?.terminate()
        process = nil
        isBusy = false
    }
}

// MARK: - Meal model (the agent's JSON reply)

struct AgentReply: Decodable {
    let meals: [Meal]
}

struct Meal: Decodable {
    let title: String
    let date: String
    let time: String
    let meal: String
    let confidence: String
    let items: [Item]
    let assumptions: [String]?
}

struct Item: Decodable {
    let name: String
    let amount: String?
    let calories: Double
    let protein_g: Double
    let carbs_g: Double
    let fat_g: Double
    let fiber_g: Double
    let sugar_g: Double
    let sat_fat_g: Double
    let sodium_mg: Double
}

/// One nutrient: its frontmatter key, its table label, and its digits.
struct Nutrient {
    let key: String
    let label: String
    let digits: Int
    let value: (Item) -> Double

    static let all: [Nutrient] = [
        Nutrient(key: "calories", label: "kcal", digits: 0) { $0.calories },
        Nutrient(key: "protein_g", label: "Protein g", digits: 1) { $0.protein_g },
        Nutrient(key: "carbs_g", label: "Carbs g", digits: 1) { $0.carbs_g },
        Nutrient(key: "fat_g", label: "Fat g", digits: 1) { $0.fat_g },
        Nutrient(key: "fiber_g", label: "Fiber g", digits: 1) { $0.fiber_g },
        Nutrient(key: "sugar_g", label: "Sugar g", digits: 1) { $0.sugar_g },
        Nutrient(key: "sat_fat_g", label: "Sat fat g", digits: 1) { $0.sat_fat_g },
        Nutrient(key: "sodium_mg", label: "Sodium mg", digits: 0) { $0.sodium_mg },
    ]

    func format(_ x: Double) -> String {
        digits == 0 ? String(Int(x.rounded())) : String(format: "%.\(digits)f", x)
    }
}

extension Meal {
    func total(_ n: Nutrient) -> Double {
        items.reduce(0) { $0 + n.value($1) }
    }
}

enum ReplyParser {
    /// Pull the JSON object out of the agent's text and decode it. Throws a
    /// readable error, so a bad reply is loud in the log.
    static func parse(_ text: String) throws -> [Meal] {
        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            start < end
        else {
            throw err("agent reply has no JSON object: \(text.prefix(200))")
        }
        let json = Data(text[start...end].utf8)
        let reply = try JSONDecoder().decode(AgentReply.self, from: json)

        let mealKinds: Set = ["breakfast", "lunch", "dinner", "snack", "drink"]
        for m in reply.meals {
            guard isDate(m.date) else { throw err("bad date \"\(m.date)\" in \"\(m.title)\"") }
            guard isTime(m.time) else { throw err("bad time \"\(m.time)\" in \"\(m.title)\"") }
            guard mealKinds.contains(m.meal) else { throw err("bad meal \"\(m.meal)\" in \"\(m.title)\"") }
            guard !m.items.isEmpty else { throw err("meal \"\(m.title)\" has no items") }
        }
        return reply.meals
    }

    private static func isDate(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isTime(_ s: String) -> Bool {
        s.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "foodos", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Meal store (<vault>/<folder>/Meals)

enum MealStore {

    /// Write a pending meal note with the raw transcript, before the agent
    /// runs. The base lists it under "Pending" until the agent finishes.
    static func writePending(transcript: String, in dir: URL, now: Date = Date())
        throws -> URL
    {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent(
            "\(stamp(now, "yyyy-MM-dd HHmmss")) pending.md"
        )
        let body = """
            ---
            type: meal
            status: pending
            date: \(stamp(now, "yyyy-MM-dd"))
            time: "\(stamp(now, "HH:mm"))"
            logged: \(stamp(now, "yyyy-MM-dd'T'HH:mm:ssZZZZZ"))
            source: foodos
            ---

            # Pending meal

            > \(transcript)

            The agent did not finish. Log it again, or fill in the numbers by hand.
            """
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Replace the pending note with the first meal, and write any further
    /// meals as new notes. Returns the final paths.
    static func finalize(
        meals: [Meal], transcript: String, pendingURL: URL, now: Date = Date()
    ) throws -> [URL] {
        let dir = pendingURL.deletingLastPathComponent()
        let logged = stamp(now, "yyyy-MM-dd'T'HH:mm:ssZZZZZ")
        var written: [URL] = []

        for m in meals {
            let text = render(m, transcript: transcript, logged: logged)
            let dest = uniqueURL(
                in: dir,
                base: "\(m.date) \(m.time.replacingOccurrences(of: ":", with: "")) \(safeTitle(m.title))"
            )
            try text.write(to: dest, atomically: true, encoding: .utf8)
            written.append(dest)
        }
        try FileManager.default.removeItem(at: pendingURL)
        return written
    }

    static func render(_ m: Meal, transcript: String, logged: String) -> String {
        var fm = [
            "---",
            "type: meal",
            "status: logged",
            "date: \(m.date)",
            "time: \"\(m.time)\"",
            "meal: \(m.meal)",
        ]
        for n in Nutrient.all {
            fm.append("\(n.key): \(n.format(m.total(n)))")
        }
        fm += [
            "items: \(m.items.count)",
            "confidence: \(m.confidence)",
            "logged: \(logged)",
            "source: foodos",
            "---",
        ]

        let shown = Nutrient.all.prefix(5)  // kcal, protein, carbs, fat, fiber
        var table = [
            "| Item | Amount | " + shown.map(\.label).joined(separator: " | ") + " |",
            "| --- | --- | " + shown.map { _ in "--:" }.joined(separator: " | ") + " |",
        ]
        for item in m.items {
            let cells = shown.map { $0.format($0.value(item)) }
            table.append(
                "| \(cell(item.name)) | \(cell(item.amount ?? "")) | "
                    + cells.joined(separator: " | ") + " |"
            )
        }
        table.append(
            "| **Total** | | "
                + shown.map { "**\($0.format(m.total($0)))**" }.joined(separator: " | ")
                + " |"
        )

        let extra = Nutrient.all.dropFirst(5)
            .map { "\($0.label): \($0.format(m.total($0)))" }
            .joined(separator: " · ")

        var body = fm.joined(separator: "\n") + "\n\n# \(m.title)\n\n"
        body += table.joined(separator: "\n") + "\n\n" + extra + "\n"
        if let a = m.assumptions, !a.isEmpty {
            body += "\n## Assumptions\n\n" + a.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        body += "\n## What I said\n\n> \(transcript)\n"
        return body
    }

    private static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// A filename-safe title. Strip characters Obsidian or the filesystem
    /// rejects in names.
    static func safeTitle(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        var t = title
            .components(separatedBy: forbidden)
            .joined()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if t.count > 60 {
            t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return t.isEmpty ? "Meal" : t
    }

    private static func uniqueURL(in dir: URL, base: String) -> URL {
        var url = dir.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        return url
    }

    static func stamp(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}

// MARK: - Orb spinner (thinking-orbs, via WKWebView; from noteOS)

final class OrbPanel {
    private var panel: NSPanel?
    private var followTimer: Timer?
    private let orbDir: URL?
    private let size: CGFloat = 64

    init(orbDir: URL?) {
        self.orbDir = orbDir
    }

    private func origin(for anchor: NSPoint) -> NSPoint {
        var origin = NSPoint(x: anchor.x + 14, y: anchor.y - size - 6)
        if let screen = NSScreen.screens.first(where: {
            $0.frame.contains(anchor)
        }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX), f.maxX - size)
            origin.y = min(max(origin.y, f.minY), f.maxY - size)
        }
        return origin
    }

    /// Show the orb near the pointer. `state` picks the thinking-orbs mode:
    /// "listening" (wave) while recording, "composing" (ribbon) while the
    /// agent estimates the meal. The state rides on the URL fragment.
    func show(state: String) {
        guard let orbDir else { return }
        let html = orbDir.appendingPathComponent("orb.html")
        guard FileManager.default.fileExists(atPath: html.path) else { return }
        guard let url = URL(string: html.absoluteString + "#" + state) else { return }

        hide()

        let origin = origin(for: NSEvent.mouseLocation)
        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: size, height: size)
        )
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        webView.loadFileURL(url, allowingReadAccessTo: orbDir)
        p.contentView = webView

        p.orderFrontRegardless()
        panel = p

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            panel.setFrameOrigin(self.origin(for: NSEvent.mouseLocation))
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    func hide() {
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

// MARK: - Headless mode (test the pipeline without the mic)
//
//   foodos --log "two eggs and toast for breakfast"
//
// Runs the agent and writes the meal notes, then exits. Same path as the
// hotkey, minus recording and transcription.

func agentContext(config: Config, now: Date = Date()) -> String {
    let profile = (try? String(contentsOf: config.profileURL, encoding: .utf8))
        ?? "(no food profile yet)"
    return """
        Current local time: \(MealStore.stamp(now, "EEEE yyyy-MM-dd HH:mm ZZZZZ"))

        <food_profile>
        \(profile)
        </food_profile>
        """
}

func loadConfigOrExit() -> Config {
    do {
        return try Config.load()
    } catch {
        fputs("foodos: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func runHeadless(transcript: String) -> Int32 {
    let config = loadConfigOrExit()
    let agent = AgentEngine(config: config)
    var code: Int32 = 0
    let pending: URL
    do {
        pending = try MealStore.writePending(transcript: transcript, in: config.mealsDir)
    } catch {
        fputs("foodos: could not write pending note: \(error.localizedDescription)\n", stderr)
        return 1
    }
    agent.run(transcript: transcript, context: agentContext(config: config)) { result in
        code = finish(result: result, transcript: transcript, pendingURL: pending) ? 0 : 1
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return code
}

/// Shared tail of both modes: parse the reply and write the notes. Returns
/// true on success. On any failure the pending note stays on disk.
func finish(result: Result<String, Error>, transcript: String, pendingURL: URL) -> Bool {
    switch result {
    case .failure(let error):
        fputs("foodos: agent failed — pending note kept at \(pendingURL.path): \(error.localizedDescription)\n", stderr)
        return false
    case .success(let text):
        do {
            let meals = try ReplyParser.parse(text)
            guard !meals.isEmpty else {
                try? FileManager.default.removeItem(at: pendingURL)
                fputs("foodos: no food found in transcript — nothing logged\n", stderr)
                return false
            }
            let urls = try MealStore.finalize(
                meals: meals, transcript: transcript, pendingURL: pendingURL
            )
            for (m, url) in zip(meals, urls) {
                fputs(
                    "foodos: logged \(Int(m.total(Nutrient.all[0]).rounded())) kcal → \(url.path)\n",
                    stderr
                )
            }
            return true
        } catch {
            fputs("foodos: bad agent reply — pending note kept at \(pendingURL.path): \(error)\n", stderr)
            return false
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State {
        case idle, recording, transcribing, composing
    }

    private var config: Config!
    private var recorder: Recorder!
    private var agent: AgentEngine!
    private var orb: OrbPanel!
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var state: State = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = loadConfigOrExit()
        recorder = Recorder(config: config)
        agent = AgentEngine(config: config)
        orb = OrbPanel(orbDir: config.orbDir)

        fputs(
            """
            foodos ready
              hotkey:  Option+Shift+F  (record → stop+log; press while logging to cancel)
              whisper: \(config.whisperBinary)
              model:   \(config.modelPath)
              claude:  \(config.claudeBinary)
              agent:   \(config.claudeModel ?? "sonnet")
              meals:   \(config.mealsDir.path)
              profile: \(config.profileURL.path)
              orb:     \(config.orbDir?.path ?? "(none — menu-bar indicator only)")

            """,
            stderr
        )

        setupStatusItem()
        registerHotkey()
        updateStatus()
    }

    // MARK: flow

    private func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndLog()
        case .transcribing:
            // Local transcription takes a moment; there is nothing to cancel
            // that would not lose the recording.
            NSSound.beep()
        case .composing:
            // Cancel the agent; the pending note stays on disk.
            agent.cancel()
            state = .idle
            orb.hide()
            updateStatus()
            NSSound(named: .init("Pop"))?.play()
            fputs("foodos: canceled — pending note kept\n", stderr)
        }
    }

    private func startRecording() {
        guard recorder.start() else {
            NSSound.beep()
            return
        }
        state = .recording
        orb.show(state: "listening")
        updateStatus()
        NSSound(named: .init("Tink"))?.play()
        fputs("● Recording… (Option+Shift+F to stop)\n", stderr)
    }

    private func stopAndLog() {
        guard let wav = recorder.stop() else {
            state = .idle
            orb.hide()
            updateStatus()
            return
        }
        state = .transcribing
        orb.show(state: "composing")
        updateStatus()
        NSSound(named: .init("Pop"))?.play()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let transcript: String
            do {
                transcript = try self.recorder.transcribe(wav: wav)
            } catch {
                DispatchQueue.main.async {
                    self.fail("whisper failed: \(error.localizedDescription)")
                }
                return
            }

            DispatchQueue.main.async {
                guard !transcript.isEmpty else {
                    self.fail("no speech detected")
                    return
                }
                fputs("→ \(transcript)\n", stderr)
                self.logMeal(transcript: transcript)
            }
        }
    }

    private func logMeal(transcript: String) {
        let pendingURL: URL
        do {
            pendingURL = try MealStore.writePending(
                transcript: transcript, in: config.mealsDir
            )
        } catch {
            fail("could not write pending note: \(error.localizedDescription)")
            return
        }

        state = .composing
        updateStatus()

        agent.run(transcript: transcript, context: agentContext(config: config)) {
            [weak self] result in
            guard let self else { return }
            self.orb.hide()
            self.state = .idle
            self.updateStatus()
            let ok = finish(result: result, transcript: transcript, pendingURL: pendingURL)
            NSSound(named: .init(ok ? "Glass" : "Basso"))?.play()
        }
    }

    private func fail(_ message: String) {
        state = .idle
        orb.hide()
        updateStatus()
        NSSound.beep()
        fputs("foodos: \(message)\n", stderr)
    }

    // MARK: status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "F"
            button.toolTip = "foodos — Option+Shift+F"
        }
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Log a Meal (⌥⇧F)",
                action: #selector(toggleFromMenu),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Open Calorie Counter",
                action: #selector(openBase),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func updateStatus() {
        switch state {
        case .recording:
            statusItem?.button?.title = "●"
            statusItem?.button?.toolTip = "foodos — recording (⌥⇧F to stop)"
        case .transcribing:
            statusItem?.button?.title = "…"
            statusItem?.button?.toolTip = "foodos — transcribing"
        case .composing:
            statusItem?.button?.title = "◍"
            statusItem?.button?.toolTip = "foodos — estimating (⌥⇧F to cancel)"
        case .idle:
            statusItem?.button?.title = "F"
            statusItem?.button?.toolTip = "foodos — Option+Shift+F"
        }
    }

    @objc private func toggleFromMenu() {
        toggle()
    }

    @objc private func openBase() {
        NSWorkspace.shared.open(config.baseURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: hotkey — Option+Shift+F (Carbon, no Accessibility needed)

    private func registerHotkey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x46444F53), id: 1) // 'FDOS'
        let keyCode = UInt32(kVK_ANSI_F)
        let modifiers = UInt32(optionKey | shiftKey)

        var handlerSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                var hk = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hk
                )
                if hk.id == 1 {
                    DispatchQueue.main.async {
                        app.toggle()
                    }
                }
                return noErr
            },
            1,
            &handlerSpec,
            userData,
            &eventHandler
        )

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

// MARK: - main

let cliArgs = CommandLine.arguments
if cliArgs.count >= 3, cliArgs[1] == "--log" {
    exit(runHeadless(transcript: cliArgs.dropFirst(2).joined(separator: " ")))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

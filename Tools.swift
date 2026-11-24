import AppKit
import PDFKit

/// The things Claude can do on this Mac. Reading is limited to the home folder and needs no approval;
/// writing a file or running a command shows the user exactly what will happen and waits for a click.
enum ToolBox {
    /// Everything the tools touch must be inside this folder.
    static var root = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
    static let maxRead = 100_000

    typealias Approve = (_ title: String, _ detail: String, _ action: String) async -> Bool

    static let definitions: [[String: Any]] = [
        tool("search_files",
             "Find files on the user's Mac with Spotlight, by name or by words inside them. Call this whenever the user mentions a document, file, photo or folder without giving its exact path.",
             ["query": ["type": "string", "description": "Words to look for, e.g. \"resume\" or \"tax 2025 invoice\""],
              "folder": ["type": "string", "description": "Optional folder to search in, e.g. \"~/Documents\". Default: the whole home folder."]],
             required: ["query"]),
        tool("list_folder",
             "List the files and folders inside a folder. Use ~ for the home folder.",
             ["path": ["type": "string", "description": "Folder path, e.g. \"~/Desktop\""]],
             required: ["path"]),
        tool("read_file",
             "Read the text of a file: plain text and code, PDF, Word (.doc/.docx), RTF, HTML and similar. Call this before answering questions about what a document says.",
             ["path": ["type": "string", "description": "File path, e.g. \"~/Documents/report.pdf\""],
              "max_characters": ["type": "integer", "description": "Optional limit on how much text to return (default 20000)."]],
             required: ["path"]),
        tool("write_file",
             "Create or replace a text file. The user is shown the path and content and must approve before anything is written; a file that gets replaced is backed up first.",
             ["path": ["type": "string", "description": "File path, e.g. \"~/Documents/notes.txt\""],
              "content": ["type": "string", "description": "The complete new contents of the file"]],
             required: ["path", "content"]),
        tool("run_command",
             "Run a zsh command on the user's Mac, e.g. to open an app or file (open -a Safari, open ~/Documents/x.pdf), check system information, or do something the other tools can't. The user sees the exact command and must approve it before it runs. Prefer the other tools for finding and reading files.",
             ["command": ["type": "string", "description": "The shell command to run"]],
             required: ["command"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "eager_input_streaming": true,
         "input_schema": ["type": "object", "properties": properties, "required": required]]
    }

    /// A short line for the chat, saying what the tool is doing.
    static func describe(_ call: ToolCall) -> String {
        let s = { (key: String) in call.input[key] as? String ?? "" }
        switch call.name {
        case "search_files": return "Searching files for “\(s("query"))”"
        case "list_folder": return "Looking in \(short(s("path")))"
        case "read_file": return "Reading \(short(s("path")))"
        case "write_file": return "Asking to write \(short(s("path")))"
        case "run_command": return "Asking to run: \(s("command"))"
        default: return "Using \(call.name)"
        }
    }

    static func short(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Runs a tool call. Inputs are checked first, since they come from the model.
    static func execute(_ call: ToolCall, approve: Approve) async -> ToolOutcome {
        func text(_ key: String) throws -> String {
            guard let value = call.input[key] as? String else {
                throw AppError(message: "Invalid input: \"\(key)\" must be a string.")
            }
            return value
        }
        do {
            switch call.name {
            case "search_files":
                let folder = (call.input["folder"] as? String).map { try? resolve($0) } ?? root
                return ToolOutcome(content: try await search(try text("query"), in: folder ?? root))
            case "list_folder":
                return ToolOutcome(content: try list(try resolve(try text("path"))))
            case "read_file":
                let limit = min(max((call.input["max_characters"] as? Int) ?? 20_000, 500), maxRead)
                return ToolOutcome(content: try await read(try resolve(try text("path")), limit: limit))
            case "write_file":
                let url = try resolve(try text("path"))
                let content = try text("content")
                let exists = FileManager.default.fileExists(atPath: url.path)
                let preview = content.count > 1500 ? String(content.prefix(1500)) + "\n…" : content
                guard await approve(exists ? "Claude wants to replace a file" : "Claude wants to create a file",
                                    short(url.path) + "\n\n" + preview, exists ? "Replace File" : "Create File") else {
                    return ToolOutcome(content: "The user declined, so the file was not written.", isError: true)
                }
                return ToolOutcome(content: try write(content, to: url))
            case "run_command":
                let command = try text("command")
                guard await approve("Claude wants to run a command", command, "Run") else {
                    return ToolOutcome(content: "The user declined, so the command did not run.", isError: true)
                }
                let result = await run("/bin/zsh", ["-c", command], timeout: 60)
                var output = result.output.isEmpty ? "(no output)" : result.output
                if output.count > 20_000 { output = String(output.prefix(20_000)) + "\n[… output truncated]" }
                let note = result.timedOut ? "\n[stopped after 60 seconds]" : "\n[exit status \(result.status)]"
                return ToolOutcome(content: output + note, isError: result.status != 0 || result.timedOut)
            default:
                return ToolOutcome(content: "Unknown tool \(call.name).", isError: true)
            }
        } catch {
            return ToolOutcome(content: error.localizedDescription, isError: true)
        }
    }

    // MARK: Paths

    /// Expands ~, resolves .. and symlinks, and refuses anything outside the root folder.
    static func resolve(_ raw: String) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw AppError(message: "No path was given.") }
        if path == "~" || path.hasPrefix("~/") { path = root.path + path.dropFirst() }  // ~ is the root folder (the home folder)
        if !path.hasPrefix("/") { path = root.path + "/" + path }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw AppError(message: "\(raw) is outside \(short(root.path)), the only folder Hidden Chat can access.")
        }
        return url
    }

    // MARK: Reading

    static func search(_ query: String, in folder: URL) async throws -> String {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppError(message: "The search query is empty.") }
        let result = await run("/usr/bin/mdfind", ["-onlyin", folder.path, query], timeout: 10)
        let searchingLibrary = folder.path.contains("/Library")
        let paths = result.output.split(separator: "\n").map(String.init)
            .filter { searchingLibrary || !$0.contains("/Library/") }
        guard !paths.isEmpty else { return "No files found for “\(query)” in \(short(folder.path))." }
        let shown = paths.prefix(40).map(short).joined(separator: "\n")
        return paths.count > 40 ? shown + "\n(\(paths.count - 40) more not shown)" : shown
    }

    static func list(_ folder: URL) throws -> String {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !items.isEmpty else { return "\(short(folder.path)) is empty." }
        let lines = items.prefix(300).map { url -> String in
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { return url.lastPathComponent + "/" }
            let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
            return "\(url.lastPathComponent)  (\(size))"
        }
        return lines.joined(separator: "\n") + (items.count > 300 ? "\n(\(items.count - 300) more not shown)" : "")
    }

    static func read(_ url: URL, limit: Int) async throws -> String {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw AppError(message: "There's no file at \(short(url.path)).")
        }
        if isFolder.boolValue { throw AppError(message: "\(short(url.path)) is a folder; use list_folder.") }

        let ext = url.pathExtension.lowercased()
        var text: String
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw AppError(message: "Couldn't open the PDF.") }
            text = pdf.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "This PDF has no selectable text (it may be scanned images)."
            }
        } else if ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"].contains(ext) {
            let result = await run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path], timeout: 20)
            guard result.status == 0 else { throw AppError(message: "Couldn't read the document: \(result.output)") }
            text = result.output
        } else {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 4_000_000) ?? Data()
            if data.prefix(8000).contains(0) {
                throw AppError(message: "\(short(url.path)) isn't a text document, so it can't be read as text.")
            }
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n\n[… truncated: showing the first \(limit) of \(text.count) characters]"
        }
        return text
    }

    // MARK: Changing things (only after approval)

    static func write(_ content: String, to url: URL) throws -> String {
        let fm = FileManager.default
        var note = ""
        if fm.fileExists(atPath: url.path) {
            let backups = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HiddenWindow/backups", isDirectory: true)
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = backups.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
            try fm.copyItem(at: url, to: backup)
            note = " The previous version was backed up to \(short(backup.path))."
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.count) characters to \(short(url.path)).\(note)"
    }

    /// Runs a program and returns its combined output, stopping it after `timeout` seconds.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> (output: String, status: Int32, timedOut: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = root
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                let lock = NSLock()
                var data = Data()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    lock.withLock { data.append(chunk) }
                }
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: ("Couldn't start \(executable): \(error.localizedDescription)", -1, false))
                    return
                }
                let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
                if timedOut { process.terminate(); _ = done.wait(timeout: .now() + 2) }
                Thread.sleep(forTimeInterval: 0.05)  // let the last output arrive
                pipe.fileHandleForReading.readabilityHandler = nil
                let output = lock.withLock { String(decoding: data, as: UTF8.self) }
                continuation.resume(returning: (output.trimmingCharacters(in: .newlines), process.terminationStatus, timedOut))
            }
        }
    }
}

import Foundation

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Settings live in ~/Library/Application Support/HiddenWindow/config.json, readable only by you.
struct Config: Codable {
    var provider: String = "claude"        // "claude" or "openai"
    var apiKey: String = ""                 // OpenAI
    var model: String = "gpt-5.5"           // OpenAI model
    var anthropicKey: String = ""
    var claudeModel: String = "claude-opus-5-5"
    var speechLocale: String = ""           // speech recognition language, e.g. "en_GB"; "" = automatic

    init() {}

    // Settings files saved by older versions lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        anthropicKey = try c.decodeIfPresent(String.self, forKey: .anthropicKey) ?? d.anthropicKey
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        speechLocale = try c.decodeIfPresent(String.self, forKey: .speechLocale) ?? d.speechLocale
    }
}

enum ConfigStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HiddenWindow", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    static func save(_ config: Config) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(config).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

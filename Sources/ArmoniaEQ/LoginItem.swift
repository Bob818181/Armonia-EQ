import Foundation

/// Avvio automatico all'accesso a macOS.
///
/// Su macOS 12 non è disponibile SMAppService (macOS 13+), e SMLoginItemSetEnabled richiede un'app
/// helper separata. La soluzione nativa e senza permessi di amministratore è un LaunchAgent
/// dell'utente in ~/Library/LaunchAgents: all'accesso launchd esegue `open -g` sull'app con
/// l'argomento --avvio-automatico, che la avvia in secondo piano con la sola icona nella barra
/// dei menu. Disattivare l'opzione rimuove il file.
enum LoginItem {
    static let label = "it.armoniaeq.app.login"
    static let launchArgument = "--avvio-automatico"

    /// Solo per i test: cartella alternativa al posto di ~/Library/LaunchAgents.
    static var overrideDirectory: URL?

    static var agentsDirectory: URL {
        overrideDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var plistURL: URL { agentsDirectory.appendingPathComponent("\(label).plist") }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func plist(appPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", appPath, "--args", launchArgument],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    /// Percorso dell'app registrato nel LaunchAgent (nil se l'opzione è disattivata).
    static func configuredAppPath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = obj["ProgramArguments"] as? [String],
              let i = args.firstIndex(of: "-a"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func setEnabled(_ enabled: Bool, appPath: String) throws {
        if enabled {
            try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist(appPath: appPath), format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } else if isEnabled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    /// Se l'app è stata spostata, aggiorna il percorso nel LaunchAgent.
    @discardableResult
    static func refreshIfNeeded(appPath: String) -> Bool {
        guard isEnabled, configuredAppPath() != appPath else { return false }
        return (try? setEnabled(true, appPath: appPath)) != nil
    }
}

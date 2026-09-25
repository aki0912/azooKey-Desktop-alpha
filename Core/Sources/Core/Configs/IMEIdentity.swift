import Foundation

/// The app and its embedded helper resolve the same identity from the enclosing app.
/// Build tools select a separate bundle; environment variables cannot redirect user data.
public enum IMEIdentity: String, Sendable {
    case standard, mixed

    public static let current: Self = resolve(executableURL: Bundle.main.executableURL,
                                             bundleIdentifier: Bundle.main.bundleIdentifier)
    public var bundleIdentifier: String {
        self == .mixed ? "dev.azookey.inputmethod.azooKeyMixed" : "dev.ensan.inputmethod.azooKeyMac"
    }
    public var displayName: String { self == .mixed ? "azooKey Mixed" : "azooKey" }
    public var machServiceName: String { bundleIdentifier + ".ConverterServer" }
    public var appGroupIdentifier: String { "group." + bundleIdentifier }
    public var preferencesIdentifier: String {
        self == .mixed ? bundleIdentifier + ".preferences" : appGroupIdentifier
    }
    public var keychainAccount: String { bundleIdentifier + ".preference.OpenAiApiKey" }
    public var customTableDirectoryName: String { self == .mixed ? "azooKeyMixed" : "azooKeyMac" }
    public var automaticModeIdentifier: String { bundleIdentifier + ".Automatic" }

    public static func resolve(executableURL: URL?, bundleIdentifier: String?) -> Self {
        if bundleIdentifier == Self.mixed.bundleIdentifier {
            return .mixed
        }
        guard var directory = executableURL?.deletingLastPathComponent() else {
            return .standard
        }
        while directory.path != "/" {
            if directory.lastPathComponent == "Contents" {
                let url = directory.appendingPathComponent("Info.plist")
                // Empty options support both older macOS Int and newer OptionSet definitions.
                if let data = try? Data(contentsOf: url),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: .init(), format: nil) as? [String: Any],
                   plist["CFBundleIdentifier"] as? String == Self.mixed.bundleIdentifier {
                    return .mixed
                }
                return .standard
            }
            directory.deleteLastPathComponent()
        }
        return .standard
    }

    /// Local test builds use their own Application Support tree, never the standard App Group.
    public func mixedDataDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/azooKeyMixed", isDirectory: true)
    }
}

public enum IMEInputMode: String, Sendable, CaseIterable {
    case japanese, roman, automatic

    public func identifier(for identity: IMEIdentity) -> String {
        identity.bundleIdentifier + "." + (self == .japanese ? "Japanese" : self == .roman ? "Roman" : "Automatic")
    }
    public var inputLanguage: InputLanguage { self == .roman ? .english : .japanese }
    public var compositionPolicy: CompositionPolicy { self == .automatic ? .automaticMixed : .manual }

    public static func resolve(_ value: String, identity: IMEIdentity) -> Self? {
        switch value {
        case "com.apple.inputmethod.Japanese": return .japanese
        case "com.apple.inputmethod.Roman": return .roman
        default:
            return allCases.first { ($0 != .automatic || identity == .mixed) && $0.identifier(for: identity) == value }
        }
    }
}

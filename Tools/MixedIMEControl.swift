import AppKit
import Carbon
import Foundation

// Installation/registration are scoped to Mixed. Restore only selects an already-enabled source.
let bundleID = "dev.azookey.inputmethod.azooKeyMixed"
let allowedIDs = Set(["Japanese", "Roman", "Automatic"].map { bundleID + "." + $0 })

func property(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let value = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}
func sources() -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
    return TISCreateInputSourceList(filter, true).takeRetainedValue() as? [TISInputSource] ?? []
}
func check(_ status: OSStatus) throws {
    if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}
func selectedID() -> String? {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return property(current, kTISPropertyInputSourceID)
}
func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let value = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
}
func canEnable(_ source: TISInputSource) -> Bool { flag(source, kTISPropertyInputSourceIsEnableCapable) }
func emitStatus() throws {
    let selected = selectedID()
    let result = sources().map { source in
        let id = property(source, kTISPropertyInputSourceID) ?? ""
        return ["id": id, "name": property(source, kTISPropertyLocalizedName) ?? "", "selected": id == selected,
                "enabled": flag(source, kTISPropertyInputSourceIsEnabled),
                "enableCapable": canEnable(source),
                "selectable": flag(source, kTISPropertyInputSourceIsSelectCapable)] as [String: Any]
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "current": print(selectedID() ?? "")
    case "restore":
        guard args.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let filter = [kTISPropertyInputSourceID as String: args[1], kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        let enabled = TISCreateInputSourceList(filter, false).takeRetainedValue() as? [TISInputSource] ?? []
        guard let source = enabled.first else { throw CocoaError(.fileReadNoSuchFile) }
        try check(TISSelectInputSource(source))
    case "register":
        guard args.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let app = URL(fileURLWithPath: args[1]).standardizedFileURL
        guard Bundle(url: app)?.bundleIdentifier == bundleID else { throw CocoaError(.fileReadCorruptFile) }
        try check(TISRegisterInputSource(app as CFURL))
        // The parent must be enabled before its modes can actually be selected.
        guard let parent = sources().first(where: { property($0, kTISPropertyInputSourceID) == bundleID }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try check(TISEnableInputSource(parent))
        for source in sources() where allowedIDs.contains(property(source, kTISPropertyInputSourceID) ?? "") {
            try check(TISEnableInputSource(source))
        }
        if !sources().contains(where: { property($0, kTISPropertyInputSourceID) == bundleID && flag($0, kTISPropertyInputSourceIsEnabled) }) {
            fputs("Mixed files are registered, but macOS has not enabled the parent input source. Log out/in, then add azooKey Mixed in Keyboard > Text Input. IMK typing is not yet verified.\n", stderr)
        }
        try emitStatus()
    case "disable":
        guard !allowedIDs.contains(selectedID() ?? "") else {
            throw NSError(domain: "Select another input source before removing azooKey Mixed", code: 1)
        }
        for source in sources() where canEnable(source) { try check(TISDisableInputSource(source)) }
    case "select":
        guard args.count == 2, allowedIDs.contains(bundleID + "." + args[1]),
              sources().contains(where: { property($0, kTISPropertyInputSourceID) == bundleID && flag($0, kTISPropertyInputSourceIsEnabled) }),
              let source = sources().first(where: { property($0, kTISPropertyInputSourceID) == bundleID + "." + args[1]
                  && flag($0, kTISPropertyInputSourceIsEnabled) && flag($0, kTISPropertyInputSourceIsSelectCapable) }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try check(TISSelectInputSource(source))
        try emitStatus()
    case "terminate":
        guard args.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        guard !allowedIDs.contains(selectedID() ?? "") else {
            throw NSError(domain: "Select another input source before updating azooKey Mixed", code: 1)
        }
        let path = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == path {
            _ = app.terminate()
            let deadline = Date().addingTimeInterval(3)
            while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if !app.isTerminated && !app.forceTerminate() { throw NSError(domain: "Unable to terminate azooKey Mixed", code: 1) }
        }
    case "status": try emitStatus()
    default: throw NSError(domain: "Use register, disable, select, terminate, status, current, or restore", code: 2)
    }
} catch {
    fputs("MixedIMEControl failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

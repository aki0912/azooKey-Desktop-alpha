@testable import Core
import Foundation
import Testing

@Suite struct IMEIdentityTests {
    @Test func standardIdentifiersRemainUnchangedAndMixedDoesNotShareStorage() {
        #expect(IMEIdentity.standard.bundleIdentifier == "dev.ensan.inputmethod.azooKeyMac")
        #expect(IMEIdentity.standard.machServiceName == "dev.ensan.inputmethod.azooKeyMac.ConverterServer")
        #expect(IMEIdentity.standard.preferencesIdentifier == "group.dev.ensan.inputmethod.azooKeyMac")
        #expect(IMEIdentity.standard.keychainAccount == "dev.ensan.inputmethod.azooKeyMac.preference.OpenAiApiKey")
        #expect(IMEIdentity.mixed.machServiceName != IMEIdentity.standard.machServiceName)
        #expect(IMEIdentity.mixed.preferencesIdentifier != IMEIdentity.standard.preferencesIdentifier)
        #expect(IMEIdentity.mixed.keychainAccount != IMEIdentity.standard.keychainAccount)
        #expect(IMEIdentity.mixed.customTableDirectoryName != IMEIdentity.standard.customTableDirectoryName)
        #expect(IMEIdentity.mixed.mixedDataDirectory(home: .temporaryDirectory).lastPathComponent == "azooKeyMixed")
    }

    @Test func appAndDeeplyEmbeddedHelperResolveTheSameIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-test-\(UUID())")
        let contents = root.appendingPathComponent("Mixed.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": IMEIdentity.mixed.bundleIdentifier],
            format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        #expect(IMEIdentity.resolve(executableURL: contents.appendingPathComponent("Helpers/ConverterServer/ConverterServer"),
                                    bundleIdentifier: nil) == .mixed)
        #expect(IMEIdentity.resolve(executableURL: contents.appendingPathComponent("MacOS/azooKeyMixed"),
                                    bundleIdentifier: IMEIdentity.mixed.bundleIdentifier) == .mixed)
        #expect(IMEIdentity.resolve(executableURL: nil, bundleIdentifier: nil) == .standard)
    }

    @Test func threeModesParseOnlyTheirOwnInputSourceIdentifiers() {
        for mode in IMEInputMode.allCases {
            #expect(IMEInputMode.resolve(mode.identifier(for: .mixed), identity: .mixed) == mode)
        }
        #expect(IMEInputMode.resolve("com.apple.inputmethod.Japanese", identity: .mixed) == .japanese)
        #expect(IMEInputMode.resolve("com.apple.inputmethod.Roman", identity: .mixed) == .roman)
        #expect(IMEInputMode.resolve(IMEInputMode.automatic.identifier(for: .mixed), identity: .standard) == nil)
        #expect(IMEInputMode.resolve(IMEInputMode.japanese.identifier(for: .standard), identity: .mixed) == nil)
        #expect(IMEInputMode.resolve("unknown", identity: .mixed) == nil)
        #expect(IMEInputMode.automatic.inputLanguage == .japanese)
        #expect(IMEInputMode.automatic.compositionPolicy == .automaticMixed)
        #expect(IMEInputMode.japanese.compositionPolicy == .manual)
        #expect(IMEInputMode.roman.compositionPolicy == .manual)
    }
}

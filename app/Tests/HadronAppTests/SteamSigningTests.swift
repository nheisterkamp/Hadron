import Foundation
import Testing

@testable import HadronApp

@Suite("Steam signing", .serialized)
struct SteamSigningTests {

    private func requirement(_ url: URL) throws -> String {
        let result = try Shell.run("/usr/bin/codesign", ["-d", "-r-", url.path(percentEncoded: false)])
        return try #require((result.stdout + result.stderr).split(separator: "\n")
            .first { $0.hasPrefix("designated => ") }.map(String.init))
    }

    private func cdhash(_ url: URL) throws -> String {
        let result = try Shell.run("/usr/bin/codesign", ["-dvvv", url.path(percentEncoded: false)])
        return try #require((result.stdout + result.stderr).split(separator: "\n")
            .first { $0.hasPrefix("CDHash=") }.map(String.init))
    }

    // What keeps Steam's permissions: changed code under the same requirement.
    @Test("Signing changed code keeps the designated requirement")
    func requirementSurvivesChange() throws {
        let files = FileManager.default
        let work = files.temporaryDirectory.appending(path: "steam-signing-\(UUID().uuidString)")
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        let signing = SteamSigning(support: work)
        defer {
            _ = try? Shell.run("/usr/bin/security", ["delete-keychain", signing.keychain.path(percentEncoded: false)])
            try? files.removeItem(at: work)
        }

        let identity = try #require(signing.identity())
        let target = work.appending(path: "steam_osx")

        try files.copyItem(at: URL(filePath: "/bin/ls"), to: target)
        try signing.sign(target)
        let before = try requirement(target)
        let firstHash = try cdhash(target)

        try files.removeItem(at: target)
        try files.copyItem(at: URL(filePath: "/bin/cat"), to: target)
        try SteamSigning(support: work).sign(target)

        #expect(before.contains("certificate leaf = H\"\(identity.lowercased())\""))
        #expect(try requirement(target) == before)
        #expect(try cdhash(target) != firstHash)
        #expect(SteamSigning(support: work).identity() == identity, "a second run made a new identity")

        // The password stays with Hadron, and the keychain stays out of the search list.
        let mode = try files.attributesOfItem(atPath: signing.passwordFile.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let list = try Shell.run("/usr/bin/security", ["list-keychains", "-d", "user"]).stdout
        #expect(!list.contains(signing.keychain.lastPathComponent))
    }

    @Test("The installer resets Steam's permissions only when the requirement changes")
    func resetFollowsRequirement() throws {
        let source = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Sources/HadronApp/Model/SteamInstaller.swift"),
            encoding: .utf8)
        #expect(source.contains("if designatedRequirement(of: app) != priorRequirement {"))
        #expect(!source.contains("cdhash(of: app) != priorHash"))
    }
}

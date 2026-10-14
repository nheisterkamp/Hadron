// The identity Hadron signs Steam with after injecting into it.
//
// macOS ties Steam's input and device permissions to Steam's designated requirement. An
// ad-hoc signature's requirement is the code's hash, which every Hadron update changes, so
// the permissions went with each update. A certificate's requirement names the identifier
// and the certificate, which stay, so Hadron signs with a self-signed one of its own. It
// lives in a keychain file of its own with a password only Hadron keeps, so signing never
// asks for anything and nothing is added to the login keychain.

import Foundation
import Security

struct SteamSigning: Sendable {

    static let commonName = "Hadron Steam Signing"

    let directory: URL

    init(support: URL = SupportPaths.support) {
        directory = support.appending(path: "signing")
    }

    var keychain: URL { directory.appending(path: "hadron-signing.keychain-db") }
    var passwordFile: URL { directory.appending(path: "keychain-password") }
    // Left when no identity could be made, so Steam is not offered a new signature on
    // every check only to be signed ad hoc again.
    var unavailableMarker: URL { directory.appending(path: "unavailable") }

    // Steam still has the ad-hoc signature an earlier Hadron gave it, and the identity
    // could replace it.
    func wantsResigning(_ app: URL) -> Bool {
        guard !FileManager.default.fileExists(atPath: path(unavailableMarker)),
            let requirement = SteamInstaller.designatedRequirement(of: app)
        else { return false }
        return requirement.hasPrefix("cdhash ")
    }

    // Signs with the identity, made the first time; ad hoc when it cannot be had.
    func sign(_ url: URL, step: String = SteamInstaller.step) throws {
        guard let identity = identity() else {
            try SteamInstaller.adHocSign(url, step: step)
            return
        }
        try SteamInstaller.sign(url, step: step, arguments: ["-s", identity, "--keychain", path(keychain)])
    }

    // The identity's SHA-1, with the keychain unlocked for codesign.
    func identity() -> String? {
        guard let password = password() else { return nil }
        if FileManager.default.fileExists(atPath: path(keychain)) {
            if unlock(password), let found = findIdentity() { return found }
            AppLog.note("signing: the keychain has no usable identity, making a new one")
            _ = try? Shell.run("/usr/bin/security", ["delete-keychain", path(keychain)])
            try? FileManager.default.removeItem(at: keychain)
        }
        do {
            try create(password: password)
        } catch {
            AppLog.note("signing: could not make an identity, signing ad hoc: \(error)")
            _ = try? Shell.run("/usr/bin/security", ["delete-keychain", path(keychain)])
            FileManager.default.createFile(atPath: path(unavailableMarker), contents: Data())
            return nil
        }
        return unlock(password) ? findIdentity() : nil
    }

    private func password() -> String? {
        if let saved = try? String(contentsOf: passwordFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(
                atPath: path(passwordFile), contents: Data(fresh.utf8), attributes: [.posixPermissions: 0o600])
            else { return nil }
        } catch {
            return nil
        }
        return fresh
    }

    private func create(password: String) throws {
        let work = directory.appending(path: "work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        let config = work.appending(path: "cert.cnf")
        try """
            [req]
            distinguished_name = dn
            x509_extensions = ext
            prompt = no
            [dn]
            CN = \(Self.commonName)
            [ext]
            keyUsage = critical, digitalSignature
            extendedKeyUsage = critical, codeSigning
            basicConstraints = critical, CA:false

            """.write(to: config, atomically: true, encoding: .utf8)
        let key = work.appending(path: "key.pem"), cert = work.appending(path: "cert.pem")
        let bundle = work.appending(path: "identity.p12")

        // The system's LibreSSL, whose PKCS#12 security(1) imports as it is.
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "7300",
                                     "-keyout", path(key), "-out", path(cert), "-config", path(config)])
        try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", path(key), "-in", path(cert),
                                     "-out", path(bundle), "-name", Self.commonName,
                                     "-passout", "pass:\(password)"])
        try run("/usr/bin/security", ["create-keychain", "-p", password, path(keychain)])
        // No locking on sleep or after a while; it is unlocked before every use anyway.
        try run("/usr/bin/security", ["set-keychain-settings", path(keychain)])
        try run("/usr/bin/security", ["unlock-keychain", "-p", password, path(keychain)])
        try run("/usr/bin/security", ["import", path(bundle), "-k", path(keychain), "-P", password,
                                      "-T", "/usr/bin/codesign", "-f", "pkcs12"])
        // Without this, codesign asks for the keychain's password to use the key.
        try run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                                      "-s", "-k", password, path(keychain)])
    }

    private func unlock(_ password: String) -> Bool {
        (try? Shell.run("/usr/bin/security", ["unlock-keychain", "-p", password, path(keychain)]))?.succeeded == true
    }

    private func findIdentity() -> String? {
        guard let result = try? Shell.run("/usr/bin/security", ["find-identity", "-p", "codesigning", path(keychain)])
        else { return nil }
        // An untrusted self-signed certificate is listed under matching identities only,
        // which is all codesign needs.
        for line in result.stdout.split(separator: "\n") where line.contains("\"\(Self.commonName)\"") {
            let words = line.split(separator: " ")
            if let hash = words.first(where: { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }) {
                return String(hash)
            }
        }
        return nil
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let result = try Shell.run(tool, arguments)
        guard result.succeeded else {
            throw StepFailure(step: "signing", detail: "\(tool) \(arguments.first ?? ""): \(result.stderr)")
        }
    }

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }
}

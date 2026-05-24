import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH
import os

private let logger = Logger(subsystem: "com.telecmux.app", category: "SSH")

/// Owns a long-lived non-interactive SSH session to a single Host.
///
/// Telecmux drives cmux through short `cmux <subcommand>` exec calls — we
/// don't open a PTY. Each Pane view creates its own manager, connects, then
/// fires `exec()` on user actions and on the polling timer.
///
/// All state mutations happen on the main actor so views can read directly.
@MainActor
@Observable
final class SSHConnectionManager {

    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    /// What's happening right now. Views render based on this.
    private(set) var state: State = .idle

    private var client: SSHClient?

    // MARK: - public API

    /// Open an exec-only SSH session. Idempotent — re-calling while already
    /// connected is a no-op so views can `await` it from `.task` without
    /// guarding.
    func connect(to host: Host) async {
        if case .ready = state { return }
        state = .connecting

        do {
            let auth = try buildAuthMethod(for: host)
            let client = try await SSHClient.connect(
                host: host.hostname,
                port: host.port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
            self.client = client
            state = .ready
        } catch {
            logger.error("connect failed: \(String(describing: error))")
            state = .failed(error.localizedDescription)
        }
    }

    /// Compatibility name kept while older call sites migrate.
    func connectExecOnly(host: Host) async { await connect(to: host) }

    /// Run a one-shot command on the remote host and return the captured
    /// stdout. Designed for cmux CLI calls that return quickly; not for
    /// streaming.
    func exec(_ command: String) async throws -> String {
        guard let client else { throw Failure.notReady }
        let buffer = try await client.executeCommand(command)
        return buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
    }

    /// Close the underlying SSH session. Safe to call multiple times.
    func disconnect() {
        let snapshot = client
        client = nil
        state = .idle
        Task { try? await snapshot?.close() }
    }

    // MARK: - auth

    private func buildAuthMethod(for host: Host) throws -> SSHAuthenticationMethod {
        guard !host.privateKeyRef.isEmpty else { throw Failure.noKeyConfigured }
        let blob = try loadKeyBytes(for: host)
        guard let pem = String(data: blob, encoding: .utf8) else { throw Failure.keyNotUTF8 }

        switch SSHKeyFormat.detect(in: pem) {
        case .opensshEd25519:
            let seed = try OpenSSHEd25519Parser.parseSeed(pem: pem)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return .ed25519(username: host.username, privateKey: key)
        case .rsa:
            let key = try Insecure.RSA.PrivateKey(sshRsa: pem)
            return .rsa(username: host.username, privateKey: key)
        case .unknown:
            throw Failure.unsupportedKeyFormat
        }
    }

    private func loadKeyBytes(for host: Host) throws -> Data {
        if KeychainStore.contains(host.privateKeyRef) {
            return try KeychainStore.load(host.privateKeyRef)
        }
        // Developer escape hatch: a plain file at Documents/dev-ssh-key so a
        // dev build can load a key without going through the Keychain UI.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let devFile = docs.appendingPathComponent("dev-ssh-key")
        if FileManager.default.fileExists(atPath: devFile.path) {
            return try Data(contentsOf: devFile)
        }
        throw Failure.noKeyConfigured
    }
}

// MARK: - errors

extension SSHConnectionManager {
    enum Failure: LocalizedError {
        case noKeyConfigured
        case keyNotUTF8
        case unsupportedKeyFormat
        case notReady

        var errorDescription: String? {
            switch self {
            case .noKeyConfigured:     "No SSH key set for this host"
            case .keyNotUTF8:          "Stored key is not valid UTF-8"
            case .unsupportedKeyFormat: "Key format not supported (need OpenSSH ed25519 or RSA)"
            case .notReady:            "SSH session is not connected"
            }
        }
    }
}

// MARK: - key format detection

/// What kind of PEM blob we're holding.
enum SSHKeyFormat {
    case opensshEd25519
    case rsa
    case unknown

    /// Heuristic based on the BEGIN line of the PEM blob.
    static func detect(in pem: String) -> SSHKeyFormat {
        if pem.contains("BEGIN OPENSSH PRIVATE KEY") { return .opensshEd25519 }
        if pem.contains("BEGIN RSA PRIVATE KEY")     { return .rsa }
        return .unknown
    }
}

// MARK: - OpenSSH ed25519 seed extractor

/// Pulls the 32-byte ed25519 seed out of an unencrypted OpenSSH-format
/// private key blob.
///
/// OpenSSH key format reference:
/// https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.key
///
/// Wire layout (everything length-prefixed by big-endian uint32):
///   magic            = "openssh-key-v1\0"
///   ciphername       = "none"  (we require unencrypted keys)
///   kdfname          = "none"
///   kdfoptions       = "" (empty string)
///   numkeys          = 1
///   public-key-blob
///   private-key-blob:
///       checkint1        (uint32)
///       checkint2        (uint32, equal to checkint1)
///       keytype          = "ssh-ed25519"
///       public-key-bytes (32 bytes, length-prefixed)
///       private-key-bytes (64 bytes, length-prefixed; first 32 = seed)
///       comment
///       padding to 8-byte alignment
enum OpenSSHEd25519Parser {

    enum ParseError: LocalizedError {
        case base64Decode
        case missingMagic
        case truncated
        case encryptedKey
        case notEd25519

        var errorDescription: String? {
            switch self {
            case .base64Decode: "Could not base64-decode the OpenSSH blob"
            case .missingMagic: "Blob does not start with the OpenSSH magic header"
            case .truncated:    "OpenSSH blob ended before expected data"
            case .encryptedKey: "Encrypted OpenSSH keys are not supported — re-export without a passphrase"
            case .notEd25519:   "Inner key type is not ssh-ed25519"
            }
        }
    }

    /// Returns the 32-byte seed suitable for `Curve25519.Signing.PrivateKey`.
    static func parseSeed(pem: String) throws -> Data {
        let bytes = try base64Body(of: pem)
        var reader = ByteReader(bytes)

        try reader.expectMagic("openssh-key-v1\0".data(using: .utf8)!)

        let cipher = try reader.lengthPrefixedString()
        let kdf    = try reader.lengthPrefixedString()
        _ = try reader.lengthPrefixedString() // kdfoptions
        guard cipher == "none", kdf == "none" else { throw ParseError.encryptedKey }

        guard try reader.uint32() == 1 else { throw ParseError.truncated } // numkeys
        _ = try reader.lengthPrefixedBytes() // public-key blob (skipped)
        let priv = try reader.lengthPrefixedBytes()

        var inner = ByteReader(Array(priv))
        _ = try inner.uint32() // checkint1
        _ = try inner.uint32() // checkint2 (assumed equal)

        let keyType = try inner.lengthPrefixedString()
        guard keyType == "ssh-ed25519" else { throw ParseError.notEd25519 }

        _ = try inner.lengthPrefixedBytes() // inner-pub (32 bytes)
        let privBlob = try inner.lengthPrefixedBytes() // 64 bytes
        guard privBlob.count >= 32 else { throw ParseError.truncated }

        return Data(privBlob.prefix(32))
    }

    /// Strip PEM header/footer, base64-decode the body.
    private static func base64Body(of pem: String) throws -> [UInt8] {
        let body = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw ParseError.base64Decode }
        return Array(data)
    }
}

// MARK: - byte cursor helper

/// Forward-only reader over a byte array. Throws `truncated` when callers
/// ask for more than what's left.
private struct ByteReader {
    private let bytes: [UInt8]
    private var index: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func uint32() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw OpenSSHEd25519Parser.ParseError.truncated }
        let v: UInt32 =
            (UInt32(bytes[index    ]) << 24) |
            (UInt32(bytes[index + 1]) << 16) |
            (UInt32(bytes[index + 2]) <<  8) |
             UInt32(bytes[index + 3])
        index += 4
        return v
    }

    mutating func lengthPrefixedBytes() throws -> [UInt8] {
        let n = Int(try uint32())
        guard index + n <= bytes.count else { throw OpenSSHEd25519Parser.ParseError.truncated }
        let slice = Array(bytes[index ..< (index + n)])
        index += n
        return slice
    }

    mutating func lengthPrefixedString() throws -> String {
        let raw = try lengthPrefixedBytes()
        return String(decoding: raw, as: UTF8.self)
    }

    /// Advance past `magic` if the bytes at the cursor match. Throws
    /// `missingMagic` on mismatch and `truncated` if there aren't enough
    /// bytes left to compare.
    mutating func expectMagic(_ magic: Data) throws {
        guard index + magic.count <= bytes.count else {
            throw OpenSSHEd25519Parser.ParseError.truncated
        }
        for (i, byte) in magic.enumerated() where bytes[index + i] != byte {
            throw OpenSSHEd25519Parser.ParseError.missingMagic
        }
        index += magic.count
    }
}

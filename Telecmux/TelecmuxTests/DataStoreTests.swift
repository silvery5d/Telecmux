import Testing
import Foundation
@testable import Telecmux

@Suite("Backup Tests")
struct DataStoreTests {
    @Test func backupRoundTrip() throws {
        let host = Host(displayName: "Test", hostname: "10.0.0.1", username: "user")
        let session = Session(displayName: "Session1", hostID: host.id, mode: .board)

        let backup = BackupData(
            version: 1,
            exportedAt: Date(),
            hosts: [host],
            sessions: [session]
        )

        let data = try JSONEncoder.telecmux.encode(backup)
        let decoded = try JSONDecoder.telecmux.decode(BackupData.self, from: data)

        #expect(decoded.version == 1)
        #expect(decoded.hosts.count == 1)
        #expect(decoded.sessions.count == 1)
        #expect(decoded.hosts[0].displayName == "Test")
        #expect(decoded.sessions[0].mode == .board)
    }

    @Test func backupOmitsKeyMaterial() throws {
        let host = Host(
            displayName: "Test",
            hostname: "10.0.0.1",
            username: "user",
            privateKeyRef: "keychain-ref-abc"
        )
        let backup = BackupData(version: 1, exportedAt: Date(), hosts: [host], sessions: [])
        let data = try JSONEncoder.telecmux.encode(backup)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("keychain-ref-abc"))
        #expect(!json.contains("BEGIN RSA PRIVATE KEY"))
        #expect(!json.contains("BEGIN OPENSSH PRIVATE KEY"))
    }
}

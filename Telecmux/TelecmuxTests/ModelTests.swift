import Testing
import Foundation
@testable import Telecmux

@Suite("Model Codable Tests")
struct ModelTests {
    @Test func hostRoundTrip() throws {
        let host = Host(
            displayName: "Test Mac",
            hostname: "192.168.1.1",
            port: 22,
            username: "dev",
            privateKeyRef: "key-ref-123"
        )
        let data = try JSONEncoder.telecmux.encode(host)
        let decoded = try JSONDecoder.telecmux.decode(Host.self, from: data)
        #expect(decoded.displayName == host.displayName)
        #expect(decoded.hostname == host.hostname)
        #expect(decoded.port == host.port)
        #expect(decoded.username == host.username)
        #expect(decoded.privateKeyRef == host.privateKeyRef)
        #expect(decoded.ribbonConfig == .cmuxAgent)
    }

    @Test func boardSessionRoundTrip() throws {
        let session = Session(displayName: "main", hostID: UUID(), mode: .board)
        let data = try JSONEncoder.telecmux.encode(session)
        let decoded = try JSONDecoder.telecmux.decode(Session.self, from: data)
        #expect(decoded.mode == .board)
        #expect(decoded.cmuxSurfaceRef == nil)
    }

    @Test func paneSessionRoundTrip() throws {
        let session = Session(
            displayName: "claude pane",
            hostID: UUID(),
            mode: .pane,
            cmuxSurfaceRef: "surface:34"
        )
        let data = try JSONEncoder.telecmux.encode(session)
        let decoded = try JSONDecoder.telecmux.decode(Session.self, from: data)
        #expect(decoded.mode == .pane)
        #expect(decoded.cmuxSurfaceRef == "surface:34")
    }

    @Test func legacyTmuxRecordDecodesAsBoard() throws {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "displayName": "old-session",
          "hostID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "createdAt": "2025-01-01T00:00:00Z",
          "tmuxSessionName": "claude",
          "mode": "tmux"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder.telecmux.decode(Session.self, from: json)
        #expect(decoded.mode == .board)
    }

    @Test func legacyCmuxPaneRefMigratesToCmuxSurfaceRef() throws {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "displayName": "old-pane",
          "hostID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "createdAt": "2025-01-01T00:00:00Z",
          "cmuxPaneRef": "surface:5",
          "mode": "cmuxPane"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder.telecmux.decode(Session.self, from: json)
        #expect(decoded.mode == .pane)
        #expect(decoded.cmuxSurfaceRef == "surface:5")
    }
}

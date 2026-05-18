import Foundation

/// A remote Mac that runs cmux. The SSH credentials live in this record;
/// per-session state lives in `Session`.
struct Host: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var hostname: String
    var port: Int = 22
    var username: String
    /// Keychain account key that resolves to the OpenSSH private key bytes.
    var privateKeyRef: String = ""
    /// Ribbon shown on PaneFocusView for sessions targeting this host.
    var ribbonConfig: RibbonConfig = .cmuxAgent
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, displayName, hostname, port, username, privateKeyRef
        case ribbonConfig, createdAt
        // Legacy: earlier dev builds wrote an array of ribbons.
        case ribbonConfigs
    }

    init(displayName: String,
         hostname: String,
         port: Int = 22,
         username: String,
         privateKeyRef: String = "") {
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.privateKeyRef = privateKeyRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        privateKeyRef = try c.decode(String.self, forKey: .privateKeyRef)
        createdAt = try c.decode(Date.self, forKey: .createdAt)

        if let single = try? c.decode(RibbonConfig.self, forKey: .ribbonConfig) {
            ribbonConfig = single
        } else if let arr = try? c.decode([RibbonConfig].self, forKey: .ribbonConfigs),
                  let first = arr.first {
            ribbonConfig = first
        } else {
            ribbonConfig = .cmuxAgent
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(hostname, forKey: .hostname)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(privateKeyRef, forKey: .privateKeyRef)
        try c.encode(ribbonConfig, forKey: .ribbonConfig)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

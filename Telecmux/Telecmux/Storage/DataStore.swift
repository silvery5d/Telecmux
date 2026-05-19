import Foundation
import os

private let logger = Logger(subsystem: "com.diwu.telecmux", category: "DataStore")

/// Persists the user's Host + Session list as a single JSON file.
///
/// Storage is chosen at construction:
/// - If the iCloud Drive ubiquity container is reachable, the file lives
///   there (`telecmux-data.json` inside `Documents/`) and is mirrored across
///   the user's devices.
/// - Otherwise (no iCloud account, simulator, container unavailable), it
///   falls back to the app's local Documents directory.
///
/// Concurrency model: this is a `@MainActor` `@Observable` so views can read
/// `hosts` / `sessions` directly. All file I/O happens through
/// `NSFileCoordinator` so iCloud writes don't race other devices.
@MainActor
@Observable
final class DataStore {
    var hosts: [Host] = []
    var sessions: [Session] = []

    /// Where this store's data file lives.
    let storage: Storage
    /// True iff iCloud chose itself at boot. Surfaced for the Settings panel.
    var iCloudAvailable: Bool { storage.isCloud }

    private var cloudWatcher: NSMetadataQuery?
    private var cloudObserver: NSObjectProtocol?

    init() {
        storage = Storage.resolve()
        bootstrap()
    }

    // No explicit deinit: this store is held by the app's @State for the
    // entire process lifetime, so the cloud watcher and observer naturally
    // outlive the only reference. Swift 6's strict actor isolation also
    // disallows touching MainActor-bound properties from a nonisolated
    // deinit, so there's no clean cleanup path here anyway.

    // MARK: - lifecycle

    /// One-shot boot sequence. Public so tests can re-run if needed.
    private func bootstrap() {
        promoteLegacyLocalFileIntoCloud()
        load()
        seedFileIfMissing()
        startWatchingCloud()
    }

    // MARK: - host CRUD

    func addHost(_ host: Host) {
        hosts.append(host)
        commit()
    }

    func deleteHost(_ host: Host) {
        // Cascading delete: any session bound to this host goes too.
        sessions.removeAll { $0.hostID == host.id }
        hosts.removeAll { $0.id == host.id }
        commit()
    }

    func host(for session: Session) -> Host? {
        hosts.first(where: { $0.id == session.hostID })
    }

    // MARK: - session CRUD

    func addSession(_ session: Session) {
        sessions.append(session)
        commit()
    }

    func deleteSession(_ session: Session) {
        sessions.removeAll(where: { $0.id == session.id })
        commit()
    }

    func sessions(for host: Host) -> [Session] {
        sessions.filter { $0.hostID == host.id }
    }

    // MARK: - persistence

    /// Read from disk (or iCloud), replacing in-memory state.
    func load() {
        let url = storage.url

        // If iCloud hasn't downloaded the file yet, ask for it; the cloud
        // watcher will retry once it arrives. Don't seed empty data on top
        // of what might still be syncing.
        if case .cloud(let cloudURL) = storage,
           !FileManager.default.fileExists(atPath: cloudURL.path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: cloudURL)
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var fileData: Data?
        var coordErr: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordErr) { coord in
            fileData = try? Data(contentsOf: coord)
        }
        if let coordErr {
            logger.error("Read coordinator failed: \(coordErr.localizedDescription)")
            return
        }
        guard let fileData else { return }

        do {
            let payload = try JSONDecoder.telecmux.decode(BackupData.self, from: fileData)
            hosts = payload.hosts
            sessions = payload.sessions
        } catch {
            logger.error("Decode of \(url.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }

    /// Encode current state and write it back.
    func commit() {
        // Protect against clobbering iCloud with an empty file when a device
        // boots before the cloud copy finishes downloading.
        if case .cloud = storage, hosts.isEmpty, sessions.isEmpty {
            logger.warning("Refusing to write empty state to cloud")
            return
        }

        let payload = BackupData(version: BackupData.currentVersion,
                                 exportedAt: Date(),
                                 hosts: hosts,
                                 sessions: sessions)
        let encoded: Data
        do {
            encoded = try JSONEncoder.telecmux.encode(payload)
        } catch {
            logger.error("Encode failed: \(error.localizedDescription)")
            return
        }

        var coordErr: NSError?
        NSFileCoordinator().coordinate(writingItemAt: storage.url,
                                       options: .forReplacing,
                                       error: &coordErr) { coord in
            do {
                try encoded.write(to: coord, options: .atomic)
            } catch {
                logger.error("Write failed: \(error.localizedDescription)")
            }
        }
        if let coordErr {
            logger.error("Write coordinator failed: \(coordErr.localizedDescription)")
        }
    }

    // MARK: - one-time migrations

    /// If a prior local-only install left a file behind and we just got an
    /// iCloud container, move it up so the user doesn't see two stores.
    private func promoteLegacyLocalFileIntoCloud() {
        guard case .cloud(let cloudURL) = storage else { return }
        let localURL = Storage.localFallbackURL()
        guard FileManager.default.fileExists(atPath: localURL.path),
              !FileManager.default.fileExists(atPath: cloudURL.path) else { return }
        do {
            let blob = try Data(contentsOf: localURL)
            try blob.write(to: cloudURL, options: .atomic)
            try? FileManager.default.removeItem(at: localURL)
            logger.info("Promoted local store into iCloud")
        } catch {
            logger.error("Promotion failed: \(error.localizedDescription)")
        }
    }

    private func seedFileIfMissing() {
        // Only seed when there's no iCloud — when there is, we wait for the
        // download instead of racing it.
        guard case .local(let url) = storage,
              !FileManager.default.fileExists(atPath: url.path) else { return }
        commit()
    }

    // MARK: - cloud change watcher

    private func startWatchingCloud() {
        guard case .cloud = storage else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, Storage.fileName)

        cloudObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            // Hop to the actor since this closure runs on the main queue but
            // not yet @MainActor-bound under Swift 6 concurrency rules.
            Task { @MainActor in self?.load() }
        }
        query.start()
        cloudWatcher = query
    }
}

// MARK: - storage strategy

extension DataStore {
    /// Where the JSON lives. Picked once at boot.
    enum Storage {
        case cloud(URL)
        case local(URL)

        static let fileName = "telecmux-data.json"
        static let containerID = "iCloud.com.diwu.telecmux"

        var url: URL {
            switch self {
            case .cloud(let u): u
            case .local(let u): u
            }
        }

        var isCloud: Bool {
            if case .cloud = self { true } else { false }
        }

        /// Local-only file URL inside the app's Documents folder.
        static func localFallbackURL() -> URL {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent(fileName)
        }

        /// Picks cloud when available, local otherwise. Never attempts cloud
        /// on the simulator — we don't want test devices stomping production.
        static func resolve() -> Storage {
            let local = localFallbackURL()
            #if targetEnvironment(simulator)
            return .local(local)
            #else
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID)
            else { return .local(local) }
            let docs = container.appendingPathComponent("Documents")
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            return .cloud(docs.appendingPathComponent(fileName))
            #endif
        }
    }
}

// MARK: - backup payload + Coders

/// The on-disk shape of the persisted store. Versioned so future migrations
/// can read older blobs.
struct BackupData: Codable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: Date
    var hosts: [Host]
    var sessions: [Session]
}

extension JSONEncoder {
    /// Encoder with stable, diff-friendly output (sorted keys + ISO 8601).
    static let telecmux: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    /// Matching decoder.
    static let telecmux: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

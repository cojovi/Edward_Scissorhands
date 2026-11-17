import Foundation
import CSQLite
import EdwardDomain

public struct WorkspacePaths: Sendable {
    public let root: URL
    public var database: URL { root.appendingPathComponent("library.sqlite") }
    public var jobs: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    public init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Edward Scissorhands", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
    }
    public func directory(for id: UUID) throws -> URL {
        let url = jobs.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var defaultExports: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Edward Scissorhands", isDirectory: true)
    }
}

public actor ProjectStore {
    public nonisolated let paths: WorkspacePaths
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public private(set) var recoveryNotice: String?

    public init(paths: WorkspacePaths) throws {
        self.paths = paths
        encoder.outputFormatting = [.sortedKeys]
        var connection: OpaquePointer?
        guard sqlite3_open_v2(paths.database.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw EdwardError.invalidInput("Could not open the project library.")
        }
        db = connection
        sqlite3_busy_timeout(connection, 5000)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, updated REAL NOT NULL, body BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS settings (id TEXT PRIMARY KEY, body BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS usage (id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE, body BLOB NOT NULL);
        PRAGMA user_version=1;
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(connection)); sqlite3_close(connection); db = nil
            throw EdwardError.invalidInput("Could not initialize the project library: \(detail)")
        }
    }
    deinit { sqlite3_close(db) }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    private func failure() -> EdwardError { .invalidInput("Library error: \(String(cString: sqlite3_errmsg(db)))") }
    private func bind(_ data: Data, to stmt: OpaquePointer, at index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) }
    }
    private func data(_ stmt: OpaquePointer, column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    public func save(_ job: JobCheckpoint) throws {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw failure() }
        do {
            let stmt = try statement("INSERT INTO jobs(id,updated,body) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET updated=excluded.updated,body=excluded.body")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, job.id.uuidString, -1, transient)
            sqlite3_bind_double(stmt, 2, job.updatedAt.timeIntervalSince1970)
            bind(try encoder.encode(job), to: stmt, at: 3)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            for usage in job.usage {
                let u = try statement("INSERT OR IGNORE INTO usage(id,job_id,body) VALUES(?,?,?)")
                defer { sqlite3_finalize(u) }
                sqlite3_bind_text(u, 1, usage.id.uuidString, -1, transient)
                sqlite3_bind_text(u, 2, job.id.uuidString, -1, transient)
                bind(try encoder.encode(usage), to: u, at: 3)
                guard sqlite3_step(u) == SQLITE_DONE else { throw failure() }
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure() }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error
        }
        do { try writeRecoverySnapshot(job) }
        catch { throw EdwardError.invalidInput("The project was saved, but its recovery copy could not be written. Check free disk space and resume.") }
    }

    /// Independent, atomic copies of each job protect its transcript, settings and stage state
    /// if an individual library row becomes unreadable. Original media remain in place.
    private func writeRecoverySnapshot(_ job: JobCheckpoint) throws {
        let folder = try paths.directory(for: job.id).appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let current = folder.appendingPathComponent("checkpoint.json")
        let previous = folder.appendingPathComponent("checkpoint-previous.json")
        let updated = try encoder.encode(job)
        if let existing = try? Data(contentsOf: current),
           let decoded = try? decoder.decode(JobCheckpoint.self, from: existing), decoded.id == job.id {
            if existing == updated { return }
            try existing.write(to: previous, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
        }
        try updated.write(to: current, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
    }

    private func recoverySnapshot(for id: UUID) -> JobCheckpoint? {
        let folder = paths.jobs.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("Recovery", isDirectory: true)
        for name in ["checkpoint.json", "checkpoint-previous.json"] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let job = try? decoder.decode(JobCheckpoint.self, from: data), job.id == id else { continue }
            return job
        }
        return nil
    }
    public func loadJobs() throws -> [JobCheckpoint] {
        let stmt = try statement("SELECT id,body FROM jobs ORDER BY updated DESC")
        defer { sqlite3_finalize(stmt) }
        var result: [JobCheckpoint] = []; var recovered = 0; var backupFailures = 0
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: idText)) else {
                throw EdwardError.invalidInput("A project in the library has an invalid identifier. Existing files have been preserved.")
            }
            let job: JobCheckpoint; let loadedFromLibrary: Bool
            if let decoded = try? decoder.decode(JobCheckpoint.self, from: data(stmt, column: 1)), decoded.id == id {
                job = decoded; loadedFromLibrary = true
            } else if let saved = recoverySnapshot(for: id) {
                job = saved; loadedFromLibrary = false; recovered += 1
            } else {
                throw EdwardError.invalidInput("A project in the library is unreadable and has no usable recovery copy. Existing files have been preserved.")
            }
            result.append(job)
            // Backfill old projects and repair missing or stale recovery copies from valid rows.
            if loadedFromLibrary {
                do { try writeRecoverySnapshot(job) } catch { backupFailures += 1 }
            }
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        var notices: [String] = []
        if recovered > 0 { notices.append("Recovered \(recovered) project(s) from saved checkpoints. Check their state before resuming.") }
        if backupFailures > 0 { notices.append("Could not create \(backupFailures) project recovery copy/copies. Check free disk space.") }
        recoveryNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
        return result
    }
    public func deleteJob(_ id: UUID) throws {
        let stmt = try statement("DELETE FROM jobs WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        // Exports and original media intentionally remain user-owned.
    }
    public func saveSettings(_ settings: AppSettings) throws {
        let stmt = try statement("INSERT INTO settings(id,body) VALUES('app',?) ON CONFLICT(id) DO UPDATE SET body=excluded.body")
        defer { sqlite3_finalize(stmt) }
        bind(try encoder.encode(settings), to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func loadSettings() throws -> AppSettings? {
        let stmt = try statement("SELECT body FROM settings WHERE id='app'")
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        return try decoder.decode(AppSettings.self, from: data(stmt, column: 0))
    }
}

import XCTest
import CSQLite
import EdwardDomain
import EdwardPersistence

final class PersistenceTests: XCTestCase {
    func testCheckpointRoundTripAndUsageDeduplication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProjectStore(paths: WorkspacePaths(root: directory))
        var job = JobCheckpoint(source: "/tmp/input.mp4", configuration: .init(outputDirectory: directory))
        job.stage = .render; job.completedStages = [.ingest, .probe, .transcribe, .select]
        job.usage = [.init(providerID: "test", model: "fixture", inputTokens: 42)]
        try await store.save(job); try await store.save(job)
        let restored = try await store.loadJobs()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].stage, .render)
        XCTAssertEqual(restored[0].usage.count, 1)
        var settings = AppSettings(outputDirectory: directory)
        settings.preset.topic = "A topic with quotes: ' and Unicode 你好"
        try await store.saveSettings(settings)
        let saved = try await store.loadSettings()
        XCTAssertEqual(saved?.preset.topic, settings.preset.topic)
        try await store.deleteJob(job.id)
        let empty = try await store.loadJobs()
        XCTAssertTrue(empty.isEmpty)
    }
    func testSentenceBoundariesKeepTimedWords() {
        let t = TimedTranscript(words: [.init(text: "Hello", start: 0, end: 0.4), .init(text: "world.", start: 0.4, end: 1), .init(text: "Next!", start: 2, end: 3)], engine: "fixture")
        XCTAssertEqual(t.sentences.count, 2)
        XCTAssertEqual(t.sentences[0].range.end, 1)
        XCTAssertEqual(t.sentences[1].text, "Next!")
    }

    func testUnreadableLibraryRowRecoversPreviousCheckpointWithoutDeletingSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = try WorkspacePaths(root: directory)
        let store = try ProjectStore(paths: paths)
        let source = directory.appendingPathComponent("source.mp4")
        try Data("original media".utf8).write(to: source)
        var job = JobCheckpoint(source: source.path, configuration: .init(outputDirectory: directory))
        job.transcript = .init(words: [.init(text: "Saved.", start: 0, end: 1)], engine: "fixture")
        job.stage = .transcribe; job.completedStages = [.ingest, .probe, .transcribe]
        try await store.save(job)
        job.stage = .select; try await store.save(job)
        let recovery = paths.jobs.appendingPathComponent(job.id.uuidString).appendingPathComponent("Recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("checkpoint-previous.json").path))
        // Damage both the database row and the latest snapshot; the prior generation must survive.
        try Data("broken".utf8).write(to: recovery.appendingPathComponent("checkpoint.json"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(paths.database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "UPDATE jobs SET body=x'00' WHERE id='\(job.id.uuidString)'"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let recovered = try await store.loadJobs()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].stage, .transcribe)
        XCTAssertEqual(recovered[0].transcript?.words.first?.text, "Saved.")
        let notice = await store.recoveryNotice
        XCTAssertTrue(notice?.contains("Recovered 1") == true)
        XCTAssertEqual(try Data(contentsOf: source), Data("original media".utf8))
    }
}

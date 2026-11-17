import Foundation
import EdwardDomain

final class OwnedProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    func run(executable: URL, arguments: [String], directory: URL) async throws -> String {
        let out = Pipe(); let err = Pipe()
        process.executableURL = executable; process.arguments = arguments
        let inherited = ProcessInfo.processInfo.environment
        process.environment = Dictionary(uniqueKeysWithValues: ["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "HF_HOME", "HF_HUB_CACHE"].compactMap { key in inherited[key].map { (key, $0) } })
        process.currentDirectoryURL = directory
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            let wasCancelled = lock.withLock { cancelled }
            if wasCancelled { stop() }
            async let stdout = Self.read(out.fileHandleForReading)
            async let stderr = Self.read(err.fileHandleForReading)
            while process.isRunning {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let text = await stdout; let errors = await stderr
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw EdwardError.media("\(executable.lastPathComponent) failed (\(process.terminationStatus)). \(errors.suffix(2500))")
            }
            return text
        } onCancel: { self.stop() }
    }
    private static func read(_ handle: FileHandle) async -> String {
        await Task.detached(priority: .utility) {
            var tail = Data()
            while let data = try? handle.read(upToCount: 16_384), !data.isEmpty {
                tail.append(data)
                if tail.count > 65_536 { tail.removeFirst(tail.count - 65_536) }
            }
            return String(decoding: tail, as: UTF8.self)
        }.value
    }
    private func stop() {
        lock.lock(); cancelled = true; let running = process.isRunning; lock.unlock()
        guard running else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

enum MediaTools {
    static func executable(_ name: String) -> URL? {
        let fm = FileManager.default
        var candidates = [URL]()
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("bin/\(name)")) }
        if let binary = Bundle.main.executableURL { candidates.append(binary.deletingLastPathComponent().appendingPathComponent(name)) }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".tools/\(name)"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/debug/\(name)"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/out/Products/Debug/\(name)"))
        candidates += ["/opt/homebrew/bin", "/usr/local/bin", "\(fm.homeDirectoryForCurrentUser.path)/homebrew/bin", "/usr/bin"].map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}

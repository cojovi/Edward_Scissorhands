import Foundation
import CryptoKit
import EdwardDomain

enum SourceIdentity {
    private struct Stamp: Equatable {
        let path: String
        let size: Int64
        let modified: Date
        let inode: UInt64
        let device: UInt64
    }

    /// A streaming content hash bounds memory independently of the length of the source video.
    static func fingerprint(_ url: URL) async throws -> String {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let before = try stamp(url)
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: before.path))
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            try Task.checkCancellation()
            guard try stamp(url) == before else {
                throw EdwardError.invalidInput("The source video changed while it was being verified. Wait for the file copy or edit to finish, then resume.")
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private static func stamp(_ url: URL) throws -> Stamp {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else {
            throw EdwardError.invalidInput("The source must be a readable regular video file before it can be verified.")
        }
        return .init(path: resolved.path, size: size.int64Value, modified: modified, inode: inode.uint64Value, device: device.uint64Value)
    }
}

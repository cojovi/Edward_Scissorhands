import Foundation
import EdwardMedia

@main
struct EdwardMediaWorker {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: EdwardMediaWorker /absolute/request.json\n".utf8)); exit(2)
        }
        do { try await LocalTranscriptionWorker.run(requestURL: URL(fileURLWithPath: CommandLine.arguments[1])) }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}

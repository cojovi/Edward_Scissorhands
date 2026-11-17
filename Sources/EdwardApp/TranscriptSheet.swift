import SwiftUI
import EdwardDomain

struct TranscriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let job: JobCheckpoint
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 6) { Eyebrow(text: "Source transcript", color: Studio.green); Text(job.title).font(.system(size: 21, weight: .semibold)).lineLimit(1) }; Spacer(); Button("Close") { dismiss() }.buttonStyle(SignalButton()) }
            Text(job.transcript?.engine ?? "").font(Studio.mono(10)).foregroundStyle(Studio.muted)
            TextField("Find a phrase", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach((job.transcript?.sentences ?? []).filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }) { sentence in
                        HStack(alignment: .top, spacing: 18) {
                            Text(timecode(sentence.range.start)).font(Studio.mono(10)).foregroundStyle(Studio.green).frame(width: 60, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) { if let speaker = sentence.words.first?.speaker { Text(speaker).font(Studio.mono(9)).foregroundStyle(Studio.muted) }; Text(sentence.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled) }
                        }
                    }
                }.padding(18)
            }.background(Studio.background, in: RoundedRectangle(cornerRadius: 10))
            HStack { Text("\(job.transcript?.words.count ?? 0) timed words").font(Studio.mono(10)).foregroundStyle(Studio.muted); Spacer(); Button("Copy") { model.copyTranscript(job) }.buttonStyle(SignalButton()); Button("Save as text") { model.saveTranscript(job) }.buttonStyle(SignalButton(prominent: true)) }
        }.padding(28).frame(width: 760, height: 700).background(Studio.panel).foregroundStyle(Studio.white)
    }
}

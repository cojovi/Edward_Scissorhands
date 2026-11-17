import SwiftUI
import AppKit
import AVKit
import EdwardDomain

struct ClipEditorView: View {
    @ObservedObject var model: WorkspaceModel
    let job: JobCheckpoint
    let clip: ClipResult
    @State private var title: String
    @State private var transcript: TimedTranscript
    @State private var captions: CaptionStyle
    @State private var framing: FramingMode
    @State private var included: Set<Int>
    @State private var player: AVPlayer?
    @State private var status = ""
    @State private var busy = false
    @State private var editingWords = false
    @State private var start: Double
    @State private var end: Double
    @State private var originalSentences: [TimedSentence]

    init(model: WorkspaceModel, job: JobCheckpoint, clip: ClipResult) {
        self.model = model; self.job = job; self.clip = clip
        _title = State(initialValue: clip.proposal.title)
        let t = job.transcript ?? TimedTranscript(words: [], engine: "Unknown")
        _transcript = State(initialValue: t)
        _captions = State(initialValue: clip.plan?.captions ?? job.configuration.preset.captions)
        _framing = State(initialValue: clip.plan?.framing ?? job.configuration.preset.framing)
        _start = State(initialValue: clip.proposal.start); _end = State(initialValue: clip.proposal.end)
        let visible = t.sentences.filter { $0.range.end > clip.proposal.start && $0.range.start < clip.proposal.end }
        _originalSentences = State(initialValue: visible)
        _included = State(initialValue: Set(visible.filter { sentence in clip.proposal.ranges.contains { $0.start < sentence.range.end && $0.end > sentence.range.start } }.map(\.id)))
    }
    private var sentences: [TimedSentence] {
        originalSentences.map { sentence in .init(id: sentence.id, words: transcript.words.filter { $0.start >= sentence.range.start && $0.end <= sentence.range.end }) }
    }
    private var draft: ClipProposal {
        var p = clip.proposal; p.title = title
        p.ranges = TranscriptEditing.retainedRanges(originalPieces: clip.proposal.ranges, sentences: sentences, selectedIDs: included, trim: .init(start: start, end: end))
        return p
    }
    private var speakers: [String] { Array(Set(transcript.words.compactMap(\.speaker))).sorted() }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 8) { Eyebrow(text: "The cutting room", color: Studio.green); TextField("Clip title", text: $title).textFieldStyle(.plain).font(.system(size: 23, weight: .semibold)) }
                Spacer()
                Button { model.showEditor = false } label: { Image(systemName: "xmark") }.buttonStyle(SignalButton()).keyboardShortcut(.cancelAction)
            }.padding(26)
            Divider().overlay(Studio.line)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    NativePreviewView(player: player).frame(width: 330, height: 430).background(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                    HStack { Text(timecode(draft.duration)).font(Studio.mono(18)).foregroundStyle(Studio.green); Spacer(); Button("Preview edits") { preview() }.buttonStyle(SignalButton()).disabled(busy || draft.ranges.isEmpty) }
                    Text(clip.proposal.reason).font(.system(size: 12)).foregroundStyle(Studio.muted).lineLimit(4)
                    if let output = clip.outputURL { Button("Reveal current export") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Studio.green) }
                    if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(Studio.amber).lineLimit(4) }
                }
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Eyebrow(text: "Sentence edit"); Spacer(); Button(editingWords ? "Done correcting" : "Correct words") { editingWords.toggle() }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Studio.green) }
                    Text("Keep the sentences that make the moment. Speaker changes also update caption colors and the next framing pass.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(sentences) { sentence in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Toggle("Keep sentence", isOn: Binding(get: { included.contains(sentence.id) }, set: { if $0 { included.insert(sentence.id) } else { included.remove(sentence.id) } })).labelsHidden().toggleStyle(.checkbox)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(sentence.text).font(.system(size: 12)).foregroundStyle(included.contains(sentence.id) ? Studio.white : Studio.muted).fixedSize(horizontal: false, vertical: true)
                                            HStack {
                                                Text(timecode(sentence.range.start)).font(Studio.mono(9)).foregroundStyle(Studio.muted)
                                                Spacer()
                                                Menu(sentence.words.first?.speaker ?? "Speaker") {
                                                    ForEach(speakers, id: \.self) { speaker in Button(speaker) { assign(sentence, to: speaker) } }
                                                    Button("Speaker 1") { assign(sentence, to: "speaker_0") }
                                                    Button("Speaker 2") { assign(sentence, to: "speaker_1") }
                                                    Button("Unassigned") { assign(sentence, to: nil) }
                                                }.font(.system(size: 9)).menuStyle(.borderlessButton).frame(width: 110)
                                            }
                                        }
                                    }
                                    if editingWords {
                                        ForEach(transcript.words.indices.filter { transcript.words[$0].start >= sentence.range.start && transcript.words[$0].end <= sentence.range.end }, id: \.self) { i in
                                            HStack { Text(timecode(transcript.words[i].start)).font(Studio.mono(9)).foregroundStyle(Studio.muted); TextField("Word", text: $transcript.words[i].text).textFieldStyle(.roundedBorder).font(.system(size: 11)) }
                                        }
                                    }
                                }.padding(12).background(Studio.panel, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }.frame(maxHeight: .infinity)
                    HStack { Button("Keep all") { included = Set(sentences.map(\.id)) }; Button("Swap speakers") { swapSpeakers() }.disabled(speakers.count != 2); Spacer(); Text("\(included.count) sentences").font(Studio.mono(10)).foregroundStyle(Studio.muted) }.font(.system(size: 11))
                    HStack { Text("Trim"); TextField("Start", value: $start, format: .number.precision(.fractionLength(2))).frame(width: 75); Text("to"); TextField("End", value: $end, format: .number.precision(.fractionLength(2))).frame(width: 75); Text("source seconds").foregroundStyle(Studio.muted) }.font(.system(size: 11)).textFieldStyle(.roundedBorder)
                    HStack { Toggle("Captions", isOn: $captions.enabled); Toggle("Top", isOn: $captions.atTop); Toggle("Speaker colors", isOn: $captions.speakerColors) }.font(.system(size: 11)).controlSize(.small)
                    Picker("Framing", selection: $framing) { Text("Follow speaker").tag(FramingMode.speaker); Text("Preserve full content").tag(FramingMode.preserve) }.font(.system(size: 11))
                }.frame(maxWidth: .infinity)
            }.padding(26)
            Divider().overlay(Studio.line)
            HStack {
                Text("Local edits reuse your existing AI analysis.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                Spacer()
                Button("Save & render") {
                    model.perform {
                        guard start.isFinite, end.isFinite, end > start, draft.duration > 0 else { throw EdwardError.invalidInput("Keep at least one sentence and choose valid trim bounds.") }
                        try await model.coordinator.updateClip(jobID: job.id, clip: draft, transcript: transcript, captions: captions, framing: framing)
                        model.showEditor = false; model.coordinator.start()
                    }
                }.buttonStyle(SignalButton(prominent: true)).disabled(busy || draft.ranges.isEmpty)
            }.padding(22)
        }.frame(width: 980, height: 800).background(Studio.background).foregroundStyle(Studio.white).tint(Studio.green)
            .task {
                if let output = clip.outputURL { player = AVPlayer(url: output); status = "Showing saved export. Preview edits to refresh." }
                else { preview() }
            }
            .onDisappear { player?.pause() }
    }
    private func assign(_ sentence: TimedSentence, to speaker: String?) {
        for i in transcript.words.indices where transcript.words[i].start >= sentence.range.start && transcript.words[i].end <= sentence.range.end { transcript.words[i].speaker = speaker }
    }
    private func swapSpeakers() {
        guard speakers.count == 2 else { return }
        let a = speakers[0]; let b = speakers[1]
        for i in transcript.words.indices {
            if transcript.words[i].speaker == a { transcript.words[i].speaker = b }
            else if transcript.words[i].speaker == b { transcript.words[i].speaker = a }
        }
    }
    private func preview() {
        guard let asset = job.asset, !draft.ranges.isEmpty else { return }
        busy = true; player?.pause(); status = "Preparing the edited preview…"
        let proposal = draft
        Task {
            defer { busy = false }
            do {
                let keys = framing == .speaker ? try await model.coordinator.media.track(asset: asset, clip: proposal, transcript: transcript) : []
                let plan = RenderPlan(sourceURL: asset.url, outputURL: URL(fileURLWithPath: "/dev/null"), clip: proposal, transcript: transcript, canvas: job.configuration.preset.canvas, framing: framing, cropKeyframes: keys, captions: captions)
                let item = try await model.coordinator.media.preview(plan: plan)
                player = AVPlayer(playerItem: item); status = "Preview uses the same composition as export."
            } catch { status = error.localizedDescription }
        }
    }
}

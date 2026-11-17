import SwiftUI
import AppKit
import EdwardDomain
import EdwardJobs
import EdwardProviders

struct PresetInspector: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack { Eyebrow(text: "Cut recipe", color: Studio.green); Spacer(); Image(systemName: "slider.horizontal.3").foregroundStyle(Studio.muted) }
                VStack(alignment: .leading, spacing: 9) {
                    Text("Start with a preset").font(.system(size: 13, weight: .semibold))
                    Picker("Preset", selection: Binding(get: { model.settings.preset.id }, set: { id in if let p = model.settings.savedPresets.first(where: { $0.id == id }) { model.settings.preset = p; model.saveSettings() } })) {
                        ForEach(model.settings.savedPresets) { Text($0.name).tag($0.id) }
                    }.labelsHidden().pickerStyle(.menu)
                }
                Divider().overlay(Studio.line)
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Text("Clip count").font(.system(size: 12)); Spacer(); Text("\(model.settings.preset.clipCount)").font(Studio.mono(17)).foregroundStyle(Studio.green) }
                    HStack {
                        Button { model.settings.preset.clipCount = max(1, model.settings.preset.clipCount - 1) } label: { Image(systemName: "minus") }.buttonStyle(SignalButton()).help("Fewer clips")
                        Spacer()
                        Text("MOMENTS PER SOURCE").font(Studio.mono(8)).foregroundStyle(Studio.muted)
                        Spacer()
                        Button { model.settings.preset.clipCount = min(30, model.settings.preset.clipCount + 1) } label: { Image(systemName: "plus") }.buttonStyle(SignalButton()).help("More clips")
                    }
                    HStack { field("MIN SEC", value: $model.settings.preset.minDuration); Text("—").foregroundStyle(Studio.muted); field("MAX SEC", value: $model.settings.preset.maxDuration) }
                    Text("Complete thoughts. Fewer clips when the source has fewer strong moments.").font(.system(size: 10)).lineSpacing(3).foregroundStyle(Studio.muted)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Creative direction")
                    TextEditor(text: $model.settings.preset.topic).font(.system(size: 12)).scrollContentBackground(.hidden).padding(8).frame(height: 82).background(Studio.background, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
                    Text("A topic, guest, question, or moment to look for.").font(.system(size: 10)).foregroundStyle(Studio.muted)
                }
                VStack(alignment: .leading, spacing: 13) {
                    Eyebrow(text: "Delivery")
                    Picker("Frame", selection: $model.settings.preset.canvas) { Text("9:16 Vertical").tag(CanvasFormat.vertical); Text("1:1 Square").tag(CanvasFormat.square); Text("16:9 Wide").tag(CanvasFormat.landscape) }.font(.system(size: 11))
                    Picker("Framing", selection: $model.settings.preset.framing) { Text("Follow speaker").tag(FramingMode.speaker); Text("Preserve content").tag(FramingMode.preserve) }.font(.system(size: 11))
                    Picker("Quality", selection: $model.settings.preset.quality) { ForEach(VideoQuality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.font(.system(size: 11))
                    Toggle("Word captions", isOn: $model.settings.preset.captions.enabled)
                    Toggle("Export automatically", isOn: $model.settings.preset.automaticExport)
                }.font(.system(size: 11)).toggleStyle(.switch).controlSize(.small)
                Divider().overlay(Studio.line)
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Editorial engine")
                    Picker("AI", selection: $model.settings.selectedProviderID) { ForEach(model.settings.providers) { Text($0.name).tag($0.id) } }.labelsHidden()
                    Text(model.settings.jobConfiguration.editorial.model.isEmpty ? "Choose a model in AI connections." : model.settings.jobConfiguration.editorial.model).font(Studio.mono(9)).foregroundStyle(model.settings.jobConfiguration.editorial.model.isEmpty ? Studio.amber : Studio.muted).lineLimit(2)
                    Button("Configure connections →") { model.section = .providers }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Studio.green)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(text: "Save location")
                    Button { model.chooseOutput() } label: { Label(model.settings.outputDirectory.lastPathComponent, systemImage: "folder").font(.system(size: 11)).lineLimit(1) }.buttonStyle(.plain).foregroundStyle(Studio.muted)
                }
                Text("Changes apply to new sources and unprocessed queued sources at batch start.").font(.system(size: 10)).foregroundStyle(Studio.muted)
            }.padding(23)
        }.background(Studio.pine)
            .onChange(of: model.settings.preset) { _, _ in model.saveSettings() }
            .onChange(of: model.settings.selectedProviderID) { _, _ in model.saveSettings() }
    }
    private func field(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: title)
            TextField(title, value: value, format: .number).textFieldStyle(.plain).font(Studio.mono(15)).padding(10).background(Studio.background, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Studio.line))
        }
    }
}

struct ProviderSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var selected = "openai"
    @State private var key = ""
    @State private var status = ""
    @State private var models: [ProviderModel] = []
    @State private var checking = false
    private var index: Int { model.settings.providers.firstIndex { $0.id == selected } ?? 0 }
    private var config: Binding<ProviderConfiguration> { $model.settings.providers[index] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Choose the intelligence behind your cuts.").font(.system(size: 20, weight: .medium))
                Text("Connect your own API account or a local Ollama server. Keys stay in macOS Keychain. There is no Setapp integration or credit system.").font(.system(size: 13)).foregroundStyle(Studio.muted)
                ScrollView(.horizontal) { HStack(spacing: 8) {
                    ForEach(model.settings.providers) { provider in
                        Button(provider.name) { selected = provider.id; key = ""; status = ""; models = [] }.buttonStyle(SignalButton(prominent: selected == provider.id))
                    }
                    Menu("Add profile") {
                        ForEach(ProviderKind.allCases, id: \.self) { kind in
                            Button(kind.title) {
                                var profile = ProviderConfiguration.defaults.first { $0.kind == kind }!
                                profile.id = UUID().uuidString; profile.name = "\(kind.title) \(model.settings.providers.filter { $0.kind == kind }.count + 1)"
                                model.settings.providers.append(profile); selected = profile.id; key = ""; models = []; status = "New profile created. Choose its model and credentials."; model.saveSettings()
                            }
                        }
                    }.menuStyle(.borderlessButton).frame(width: 110)
                } }
                Panel {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack { Eyebrow(text: config.wrappedValue.name, color: Studio.green); Spacer(); Text(config.wrappedValue.kind == .ollama ? "LOCAL MODEL" : config.wrappedValue.isLocal ? "LOCAL ENDPOINT" : "YOUR API ACCOUNT").font(Studio.mono(9)).foregroundStyle(Studio.muted) }
                        labeled("Profile name") { TextField("Profile name", text: config.name).textFieldStyle(.roundedBorder) }
                        labeled("Endpoint URL") { TextField("https://…", text: config.baseURL).textFieldStyle(.roundedBorder) }
                        if config.wrappedValue.kind != .ollama {
                            labeled("API key") {
                                HStack {
                                    SecureField("Enter a key to save or replace", text: $key).textFieldStyle(.roundedBorder)
                                    Button("Save key") {
                                        do { try KeychainStore.save(key, providerID: selected); key = ""; status = "Key saved in macOS Keychain."; model.saveSettings() } catch { status = error.localizedDescription }
                                    }.disabled(key.isEmpty)
                                    Button("Remove") { do { try KeychainStore.delete(providerID: selected); status = "Saved key removed." } catch { status = error.localizedDescription } }
                                }
                            }
                        }
                        labeled("Model ID") {
                            HStack {
                                TextField("Enter a compatible model ID", text: config.model).textFieldStyle(.roundedBorder)
                                if !models.isEmpty {
                                    Menu("Discovered models") { ForEach(models) { m in Button(m.name) { config.wrappedValue.model = m.id; model.saveSettings() } } }
                                }
                            }
                        }
                        HStack {
                            Button { testConnection() } label: { Label(checking ? "Checking…" : "Test connection & list models", systemImage: "antenna.radiowaves.left.and.right") }.buttonStyle(SignalButton()).disabled(checking)
                            Spacer()
                            Button("Use for clip selection") { model.settings.selectedProviderID = selected; model.saveSettings(); status = "Selected for new batches." }.buttonStyle(SignalButton(prominent: true)).disabled(config.wrappedValue.model.isEmpty)
                        }
                        if !status.isEmpty { Text(status).font(.system(size: 12)).foregroundStyle(Studio.amber).textSelection(.enabled) }
                        Divider().overlay(Studio.line)
                        Text("Model capabilities").font(.system(size: 13, weight: .semibold))
                        Text("Enable only capabilities supported by this exact model. A successful connection confirms credentials and model discovery, not inference quality.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                        HStack { Toggle("Text", isOn: config.capabilities.text); Toggle("Images", isOn: config.capabilities.images); Toggle("Structured output", isOn: config.capabilities.structuredOutput) }.font(.system(size: 12))
                        if config.wrappedValue.kind != .ollama {
                            HStack {
                                price("Input / 1M tokens ($)", value: config.inputCostPerMillion)
                                price("Output / 1M tokens ($)", value: config.outputCostPerMillion)
                            }
                            Text("Enter the rates from your provider account to enforce the estimated spending ceiling. Provider billing remains authoritative.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                            if config.wrappedValue.isLocal { Text("A local endpoint can forward requests to a cloud service. Configure its key and token rates if needed; Edward cannot inspect the server's upstream routing.").font(.system(size: 11)).foregroundStyle(Studio.muted) }
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        Eyebrow(text: "Independent stages", color: Studio.green)
                        Picker("Local transcription", selection: $model.settings.transcription) {
                            Text("FluidAudio · local speech + speakers").tag(TranscriptionEngine.fluidAudio)
                            Text("WhisperKit · local multilingual").tag(TranscriptionEngine.whisperKit)
                            Text("Import a timed transcript").tag(TranscriptionEngine.importedTranscript)
                        }
                        TextField("Local model ID (empty uses engine default)", text: $model.settings.transcriptionModel).textFieldStyle(.roundedBorder)
                        Text("Speech models download on first use and are cached on your Mac. SRT imports interpolate word timing; JSON can preserve exact word timestamps.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                        Picker("Optional visual review", selection: Binding(get: { model.settings.visualProviderID ?? "none" }, set: { model.settings.visualProviderID = $0 == "none" ? nil : $0 })) {
                            Text("Off · local framing only").tag("none")
                            ForEach(model.settings.providers.filter { $0.capabilities.images }) { Text("\($0.name) · \($0.model)").tag($0.id) }
                        }
                        Text("Visual review sends selected JPEG frames and transcript context to the chosen provider. Local framing and export stay on your Mac.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                        Button("Save configuration") { model.saveSettings(); status = "Configuration saved." }.buttonStyle(SignalButton(prominent: true))
                    }
                }
            }.padding(30).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity)
        }.onDisappear { model.saveSettings() }
    }
    private func testConnection() {
        checking = true; model.saveSettings(); let configuration = config.wrappedValue
        Task {
            defer { checking = false }
            do { let result = try await model.coordinator.providers.testConnection(configuration: configuration); models = result.models; status = result.message }
            catch { status = error.localizedDescription }
        }
    }
    private func labeled<C: View>(_ text: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Studio.muted); content() }
    }
    private func price(_ title: String, value: Binding<Double?>) -> some View {
        labeled(title) {
            TextField("Unknown", text: Binding(get: { value.wrappedValue.map { String($0) } ?? "" }, set: { value.wrappedValue = Double($0) })).textFieldStyle(.roundedBorder)
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Panel {
                    VStack(alignment: .leading, spacing: 17) {
                        Eyebrow(text: "Editorial defaults", color: Studio.green)
                        Text("Always ask for").font(.system(size: 17, weight: .semibold))
                        Text("An audience, editorial preference, or content to skip. Combined with the direction for each batch.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                        TextEditor(text: $model.settings.standingPrompt).font(.system(size: 13)).frame(height: 90).scrollContentBackground(.hidden).padding(10).background(Studio.background, in: RoundedRectangle(cornerRadius: 7))
                        Toggle("Recognize speakers", isOn: $model.settings.preset.recognizeSpeakers)
                        Toggle("Remove pauses and filler sounds", isOn: $model.settings.preset.removeFillersAndPauses)
                        Text("Removes isolated um/uh sounds and long gaps using transcript timing. Review results for natural pacing.").font(.system(size: 11)).foregroundStyle(Studio.muted)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        Eyebrow(text: "Caption system", color: Studio.green)
                        Toggle("Burn word captions into video", isOn: $model.settings.preset.captions.enabled)
                        Toggle("Color captions by speaker", isOn: $model.settings.preset.captions.speakerColors)
                        Toggle("Place captions near the top", isOn: $model.settings.preset.captions.atTop)
                        HStack { Text("Font size"); Slider(value: $model.settings.preset.captions.fontSize, in: 28...90); Text("\(Int(model.settings.preset.captions.fontSize))").font(Studio.mono()) }
                        Stepper("Words per line: \(model.settings.preset.captions.wordsPerLine)", value: $model.settings.preset.captions.wordsPerLine, in: 2...9)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        Eyebrow(text: "Exports & costs", color: Studio.green)
                        HStack { Text(model.settings.outputDirectory.path).font(.system(size: 12)).foregroundStyle(Studio.muted); Spacer(); Button("Choose folder") { model.chooseOutput() } }
                        Toggle("Reveal exports when finished", isOn: $model.settings.revealWhenFinished)
                        Toggle("Play a sound when finished", isOn: $model.settings.soundWhenFinished)
                        HStack { Text("Estimated spending ceiling per source ($)"); TextField("USD", value: $model.settings.budgetUSD, format: .number).frame(width: 80).textFieldStyle(.roundedBorder) }
                        Toggle("Allow paid processing when token prices are unknown", isOn: $model.settings.allowUnknownCost)
                        if model.settings.allowUnknownCost { Text("A spending ceiling cannot be enforced without prices. Such batches require an explicit confirmation before starting.").font(.system(size: 11)).foregroundStyle(Studio.amber) }
                    }
                }
                HStack {
                    Button("Save preferences") { model.saveSettings() }.buttonStyle(SignalButton(prominent: true))
                    Button("Export diagnostics") { model.saveDiagnostics() }.buttonStyle(SignalButton())
                    Button("Welcome guide") { model.showWelcome = true }.buttonStyle(SignalButton())
                }
            }.padding(30).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.font(.system(size: 13)).toggleStyle(.switch).onDisappear { model.saveSettings() }
    }
}

struct PresetsView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var name = ""
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your repeatable recipes.").font(.system(size: 24, weight: .semibold))
                    Text("Tune a recipe in the inspector, then save it for the next batch.").foregroundStyle(Studio.muted)
                    ForEach(model.settings.savedPresets) { preset in
                        Button { model.settings.preset = preset; model.saveSettings() } label: {
                            Panel {
                                HStack { Image(systemName: preset.framing == .preserve ? "rectangle.inset.filled" : "person.crop.rectangle").font(.system(size: 25)).foregroundStyle(Studio.green); VStack(alignment: .leading, spacing: 6) { Text(preset.name).font(.system(size: 16, weight: .semibold)); Text("\(preset.clipCount) clips · \(Int(preset.minDuration))–\(Int(preset.maxDuration)) sec · \(preset.canvas.rawValue)").font(Studio.mono(10)).foregroundStyle(Studio.muted) }; Spacer(); Image(systemName: "arrow.up.right") }
                            }
                        }.buttonStyle(.plain)
                    }
                    HStack { TextField("Name your recipe", text: $name).textFieldStyle(.roundedBorder); Button("Save as new preset") { var p = model.settings.preset; p.id = UUID().uuidString; p.name = name; model.settings.savedPresets.append(p); model.settings.preset = p; model.saveSettings(); name = "" }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty).buttonStyle(SignalButton(prominent: true)) }
                }.padding(30)
            }
            PresetInspector(model: model).frame(width: 286)
        }
    }
}

struct BatchReviewSheet: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var coordinator: JobCoordinator
    @State private var unknownConsent = false
    @State private var error: String?
    private var config: JobConfiguration { model.settings.jobConfiguration }
    private var providers: [ProviderConfiguration] { [config.editorial, config.visual].compactMap { $0 } }
    private var allOllama: Bool { providers.allSatisfy { $0.kind == .ollama } }
    private var uploads: String {
        if allOllama { return "None · local models only" }
        if providers.allSatisfy(\.isLocal) { return "Local endpoint · its server controls onward uploads" }
        return config.visual != nil ? "Transcript + selected JPEG frames" : "Transcript only"
    }
    private var spending: String {
        if allOllama { return "$0 · local inference" }
        if unknownCost { return "Unknown · prices required for a ceiling" }
        if providers.allSatisfy({ $0.isLocal && ($0.inputCostPerMillion ?? 0) == 0 && ($0.outputCostPerMillion ?? 0) == 0 }) { return "$0 configured · verify your local server's billing" }
        return String(format: "Up to $%.2f estimated", config.budgetUSD)
    }
    private var unknownCost: Bool {
        [config.editorial, config.visual].compactMap { $0 }.contains { !$0.isLocal && ($0.inputCostPerMillion == nil || $0.outputCostPerMillion == nil) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Eyebrow(text: "Ready to roll", color: Studio.green)
            Text("Review your batch.").font(.system(size: 29, weight: .semibold))
            Text("\(coordinator.jobs.filter { $0.state == .queued }.count) queued sources · up to \(config.preset.clipCount) clips each").foregroundStyle(Studio.muted)
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    row("Transcription", config.transcription.rawValue + " · local")
                    row("Clip selection", "\(config.editorial.name) / \(config.editorial.model.isEmpty ? "No model selected" : config.editorial.model)")
                    row("Visual review", config.visual.map { "\($0.name) / \($0.model)" } ?? "Off")
                    row("Uploads", uploads)
                    row("Spend per source", spending)
                }
            }
            if unknownCost {
                if config.allowUnknownCost {
                    Toggle("I understand that an enforceable cost ceiling is unavailable for this batch.", isOn: $unknownConsent).font(.system(size: 12))
                } else { Text("Add token prices in AI connections, or explicitly enable unknown-cost processing in Preferences.").font(.system(size: 12)).foregroundStyle(Studio.amber) }
            }
            Text("The first local transcription run may download model files. Completed stages and AI results are saved for recovery.").font(.system(size: 11)).foregroundStyle(Studio.muted)
            if providers.contains(where: { $0.kind == .gemini }) {
                Text("If Gemini reaches its output limit, Edward may retry that part once with a larger allowance. The retry uses the same selected provider and may incur additional charges; your configured spending settings still apply.")
                    .font(.system(size: 11)).foregroundStyle(Studio.muted)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Studio.amber) }
            HStack {
                Button("Back") { model.showStart = false }.buttonStyle(SignalButton())
                Spacer()
                Button("Start batch") {
                    Task {
                        do {
                            guard !config.editorial.model.isEmpty else { throw EdwardError.invalidInput("Select a model in AI connections first.") }
                            for provider in providers {
                                guard !provider.model.isEmpty else { throw EdwardError.invalidInput("Choose a model for \(provider.name) first.") }
                                guard provider.capabilities.text && provider.capabilities.structuredOutput else { throw EdwardError.invalidInput("\(provider.name) must support text and structured output for this workflow.") }
                                if !provider.isLocal { guard try KeychainStore.read(providerID: provider.id) != nil else { throw EdwardError.invalidInput("Save your \(provider.name) API key in AI connections first.") } }
                            }
                            try await coordinator.configureQueued(config)
                            model.saveSettings(); model.showStart = false; coordinator.start()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(SignalButton(prominent: true)).disabled(unknownCost && (!config.allowUnknownCost || !unknownConsent))
            }
        }.padding(30).frame(width: 570).background(Studio.panel)
    }
    private func row(_ title: String, _ value: String) -> some View { HStack(alignment: .top) { Text(title).foregroundStyle(Studio.muted).frame(width: 110, alignment: .leading); Text(value).textSelection(.enabled); Spacer(minLength: 0) }.font(.system(size: 12)) }
}

struct WelcomeSheet: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            BrandMark(size: 64)
            Eyebrow(text: "Welcome to your private studio", color: Studio.green)
            Text("Every great story\nhas a sharper cut.").font(.system(size: 36, weight: .semibold, design: .rounded)).tracking(-1)
            VStack(alignment: .leading, spacing: 20) {
                step("01", "Connect your intelligence", "Use your API keys or a local Ollama model. No Setapp account or credits.")
                step("02", "Bring your long-form footage", "Choose local videos or paste links. Pick a recipe and set your direction.")
                step("03", "Let the batch run", "Transcription, framing, captions and exports—saved as a resumable project.")
            }
            HStack { Button("Explore the studio") { model.showWelcome = false; model.saveSettings() }.buttonStyle(SignalButton()); Spacer(); Button("Set up AI →") { model.showWelcome = false; model.section = .providers; model.saveSettings() }.buttonStyle(SignalButton(prominent: true)) }
        }.padding(36).frame(width: 550).background(Studio.panel)
    }
    private func step(_ n: String, _ title: String, _ body: String) -> some View { HStack(alignment: .top, spacing: 16) { Text(n).font(Studio.mono(15)).foregroundStyle(Studio.green); VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 14, weight: .semibold)); Text(body).font(.system(size: 12)).foregroundStyle(Studio.muted).lineSpacing(3) } } }
}

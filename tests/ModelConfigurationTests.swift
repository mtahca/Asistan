import Foundation
@main struct ModelConfigurationTests {
    static func main() throws {
        let original = "# private configuration\nANTHROPIC_API_KEY=private-example\nVAD_THRESHOLD=0.0015\nCLAUDE_MODEL=old\n CLAUDE_MODEL=duplicate\n"
        let updated = try BetaModelConfiguration.updating(original, with: ["CLAUDE_MODEL":"claude-haiku-4-5", "SUMMARY_MODEL":"claude-sonnet-5-5", "OWNER_NAME":"İpek"])
        let parsed = BetaModelConfiguration.values(in: updated)
        precondition(parsed["ANTHROPIC_API_KEY"] == "private-example")
        precondition(parsed["VAD_THRESHOLD"] == "0.0015")
        precondition(parsed["SUMMARY_MODEL"] == "claude-sonnet-5-5")
        precondition(updated.components(separatedBy: "CLAUDE_MODEL=").count == 2)
        precondition(parsed["OWNER_NAME"] == "İpek")
        do {
            _ = try BetaModelConfiguration.updating(original, with: ["OWNER_NAME":"İpek\nANTHROPIC_API_KEY=override"])
            preconditionFailure("Newline injection was accepted")
        } catch {}
        do {
            _ = try BetaModelConfiguration.updating(original, with: ["ANTHROPIC_API_KEY":"override"])
            preconditionFailure("Model settings changed a credential")
        } catch {}
        var count = 7
        func check(_ result: Bool) { precondition(result); count += 1 }
        let legacy = try BetaModelConfiguration.choices(in: ["CLAUDE_MODEL":"claude-sonnet-5-5"])
        check(legacy.conversation == legacy.summary && legacy.conversation.provider == "anthropic")
        let openai = ["LLM_PROVIDER":"openai", "OPENAI_MODEL":"gpt-6-luna", "OPENAI_API_KEY":"private-openai-example-key"]
        check(try BetaModelConfiguration.missingCredentials(in: openai).isEmpty)
        var mixed = openai; mixed["SUMMARY_PROVIDER"] = "anthropic"; mixed["SUMMARY_MODEL"] = "claude-sonnet-5-5"
        check(try BetaModelConfiguration.missingCredentials(in: mixed) == ["anthropic"])
        mixed["ANTHROPIC_API_KEY"] = "private-anthropic-example-key"
        check(try BetaModelConfiguration.missingCredentials(in: mixed).isEmpty)
        let keys = "ANTHROPIC_API_KEY=private-anthropic-example-key\nOPENAI_API_KEY=old\n OPENAI_API_KEY=duplicate\nVAD_THRESHOLD=0.003\n"
        let newKeys = try BetaModelConfiguration.updatingCredentials(keys, with: ["OPENAI_API_KEY":"private-openai-example-key"])
        let keyValues = BetaModelConfiguration.values(in: newKeys)
        check(keyValues["ANTHROPIC_API_KEY"] == "private-anthropic-example-key")
        check(keyValues["VAD_THRESHOLD"] == "0.003")
        check(newKeys.components(separatedBy: "OPENAI_API_KEY=").count == 2)
        for changes in [["OPENAI_API_KEY":"key\nOWNER_NAME=Override"], ["OPENAI_API_KEY":""], ["OWNER_NAME":"private-example-key-with-length"]] {
            do { _ = try BetaModelConfiguration.updatingCredentials(keys, with: changes); preconditionFailure("Invalid credential change accepted") } catch { count += 1 }
        }
        for values in [["LLM_PROVIDER":"other"], ["LLM_PROVIDER":"openai", "OPENAI_MODEL":"claude-haiku-4-5"], ["SUMMARY_PROVIDER":"anthropic", "SUMMARY_MODEL":"gpt-6-luna"]] {
            do { _ = try BetaModelConfiguration.choices(in: values); preconditionFailure("Invalid provider/model accepted") } catch { count += 1 }
        }
        check(try BetaModelChoice.parse("openai:gpt-6.1-sol").provider == "openai")
        check(try BetaModelConfiguration.voiceMode(in: [:]) == "local")
        var live = ["VOICE_MODE":"gpt-live", "ANTHROPIC_API_KEY":"private-anthropic-example-key"]
        check(try BetaModelConfiguration.requiredProviders(in: live) == ["anthropic", "openai"])
        check(try BetaModelConfiguration.missingCredentials(in: live) == ["openai"])
        live["OPENAI_API_KEY"] = "private-openai-example-key"
        check(try BetaModelConfiguration.missingCredentials(in: live).isEmpty)
        let liveUpdated = try BetaModelConfiguration.updating(keys, with: ["VOICE_MODE":"gpt-live"])
        check(BetaModelConfiguration.values(in: liveUpdated)["ANTHROPIC_API_KEY"] == "private-anthropic-example-key")
        check(BetaModelConfiguration.values(in: liveUpdated)["VOICE_MODE"] == "gpt-live")
        do { _ = try BetaModelConfiguration.voiceMode(in: ["VOICE_MODE":"unknown"]); preconditionFailure("Invalid voice mode accepted") } catch { count += 1 }
        check(try BetaModelConfiguration.requiredProviders(in: openai.merging(["VOICE_MODE":"gpt-live"], uniquingKeysWith: { _, new in new })) == ["openai"])
        let haiku = try BetaModelChoice.parse("anthropic:claude-haiku-5-5")
        check(BetaModelChoice.options.contains { $0.choice == haiku })
        check(try BetaModelConfiguration.choices(in: ["CLAUDE_MODEL": haiku.model]).conversation == haiku)
        check(try BetaModelConfiguration.choices(in: [:]).conversation.model == "claude-haiku-4-5")
        check(try BetaModelConfiguration.liveVoice(in: [:]) == "marin")
        let voiceUpdated = try BetaModelConfiguration.updating(keys, with: ["GPT_LIVE_VOICE": "cedar"])
        check(try BetaModelConfiguration.liveVoice(in: BetaModelConfiguration.values(in: voiceUpdated)) == "cedar")
        check(BetaModelConfiguration.values(in: voiceUpdated)["ANTHROPIC_API_KEY"] == "private-anthropic-example-key")
        check(BetaModelConfiguration.values(in: voiceUpdated)["VAD_THRESHOLD"] == "0.003")
        for voice in ["unknown", "Marin", "marin\nOPENAI_API_KEY=x"] {
            do { _ = try BetaModelConfiguration.updating(keys, with: ["GPT_LIVE_VOICE": voice]); preconditionFailure("Invalid voice accepted") } catch { count += 1 }
        }
        do { _ = try BetaModelConfiguration.requiredProviders(in: ["VOICE_MODE":"gpt-live", "GPT_LIVE_VOICE":"unknown"]); preconditionFailure("Invalid online voice accepted") } catch { count += 1 }
        // Gemini Live and the speech-to-text choices
        let gemini = ["VOICE_MODE":"gemini-live", "ANTHROPIC_API_KEY":"private-anthropic-example-key"]
        check(try BetaModelConfiguration.requiredProviders(in: gemini) == ["anthropic", "google"])
        check(try BetaModelConfiguration.missingCredentials(in: gemini) == ["google"])
        check(try BetaModelConfiguration.missingCredentials(in: gemini.merging(["GEMINI_API_KEY":"AIza-private-example-gemini-key"], uniquingKeysWith: { _, new in new })).isEmpty)
        check(try BetaModelConfiguration.geminiVoice(in: [:]) == "Kore")
        check(try BetaModelConfiguration.geminiModel(in: [:]) == "gemini-3.8-live")
        check(try BetaModelConfiguration.geminiModel(in: ["GEMINI_LIVE_MODEL":"gemini-3.1-flash-live-preview"]) == "gemini-3.8-live")
        check(BetaModelConfiguration.geminiModelTitle(in: ["GEMINI_LIVE_MODEL":"gemini-3.1-flash-live-preview"]) == "Gemini 3.8 Live")
        check(BetaModelConfiguration.geminiModels.count == 1)
        let deepgram = ["STT_BACKEND":"deepgram", "ANTHROPIC_API_KEY":"private-anthropic-example-key"]
        check(try BetaModelConfiguration.requiredProviders(in: deepgram) == ["anthropic", "deepgram"])
        check(try BetaModelConfiguration.requiredProviders(in: ["STT_BACKEND":"apple"]) == ["anthropic"])
        check(try BetaModelConfiguration.requiredProviders(in: ["STT_BACKEND":"deepgram", "VOICE_MODE":"gpt-live"]) == ["anthropic", "openai"])
        let newKeys2 = try BetaModelConfiguration.updatingCredentials(keys, with: ["DEEPGRAM_API_KEY":"private-deepgram-example-key", "GEMINI_API_KEY":"AIza-private-example-gemini-key"])
        check(BetaModelConfiguration.values(in: newKeys2)["DEEPGRAM_API_KEY"] == "private-deepgram-example-key")
        check(BetaModelConfiguration.providerTitle("google") == "Google Gemini")
        for changes in [["GEMINI_LIVE_VOICE":"kore"], ["GEMINI_LIVE_MODEL":"gemini-2.5"], ["STT_BACKEND":"siri"], ["VOICE_MODE":"other"]] {
            do { _ = try BetaModelConfiguration.updating(keys, with: changes); preconditionFailure("Invalid change accepted") } catch { count += 1 }
        }
        let geminiSaved = try BetaModelConfiguration.updating(keys, with: ["VOICE_MODE":"gemini-live", "GEMINI_LIVE_VOICE":"Aoede", "GEMINI_LIVE_MODEL":"", "STT_BACKEND":"apple"])
        check(try BetaModelConfiguration.geminiVoice(in: BetaModelConfiguration.values(in: geminiSaved)) == "Aoede")
        check(try BetaModelConfiguration.speechBackend(in: BetaModelConfiguration.values(in: geminiSaved)) == "apple")
        print("Model ayarları: \(count) kontrol başarılı.")
    }
}

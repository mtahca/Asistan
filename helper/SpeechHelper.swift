// asistan-speech: Turkish speech-to-text with Apple's on-device dictation model (SpeechAnalyzer).
// SpeechTranscriber has no Turkish; DictationTranscriber does. The Python agent starts this helper
// once and talks to it line by line on stdin/stdout:
//   out: {"ready": true} after the model is installed, or {"error": "..."} and exit
//   in:  {"path": "/tmp/utterance.wav"}   out: {"text": "..."} or {"error": "..."}
import AVFoundation
import Foundation
import Speech

func reply(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) else { return }
    print(line); fflush(stdout)
}

// SpeechAnalyzer ships with the macOS 26 SDK (Xcode 26, Swift 6.2); older toolchains build a stub
// that reports the requirement instead of failing the whole app build.
#if compiler(>=6.2)
@available(macOS 26, *)
func makeTranscriber(_ locale: Locale) -> DictationTranscriber {
    // No .shortForm hint: with it the model never marks a result final (checked on macOS 27).
    DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                         reportingOptions: [], attributeOptions: [])
}

@available(macOS 26, *)
func prepare() async throws -> Locale {
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "tr_TR")) else {
        throw HelperError("Bu Mac'te Apple Türkçe dikte modeli desteklenmiyor.")
    }
    let probe = makeTranscriber(locale)
    if await AssetInventory.status(forModules: [probe]) != .installed {
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            try await request.downloadAndInstall()
        }
    }
    // Status can stay .supported after a successful install, so only a missing or unsupported model fails.
    guard await AssetInventory.status(forModules: [probe]) >= .supported else {
        throw HelperError("Apple Türkçe dikte modeli indirilemedi. İnternet bağlantısını kontrol edin.")
    }
    return locale
}

@available(macOS 26, *)
func transcribe(_ url: URL, locale: Locale) async throws -> String {
    let transcriber = makeTranscriber(locale)
    let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
    let file = try AVAudioFile(forReading: url)
    let collector = Task {
        // Final results by range; a range that never became final keeps its latest volatile text.
        var final: [(Double, String)] = [], pending: [Double: String] = [:]
        for try await result in transcriber.results {
            let text = String(result.text.characters), start = result.range.start.seconds
            if result.isFinal { final.append((start, text)); pending[start] = nil } else { pending[start] = text }
        }
        return (final + pending.map { ($0.key, $0.value) }).sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }
    if let end = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: end)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
}

#endif

struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct SpeechHelper {
    static func main() async {
        #if compiler(>=6.2)
        guard #available(macOS 26, *) else {
            reply(["error": "Apple konuşma tanıma macOS 26 veya sonrasını gerektirir."]); exit(2)
        }
        let locale: Locale
        do { locale = try await prepare() } catch {
            reply(["error": error.localizedDescription]); exit(1)
        }
        reply(["ready": true])
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = request["path"] as? String else { reply(["error": "Geçersiz istek."]); continue }
            do { reply(["text": try await transcribe(URL(fileURLWithPath: path), locale: locale)]) }
            catch { reply(["error": "Apple konuşma tanıma başarısız: " + error.localizedDescription]) }
        }
        #else
        reply(["error": "Bu Asistan derlemesinde Apple konuşma tanıma yok; Xcode 26 veya sonrasıyla yeniden derleyin."]); exit(2)
        #endif
    }
}

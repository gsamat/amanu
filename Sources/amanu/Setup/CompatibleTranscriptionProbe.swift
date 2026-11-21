import Foundation

/// Setup checks use generated public speech, never a meeting from the archive.
enum CompatibleTranscriptionProbe {
    static let phrase = "Hello. This is an Amanu transcription test."

    enum Failure: LocalizedError {
        case unavailable(Int), refused(Int), speechToolMissing, speechFailed, noSpeech

        var errorDescription: String? {
            switch self {
            case .unavailable(let status):
                return localised("The server is unavailable (HTTP \(status)).", "Сервер недоступен (HTTP \(status)).")
            case .refused(let status):
                return localised("The server refused the token (HTTP \(status)).", "Сервер отклонил токен (HTTP \(status)).")
            case .speechToolMissing:
                return localised("macOS speech synthesis is unavailable. No recording was sent.",
                                 "Синтез речи macOS недоступен. Записи не отправлялись.")
            case .speechFailed:
                return localised("Couldn't create the test phrase. No recording was sent.",
                                 "Не удалось создать тестовую фразу. Записи не отправлялись.")
            case .noSpeech:
                return localised("The server returned no recognized words.", "Сервер не вернул распознанных слов.")
            }
        }
    }

    static func connection(baseURL: String, token: String?, session: URLSession = .shared) async throws -> String {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw OpenAICompatible.EndpointError.invalid("server URL")
        }
        let url = try OpenAICompatible.url(baseURL: baseURL, path: "")
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var (_, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 405 {
            request.httpMethod = "GET"
            (_, response) = try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.refused(status) }
        guard (200..<500).contains(status) else { throw Failure.unavailable(status) }
        return localised(
            "Server responded (HTTP \(status)). Recognition and the model have not been checked.",
            "Сервер ответил (HTTP \(status)). Распознавание и модель ещё не проверены.")
    }

    static func recognition(
        baseURL: String, model: String, token: String?, apiProtocol: String,
        session: URLSession = .shared,
        synthesize: @Sendable (URL) async throws -> Void = synthesize
    ) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amanu-server-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("public-test-phrase.aiff")
        try await synthesize(audio)
        try Task.checkCancellation()
        let engine = try CompatibleTranscriptionEngine(
            baseURL: baseURL, model: model, apiKey: token,
            apiProtocol: CompatibleTranscriptionProtocol(rawValue: apiProtocol) ?? .automatic,
            expectedLanguages: ["en"], session: session)
        let segments = try await engine.transcribe(audio)
        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noSpeech }
        return localised("Test phrase recognized: ", "Тестовая фраза распознана: ") + text
    }

    private static func synthesize(to destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { throw Failure.speechToolMissing }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-o", destination.path, phrase]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: destination.path) else { throw Failure.speechFailed }
        }.value
    }
}

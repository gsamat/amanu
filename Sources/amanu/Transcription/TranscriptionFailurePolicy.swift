import Foundation

/// What a failed transcription costs the session it happened to: an attempt,
/// its place in the queue for good, or nothing at all.
///
/// Nothing at all is for failures that belong to the machine rather than the
/// recording — the model download that did not finish, a key the service
/// refuses, a network that is not there. They used to be counted like any
/// other, so a model that would not download failed every meeting in the
/// queue once each and retired all of them on the third launch, and a Mac
/// that was offline three times running retired the meeting it recorded on
/// the train. A session failed that way keeps its attempts and waits, and is
/// offered again the next time the queue has anything to do.
enum TranscriptionFailurePolicy {
    enum Outcome: Equatable {
        /// Not the session's fault; nothing was counted.
        case environmental
        /// Counted, and the session will be offered again.
        case counted(attempts: Int)
        /// Counted for the last time: the session is retired.
        case retired
    }

    /// How many times a session may fail before the queue stops offering it.
    /// The queue lives in the filesystem and is rescanned at every launch, so
    /// without a limit a session that cannot be transcribed is retried for
    /// ever — and with a cloud engine, re-uploaded and re-charged every time.
    static let maxAttempts = 3

    static func hasGivenUp(on dir: URL) -> Bool {
        SessionState.value(dir, SessionState.Key.transcriptionFailed) != nil
    }

    /// Network-shaped failures, the ones a local engine can rescue. A bad key
    /// or a rejected file is not one of them — retrying locally would still be
    /// right, but silently swapping engines for every failure hides real
    /// problems.
    static func looksLikeNetworkTrouble(_ error: Error) -> Bool {
        let urlErrorCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
        ]
        if let urlError = error as? URLError { return urlErrorCodes.contains(urlError.code) }
        return "\(error)".contains("offline") || "\(error)".contains("timed out")
    }

    /// Whether a failure is the machine's rather than the recording's.
    static func isEnvironmental(_ error: Error) -> Bool {
        if (error as? TranscriptionFailure)?.isEnvironmental == true { return true }
        return looksLikeNetworkTrouble(error)
    }

    static func reason(for error: Error) -> Analytics.Reason {
        if looksLikeNetworkTrouble(error) { return .noNetwork }
        switch error {
        case is EnginePreparationFailed: return .noModel
        case is EngineResolver.EngineUnavailable: return .noKey
        case let failure as CloudHTTP.Failure:
            switch failure {
            case .unauthorized: return .noKey
            case .rejected: return .refused
            case .unavailable: return .httpError
            case .malformed: return .unknown
            }
        case let failure as TranscriptionFailure where failure.isEnvironmental:
            return .noKey
        case let failure as TranscriptionFailure where failure.isPermanent:
            return .refused
        default:
            return Analytics.reason(for: error)
        }
    }

    /// Count a failure against the session, and retire it once retrying has
    /// stopped being reasonable — either because the error can't be fixed by
    /// repeating it, or because we've repeated it enough. A failure of the
    /// machine is logged and counted against nothing.
    ///
    /// A retired session keeps its audio and gets it compressed: there will
    /// never be a transcript, so holding a gigabyte an hour of PCM against a
    /// future attempt is pure waste. Delete `transcription_failed` from
    /// meta.json to offer it to the queue again.
    ///
    /// `notify` is off for the second and later sessions a drain holds back
    /// for the same missing model: one banner says it, ten say it louder.
    @discardableResult
    static func record(
        _ error: Error, for dir: URL, engine: TranscriptionEngine?, notify: Bool = true
    ) -> Outcome {
        func log(_ message: String) { appendSessionLog(message, to: dir) }
        let engineName = engine?.name ?? Config.transcriptionEngine()
        func report(_ outcome: Analytics.Outcome) {
            Analytics.track(.transcriptFailed, [
                .engine: .text(engineName),
                .model: .text(AnalyticsCatalogue.transcriptionModel(
                    engine: engineName, provenance: engine?.model ?? "")),
                .reason: .text(reason(for: error).rawValue),
                .outcome: .text(outcome.rawValue),
            ])
        }

        if isEnvironmental(error) {
            SessionState.update(dir, with: [SessionState.Key.transcriptionDeferred: true])
            report(.deferred)
            log("not counted against this recording — the problem is this Mac's, "
                + "and the recording is offered again once there is more to transcribe")
            if notify {
                notifyUser(
                    title: localised(
                        "amanu — transcription is waiting", "amanu — расшифровка ждёт"),
                    body: dir.lastPathComponent + localised(
                        " — see transcribe.log", " — подробности в transcribe.log"),
                    opening: dir)
            }
            return .environmental
        }

        let permanent = (error as? TranscriptionFailure)?.isPermanent ?? false
        let attempts =
            (SessionState.value(dir, SessionState.Key.transcriptionAttempts) as? Int ?? 0) + 1
        let gaveUp = permanent || attempts >= maxAttempts
        report(gaveUp ? .gaveUp : .deferred)
        var fields: [String: Any?] = [SessionState.Key.transcriptionAttempts: attempts,
            SessionState.Key.transcriptionDeferred: gaveUp ? nil : true]

        if gaveUp {
            fields[SessionState.Key.transcriptionFailed] = "\(error)"
            SessionState.update(dir, with: fields)
            log(permanent
                ? "giving up: \(error) — retrying cannot change this"
                : "giving up after \(attempts) attempts")
            notifyUser(
                title: localised(
                    "amanu — transcription gave up", "amanu — расшифровка не вышла"),
                body: dir.lastPathComponent + localised(
                    " — audio kept, see transcribe.log",
                    " — звук сохранён, подробности в transcribe.log"),
                opening: dir
            )
            // Under the session's claim, as every other compression is. The
            // transcription that failed has let go of it by the time its
            // failure is recorded, and in the minutes of encoding the
            // recordings window or `amanu process` may reach for the same
            // tracks to try again. Whoever has them then keeps them as they
            // are; retired sessions are only compressed to save disk.
            do {
                try SessionClaim.acquire(dir, stage: .transcribe)
                TrackCompressor.compress(sessionDir: dir)
                TranscriptionScratch.remove(in: dir)
                SessionClaim.release(dir)
            } catch {
                log("audio left uncompressed — \(error)")
            }
            return .retired
        } else {
            SessionState.update(dir, with: fields)
            notifyUser(
                title: localised(
                    "amanu — transcription failed", "amanu — расшифровка не удалась"),
                body: dir.lastPathComponent + localised(
                    " — see transcribe.log", " — подробности в transcribe.log"),
                opening: dir
            )
            return .counted(attempts: attempts)
        }
    }
}

/// An engine that could not be made ready: the model would not download, or
/// would not load. Nothing about any one recording is wrong, so this is
/// counted against none of them — see `TranscriptionFailurePolicy`.
struct EnginePreparationFailed: TranscriptionFailure, CustomStringConvertible {
    let engine: String
    let underlying: Error

    var isPermanent: Bool { false }
    var isEnvironmental: Bool { true }

    var description: String { "\(engine) could not be prepared: \(underlying)" }
}

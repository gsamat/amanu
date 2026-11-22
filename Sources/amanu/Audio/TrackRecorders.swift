import Foundation

/// What a `RecordingSession` needs from the recorder behind its mic track.
///
/// A protocol rather than the class itself so that the session's own
/// decisions — what happens when one track fails to start, what `stop` writes
/// and in which order, when the watchdog calls a track stalled — can be run
/// against a recorder that needs no microphone and no permission. Those are
/// the paths where a mistake loses a meeting without a sound, and none of them
/// could be exercised while the session built its recorders itself.
protocol MicTrackRecorder: AnyObject {
    func start(writingTo url: URL, callApps: [String]) throws
    func stop()
    func follow(callApps families: [String])
    func checkRoute()
    var firstBufferAt: Date? { get }
    var lastSoundAt: Date? { get }
    var signalLevel: Float? { get }
    var levelMeasurable: Bool { get }
    var isMuted: Bool { get set }
    var capture: MicRecorder.Capture { get }
    var restarts: [MicRecorder.Restart] { get }
    func installLiveAudioSink(_ sink: LiveAudioBufferRelay.Sink?)
    func setLiveAudioPaused(_ paused: Bool)
}

/// What a `RecordingSession` needs from the recorder behind its system track.
/// See `MicTrackRecorder` for why this is a protocol.
protocol SystemTrackRecorder: AnyObject {
    func start(writingTo url: URL, scope: SystemAudioRecorder.Scope) throws
    func stop()
    func refresh(scope newScope: SystemAudioRecorder.Scope)
    var scope: SystemAudioRecorder.Scope { get }
    var firstBufferAt: Date? { get }
    var lastSoundAt: Date? { get }
    var signalLevel: Float? { get }
    var levelMeasurable: Bool { get }
    var isMuted: Bool { get set }
    func installLiveAudioSink(_ sink: LiveAudioBufferRelay.Sink?)
    func setLiveAudioPaused(_ paused: Bool)
}

extension MicTrackRecorder { var signalLevel: Float? { nil } }
extension SystemTrackRecorder { var signalLevel: Float? { nil } }
extension MicRecorder: MicTrackRecorder {}
extension SystemAudioRecorder: SystemTrackRecorder {}

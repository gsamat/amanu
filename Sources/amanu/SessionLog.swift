import Foundation

/// Append one line to a session's `transcribe.log`.
///
/// A free function rather than a method so both the transcription actor and
/// the summarizer can write progress as it happens: handing the summarizer a
/// closure that captured the actor would mean sending non-Sendable state across
/// an isolation boundary, and buffering the lines until the end would hide
/// exactly the part that takes minutes.
func appendSessionLog(_ message: String, to dir: URL) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let url = dir.appendingPathComponent("transcribe.log")
    if let handle = FileHandle(forWritingAtPath: url.path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

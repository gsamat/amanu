import Foundation

/// The double-clickable script that sits in every session folder.
///
/// It exists because a session folder outlives the program's idea of where
/// sessions live: it gets moved into a project folder, copied to a second Mac,
/// dropped on the desktop. Once it has left the recordings root, nothing
/// sweeping that root will ever come back for it — but the folder itself still
/// knows what it is, and the script is how a person tells amanu to look here.
///
/// It is deliberately the thinnest possible shim. Every decision — what is
/// missing, which model to ask, what to write — lives in the binary, so a
/// script written months ago against an older version still does the current
/// thing. The only two facts it carries are its own location and where the
/// binary might be.
enum SessionScript {
    static let file = "Finish processing.command"

    /// Write the script into a session folder, unless it's already current.
    ///
    /// Rewriting only on a content change keeps the folder's modification date
    /// meaningful and avoids touching files inside a folder the user may be
    /// looking at in the Finder.
    static func install(in dir: URL) {
        let url = dir.appendingPathComponent(file)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != body else { return }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        } catch {
            FileHandle.standardError.write(Data(
                "couldn't write \(file) in \(dir.lastPathComponent): \(error)\n".utf8
            ))
        }
    }

    /// `$(dirname "$0")` rather than a path baked in at write time: that is
    /// what makes the folder movable. `PATH` is searched last because a
    /// double-clicked `.command` gets Finder's minimal environment, in which
    /// `~/.local/bin` is usually absent.
    static let body = """
    #!/bin/sh
    # Finishes whatever amanu hasn't done for this recording yet: the speaker
    # names, the summary, or the transcript itself. Running it twice is safe —
    # it only does what's still missing.
    #
    # All the logic lives in the amanu binary, so this file can't go stale, and
    # it passes its own folder rather than a remembered path, so moving this
    # folder anywhere on the Mac keeps it working.

    cd "$(dirname "$0")" || exit 1

    amanu=""
    for candidate in "$HOME/.local/bin/amanu" /opt/homebrew/bin/amanu /usr/local/bin/amanu; do
        [ -x "$candidate" ] && amanu="$candidate" && break
    done
    [ -z "$amanu" ] && command -v amanu >/dev/null 2>&1 && amanu="amanu"

    if [ -z "$amanu" ]; then
        echo "amanu isn't installed in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin."
        echo "Install it and run this again."
        printf '\\nPress return to close. '
        read -r _
        exit 1
    fi

    "$amanu" process "$PWD"
    status=$?
    printf '\\nPress return to close. '
    read -r _
    exit $status

    """
}

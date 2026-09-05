# Privacy

Amanu has no account and no hosted meeting library. Recordings and the files
made from them live in the recordings folder on your Mac. What leaves the Mac
depends on the transcription, speaker-naming, and summary backends you choose.

## Meeting content

- Recording is local. Microphone audio, system audio, and optional live
  transcription are captured and stored on the Mac.
- Parakeet transcription and Ollama summaries run locally.
- If you enable AssemblyAI or OpenAI transcription, Amanu uploads the meeting
  audio to that provider.
- If you select Claude Code, Codex, Anthropic, or OpenAI for summaries or
  speaker naming, Amanu gives that backend the transcript and the available
  meeting context: title, call application, and calendar participants. Those
  CLI tools or APIs may send the material to their provider under the terms of
  the account you use.
- API keys stay on the Mac and are sent only to the provider they authenticate.

Calendar access is optional. Amanu reads events to identify a meeting, name its
recording, and optionally start it at the scheduled time. Calendar context
stays local unless it is included in a request to a cloud or CLI model as
described above.

## Product analytics

Product-usage reporting is enabled by default and can be disabled in
first-run setup, in Settings → Setup, or with `amanu analytics off`. It sends a
small closed set of events with a random installation identifier to
`stats.amanu.me`. It never includes recordings, transcripts, summaries,
calendar contents, names, paths, keys, or error text. The complete event and
field list, retention period, and deletion instructions are in
[What Amanu sends](docs/analytics.md).

## Updates and model downloads

Sparkle checks `amanu.me/appcast.xml` for updates and downloads a selected
release from GitHub. Local model setup downloads model files from their
hosting services, including Hugging Face. These requests expose ordinary
network metadata such as the IP address and user agent to the destination;
they do not include meeting content. The product-analytics switch controls
usage reporting separately from updates and model downloads.

## Website analytics

The website sends a first-party request to `amanu.me/m` when a page is viewed,
and another aggregate event if a release download link is clicked. A page view
contains the page path and title, screen dimensions, and the referring page
when the browser supplies one. The download event contains only the fixed name
`download_clicked` and current page path. As with any web request, the server
also receives ordinary request metadata such as the IP address and user agent.
The site sets no analytics identifier, does not connect this activity to the
app installation identifier, and loads no third-party analytics script.

Questions or deletion requests can be sent to [s@samat.me](mailto:s@samat.me).

# Using a speech-to-text server

Amanu can send a completed recording to a server running Nemotron 3.5
Transcribe. Start and manage the server yourself; Amanu does not download the
model or start the server. Enter its API base URL, model name and token in the
transcription settings. A local server can omit the token.

For Apple Silicon, one option is the official NVFP4 model through
`mlx-audio` 0.6.4. In a separate Python 3.12 environment:

```sh
python3.12 -m venv .venv
. .venv/bin/activate
python -m pip install 'mlx-audio[stt,server]==0.6.4'
umask 077
python -m uvicorn mlx_audio.server:app --host 127.0.0.1 --port 8000
```

Set the API URL to `http://127.0.0.1:8000/v1` and the model to
`nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-NVFP4`, or to a local
checkpoint path on the server. The model is large; allow time and disk space
for its first download. The server's current HTTP interface does not expose
MTP acceleration. Keep the server running while Amanu transcribes.
The `umask` protects temporary WAV files created by this version of the
server while it processes a recording.

New server settings use the MLX Audio API format. Amanu sends audio to the
configured server; when it is remote, the recording leaves your computer.
The server check sends a short synthetic test phrase, not a meeting recording.

Long recordings are split into parts of at most 40 minutes. A speaker label
in one part is independent of the same label in another part. On the
Participants tab, give those labels the same name when they refer to the
same person. Audio is kept for review until you create the summary or skip
the step, then follows the existing audio retention setting.

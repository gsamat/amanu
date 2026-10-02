# amanu 0.6.4

- The **My own key** card now offers three clear choices: **OpenAI**, **Anthropic**, and **OpenAI-compatible**.
- Choose **OpenAI-compatible** to enter a routing service’s API URL, model, and token. Switching to OpenAI uses OpenAI’s API and key while retaining the saved custom URL.
- OpenAI and compatible services now show a neutral **API key** hint instead of implying that every token starts with `sk-`.
- Existing custom endpoint configurations continue to select the compatible service automatically.

## Compatibility

- Universal binary for Apple Silicon and Intel Macs running macOS 14.2 or later. Local transcription requires Apple Silicon; Intel requires a cloud transcription key and has not been tested on physical hardware.

# Setup control hit areas

## Goal

Make the first-run Setup window behave like its visual layout suggests. Choice
cards should be selectable across their whole rectangle, checkbox labels should
be clickable, summary enablement should match the auto-record control, and the
local Ollama option should offer the same installation path as other missing
tools.

## Choice cards

Every `ChoiceCard` remains a bordered radio choice, but its complete bounds
become an activation target: title, detail text, status text, and unused space.
Clicking anywhere in the card selects it and invokes the same `onSelect` path as
the radio control.

Interactive accessories keep their own behavior. Clicking an installation
link, segmented control, or text field may also select its containing card, but
must not prevent that accessory from opening, changing, or accepting input.
Disabled cards do not select from either the radio or the larger hit area.

This is implemented with card-level click handling around the existing view
hierarchy. A transparent overlay is not used because it would intercept the
card's links and inputs; nesting the content inside a replacement `NSButton` is
also avoided because several cards contain their own controls.

## Checkbox and summary switch

**Keep the audio after transcribing** uses the checkbox's native title instead
of a separate label. AppKit then treats both the checkbox mark and its text as
one control, so either toggles `keep_audio`.

The **Summaries** enable switch moves to the left of its heading, matching the
placement of **Start recording by itself when a call app takes the mic**. Its
configuration behavior does not change: turning summaries off disables every
backend choice; turning them on restores the configured selection.

## Ollama

Ollama becomes a regular `ChoiceCard` in the same mutually exclusive summary
backend group as Claude Code, Codex, and API key. The card keeps its detected
state and model names.

An **Install Ollama** link points to `https://ollama.com/download/mac`. It is
visible only when Ollama is not available and hidden once the local service can
be reached. Amanu never installs Ollama automatically: the official macOS app
and its models are separate, potentially large installations that require an
explicit user action.

## Tests

Automated AppKit tests cover:

- activating the body of a card selects it through the same callback as its
  radio control;
- a disabled card ignores body activation;
- interactive accessories remain present and usable inside a fully clickable
  card;
- the Keep Audio checkbox owns its visible title;
- Ollama maps through the shared summary choice group;
- the Ollama install link starts visible and can be hidden after detection.

The manual Setup checklist adds clicks on the title, detail, and whitespace of
each kind of card; the Keep Audio label; the left-hand Summaries switch; and the
Ollama installation link when Ollama is absent.

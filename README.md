# FishAudioDemo

A free macOS menu bar app demo built on [Fish Audio](https://fish.audio)'s TTS/voice-cloning/ASR API. Browse and preview sample voices, clone your own voice, talk to a voice agent, and transcribe live calls (Meet/Teams/Zoom) — all from the menu bar.

## Why this is free

- Fish Audio's `s2.1-pro-free` model is free under a Fair Use policy through **Aug 31 2026** (no hard usage cap, voice cloning included). You need your own free Fish Audio API key from [fish.audio](https://fish.audio) — paste it into the app's Settings tab, it's stored in Keychain and never leaves your machine except to call Fish Audio's API.
- The voice agent's conversational "brain" defaults to a **local [Ollama](https://ollama.com)** instance — genuinely free, no account, no API key. Settings can instead point it at OpenAI, Gemini, or any other OpenAI-compatible `/chat/completions` endpoint if you'd rather use a hosted model (optional, never required).

## Build & run

No Xcode project — Swift Package Manager only.

```sh
make run
```

This builds a release binary, assembles a real `.app` bundle (`dist/FishAudioDemo.app`), ad-hoc code-signs it, and launches it. A real bundle (not a bare `swift run` binary) is required for macOS to correctly attribute mic/screen-recording permission grants to this app instead of Terminal.

For fast UI iteration where you're not touching mic/screen-recording, `swift build && swift run` also works.

## First run: permissions

- **Microphone** — prompted the first time you record a voice clone or start the agent. Needed for cloning and for talking to the agent.
- **Screen Recording** — prompted the first time you start "Transcribe a Call…". This is the TCC bucket that also gates system-*audio* capture, even though no video is involved. If it doesn't prompt, grant it manually in System Settings → Privacy & Security → Screen Recording, then relaunch.

## Setting up the free local LLM (optional, for the voice agent)

```sh
brew install ollama
ollama pull llama3.2
```

That's it — the app's Settings tab already defaults to `http://localhost:11434/v1` / `llama3.2` / no key. If Ollama isn't running, the agent still works end-to-end (mic → transcription → speech), it just replies with a message telling you no LLM was reachable, instead of crashing.

To use a different provider instead, change Settings → Agent Brain: any base URL + model that speaks the OpenAI `/chat/completions` schema works (OpenAI, Gemini's OpenAI-compatible endpoint, etc.). Anthropic's native API is **not** OpenAI-schema-compatible, so Claude only works here behind a compatibility proxy.

## Limitations (stated plainly, not hidden)

- **Distribution**: ad-hoc signed, not notarized, no Apple Developer account. `make run` on the machine you built on has zero Gatekeeper friction. If the built `.app` is ever transferred by download, macOS will quarantine it — right-click → Open once, or `xattr -d com.apple.quarantine FishAudioDemo.app`.
- **Call transcription** captures the whole system audio *output* mix (whatever you hear — notifications, music, the call), not scoped to one app, and only that side of the conversation — not your own mic. Two-sided transcription is a natural follow-up, not built here.
- **No barge-in**: the voice agent's mic is off while it's speaking a reply — you can't interrupt it mid-sentence in v1.
- **Voice library** is a live query against Fish Audio's public voices (`GET /model?self=false`), not a full browser of the 2M+ community library — just enough to sample a handful.

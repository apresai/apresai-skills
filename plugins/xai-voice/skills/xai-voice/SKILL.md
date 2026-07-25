---
name: xai-voice
description: Build against xAI's voice APIs (Grok Text-to-Speech, Speech-to-Text, and the realtime Speech-to-Speech voice agent). Triggers when the user wants to synthesize speech with Grok or xAI, mentions api.x.ai/v1/tts, /v1/stt, wss://api.x.ai/v1/realtime, grok-tts, grok-voice, grok-voice-tts, or Grok voice agents; wants to add xAI as a TTS provider to an app or pipeline; asks which xAI voices exist, how xAI speech tags work, what xAI TTS costs, or why xAI TTS rejects a request; asks about xAI voice cloning or a custom_voice_id; wants Grok chat to return strict schema-enforced JSON (response_format json_schema, /v1/responses text.format) for script or structured-output generation; wants to build a voice agent, phone/SIP agent, or LiveKit integration on Grok; or is choosing between TTS, STT, and speech-to-speech for a voice task. Carries live-verified request/response contracts, the 26-voice catalog, a production Go client, and the places xAI's own docs are wrong.
---

# xAI Voice: Grok TTS, STT, and Speech-to-Speech

This skill is the reference for building on xAI's three voice surfaces. It exists because
**`docs.x.ai` is materially behind the running API**: the published voice roster is 5 when
26 are live, the codec enum is missing two values, and the REST reference still restricts
`reasoning_effort` to a model that is no longer the only one accepting it. Everything here
marked **[live]** was verified by direct probe against `api.x.ai` on **2026-07-25**.

## Pick the right API first

This is the decision that matters most, and getting it wrong costs a rewrite.

| You have | You want | Use | Load |
|---|---|---|---|
| Fixed, final text | An audio file of exactly that text | **TTS** `POST /v1/tts` | `tts.md` |
| Audio | A transcript | **STT** `POST`/`WSS /v1/stt` | `realtime.md` |
| A live human on a mic or phone | A back-and-forth conversation | **S2S** `wss://api.x.ai/v1/realtime` | `realtime.md` |

**Rendering a written script to audio is TTS.** Speech-to-Speech is a conversational loop
with no verbatim-render mode (the model composes its own replies under VAD-driven turn
taking), and it bills per connected minute instead of per character. TTS is also the only one
of the three with text fidelity: it speaks exactly the text you supply, which is what makes
it usable for synthesizing a multi-speaker script segment-by-segment. Note that TTS output is
**not** deterministic: three identical requests (same text, same `voice_id`) returned three
different durations and three different sha256 hashes (1.440 s / 1.224 s / 1.176 s). **[live]**

## Reading order

Load only what the task needs.

| File | When to load |
|---|---|
| `tts.md` | The `POST /v1/tts` contract: every field, the 26-voice catalog, output formats, speech tags, limits, pricing |
| `go-client.md` | Writing the client: reference Go implementation, error classification, retry/concurrency/timeout tuning, and Grok chat with strict JSON |
| `realtime.md` | STT (`/v1/stt`) and Speech-to-Speech (`wss://.../v1/realtime`), covering event protocol, session config, SIP/telephony, ephemeral tokens, LiveKit |
| `gotchas.md` | Read before shipping. Doc-vs-live discrepancies, the traps that produce wrong audio instead of errors, and the schema-discovery technique |

## The 60-second version

```bash
curl -s -X POST https://api.x.ai/v1/tts \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Welcome back to the show.",
    "language": "en",
    "voice_id": "eve",
    "output_format": {"codec": "mp3", "sample_rate": 44100, "bit_rate": 192000}
  }' -o out.mp3
```

The response body **is** the audio: raw MP3 bytes, `Content-Type: audio/mpeg`. Not JSON, not
base64. **[live]**

Five things that surprise everyone: **[live]**

1. **There is no `model` field.** Sending one returns 200 and is silently ignored. `voice_id`
   *is* the model selection.
2. **`language` is required but never validated.** `"xx"` and `""` both return 200.
3. **Output is always mono**, at every sample rate. There is no stereo option.
4. **Omitting `output_format` silently downgrades** to 24 kHz / 128 kbps.
5. **Bracket tags are never silently ignored.** At N=6 per condition on voice `luna`, every
   bracketed form measurably lengthened the audio versus baseline (baseline mean 1.272 s,
   `[laugh]` 2.428 s, `[laughs]` 2.232 s, and the nonsense `[flibbertigibbet]` 2.088 s). So
   passing unrecognized bracketed text straight through is not safe. What the model actually
   vocalizes for an unrecognized tag is **unverified**: duration alone cannot separate "a
   laugh was rendered" from "the word was spoken," and nobody listened. Normalize or strip
   bracket tokens defensively. See `gotchas.md`.

## Auth and setup

```bash
export XAI_API_KEY="<your key>"
```

One key covers all three voice surfaces and Grok chat. Server-side REST calls use it
directly. **Ephemeral tokens are only for browser/mobile clients connecting to the realtime
WebSocket**; do not mint them for `/v1/tts` or `/v1/stt`.

## There is no Go SDK, and TTS is not OpenAI-compatible

`xai-org` publishes only `xai-sdk-python` and `xai-proto`. No official Go, TypeScript, or
Java SDK exists, and the Python SDK does not cover TTS. Community Go clients are chat-only.

xAI's **chat** surface is genuinely OpenAI-wire-compatible, so `openai-go` pointed at
`https://api.x.ai/v1` works for `/v1/chat/completions` and `/v1/responses`. Its **audio**
surface is not, and `docs.x.ai` says so verbatim: *"The xAI TTS API does not work with the
OpenAI SDK."* Different path, `text` not `input`, `voice_id` not `voice`, a required
`language`, `output_format` as an object, `speed` 0.7–1.5 instead of 0.25–4.0, no `model`.

Write the HTTP call. It is ~60 lines; see `go-client.md`.

## Working in this skill

1. **Confirm the API choice** against the decision table above before writing anything.
2. **Never hardcode the voice list from the docs.** Call `GET /v1/tts/voices`; the roster went
   5 → 26 without a docs update. `tts.md` has the current catalog as a cache, not a spec.
3. **Probe rather than guess.** The TTS deserializer names the offending field on every
   rejection and returns the full valid set for a bad enum value, so the live schema is
   discoverable for free. `gotchas.md` documents the technique.
4. **Sanitize LLM-authored text** before it reaches `/v1/tts`. Bracket tokens an LLM writes
   by habit are not ignored; they change the audio, in a way nobody has verified.
5. **Cross-check `gotchas.md` before shipping.**

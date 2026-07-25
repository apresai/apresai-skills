# xai-voice

Master reference for **xAI's three voice APIs**: Grok Text-to-Speech, Speech-to-Text, and the
realtime Speech-to-Speech voice agent.

Auto-triggering skill: no slash command needed. It loads when you mention xAI/Grok voice,
`api.x.ai/v1/tts`, `/v1/stt`, `wss://api.x.ai/v1/realtime`, grok-tts, or ask to add xAI as a
TTS provider.

## Why this exists

`docs.x.ai` is materially behind the running API. Verified by direct probe on **2026-07-25**:

| Docs say | Live reality |
|---|---|
| 5 voices (`eve`, `ara`, `leo`, `rex`, `sal`) | **26 voices** |
| codecs `mp3`/`wav`/`pcm`/`mulaw`/`alaw` | also **`opus`** and **`ulaw`** |
| `optimize_streaming_latency` is a request field | **not in the schema** (silently ignored) |
| `reasoning_effort` is "only supported by grok-4.3" | **`grok-4.5` accepts it** |
| TTS GA in March 2025 (release notes) | internally inconsistent; corroborated launch is **2026-04-17** |

Plus two behaviors documented nowhere that produce *wrong audio rather than errors*:

- **There is no `model` field on `/v1/tts`.** Sending one returns 200 and is ignored.
- **Unrecognized bracket speech tags are read aloud.** `[laugh]` renders a laugh (+1.87 s on a
  measured A/B); `[laughs]` (the plural an LLM naturally writes) renders the *word* "laughs."

## Contents

| File | What's in it |
|---|---|
| `skills/xai-voice/SKILL.md` | Router + the TTS-vs-STT-vs-S2S decision table + 60-second quickstart |
| `skills/xai-voice/tts.md` | Full `POST /v1/tts` contract, 26-voice catalog, output formats, speech tags, limits, pricing, voice cloning |
| `skills/xai-voice/go-client.md` | Production Go client, error classification, retry/concurrency/timeout tuning, Grok chat with strict JSON |
| `skills/xai-voice/realtime.md` | STT and Speech-to-Speech: event protocol, session config, SIP/telephony, ephemeral tokens, LiveKit |
| `skills/xai-voice/gotchas.md` | Doc-vs-live discrepancies, the traps, and the zero-cost schema-discovery technique |

## The technique worth stealing

xAI's TTS deserializer is `serde`-based and names the offending field on every rejection. Send
a wrong *type* to learn whether a field exists and what type it wants; send a wrong *enum
value* to get the complete valid set back. Include `"voice_id": "__nope__"` and any request
that deserializes fails `404` **before synthesis runs**, so the whole schema is discoverable
for free:

```bash
curl -s -X POST https://api.x.ai/v1/tts \
  -H "Authorization: Bearer $XAI_API_KEY" -H "Content-Type: application/json" \
  -d '{"text":"hi","language":"en","voice_id":"__nope__","output_format":{"codec":"__nope__"}}'
# -> unknown variant `__nope__`, expected one of `mp3`, `wav`, `pcm`, `opus`, `mulaw`, `ulaw`, `alaw`
```

This generalizes to any `serde`-backed Rust API.

## Provenance

Facts are labeled **[live]** (probed against `api.x.ai` on 2026-07-25) or **[docs]** (from
`docs.x.ai`, not independently confirmed). Where they conflict, live wins and the conflict is
recorded. Unresolved questions (notably the $15 vs $4.20 per-1M-character pricing conflict
between primary sources and launch-week aggregators) are flagged as unresolved rather than
papered over.

## Proven in production

Backs the `xai` TTS provider and `grok` script model in
[podcaster](https://github.com/apresai/podcaster), which renders two-host podcast scripts to
audio segment-by-segment through `POST /v1/tts`.

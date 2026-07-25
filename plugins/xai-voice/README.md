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
| `optimize_streaming_latency` is a request field | **it is** a request field, an `i32` on `POST /v1/tts` (an earlier probe with the integer `999` wrongly concluded otherwise: a valid integer deserializes fine) |
| `reasoning_effort` is "only supported by grok-4.3" | **`grok-4.5` accepts it** |
| TTS GA in March 2025 (release notes) | internally inconsistent; corroborated launch is **2026-04-17** |

Plus two behaviors documented nowhere that *change the audio instead of raising an error*:

- **There is no `model` field on `/v1/tts`.** Sending one returns 200 and is ignored.
  (Re-confirmed with an object-valued probe, which detects fields of every scalar type.)
- **Bracket speech tags are never silently ignored.** At N=6 per condition, every bracketed
  form lengthened the audio versus a 1.272 s baseline, including a nonsense token:
  `[laugh]` 2.428 s, `[laughs]` 2.232 s, `[flibbertigibbet]` 2.088 s. So unrecognized
  bracketed text must be normalized or stripped before sending. What the model actually
  vocalizes for one is **unverified**: duration cannot distinguish a rendered laugh from the
  spoken word, and nobody listened to the audio.

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

This generalizes to any `serde`-backed Rust API, with one caveat that already burned us: the
oracle only fires when the probe value mismatches the field's **actual** type. Probing an
integer field with an integer deserializes fine and falls through to the voice-404, which
reads exactly like "field ignored." Probe with an **object** (`{"field":{"__obj__":1}}`),
which mismatches every scalar type.

## Provenance

Facts are labeled **[live]** (probed against `api.x.ai` on 2026-07-25) or **[docs]** (from
`docs.x.ai`, not independently confirmed). Where they conflict, live wins and the conflict is
recorded. Unresolved questions (notably the $15 vs $4.20 per-1M-character pricing conflict
between primary sources and launch-week aggregators) are flagged as unresolved rather than
papered over.

## Validated against a real integration

Developed alongside the `xai` TTS provider and `grok` script model in
[podcaster](https://github.com/apresai/podcaster), which renders two-host podcast scripts to
audio segment-by-segment through `POST /v1/tts`. That integration is the source of the
error-handling, retry, and timeout guidance here.

**Not yet deployed.** As of 2026-07-25 the podcaster PR is open, unmerged, and not released
to production, so nothing in this skill has production-traffic evidence behind it.

# xAI Speech-to-Text and Speech-to-Speech

Sourced from `docs.x.ai` (**[docs]**) unless marked **[live]**. The TTS contract in
`tts.md` is live-verified end to end; these two surfaces are documented but were not
probed, so treat field names as needing a smoke test before they become load-bearing.

## Speech-to-Text (`/v1/stt`)

Audio in, text out. Batch and streaming.

### Batch (`POST https://api.x.ai/v1/stt`)

| Field | Notes |
|---|---|
| `file` or `url` | One required. File max 500 MB. |
| `audio_format` | Required **only** for raw `pcm`/`mulaw`/`alaw`. |
| `sample_rate` | Required for raw formats. |
| `language` | e.g. `en`, `fr`, `ja`. 25 languages supported. |
| `format` | Enables text normalization. |
| `multichannel` | bool: per-channel transcripts. |
| `channels` | 2–8, for multichannel raw audio. |
| `diarize` | bool (speaker labels). |
| `keyterm` | array, max 100 domain terms; boosts recognition of names/jargon. |
| `filler_words` | bool, keep "um", "uh". |
| `vad_threshold` | 0.0–1.0, default **0.5**. |

There is **no `model` field** on either STT endpoint; model selection does not appear to
exist for STT.

Response: `text`, `language`, `duration`, `words[]` (`text`, `start`, `end`, `confidence`,
`speaker`), and `channels[]` when `multichannel=true`.

### Streaming (`wss://api.x.ai/v1/stt`)

Query params: `sample_rate` (default 16000), `encoding` (`pcm`|`mulaw`|`alaw`, default
`pcm`), `interim_results` (default false), `endpointing` (ms, default 10), `language`,
`multichannel`, `channels`, `diarize`, `keyterm` (repeatable), `filler_words`,
`smart_turn` (0.0–1.0; xAI's dedicated end-of-turn model, distinct from VAD),
`smart_turn_timeout` (ms), `vad_threshold` (**default 0.08 here, not 0.5**: the two
endpoints disagree; set it explicitly).

Client → server: raw binary audio frames, plus `finalize` and `audio.done` control messages.
Server → client: `transcript.created`, `transcript.partial`, `transcript.done`, `error`.

## Speech-to-Speech (Voice Agent, `wss://api.x.ai/v1/realtime`)

A live conversational loop. The model listens, thinks, and speaks. It is **not** a
text renderer.

```
wss://api.x.ai/v1/realtime?model=grok-voice-latest
Authorization: Bearer $XAI_API_KEY
```

Query params: `model` (default `grok-voice-latest`), `reasoning.effort` (default `high`),
`call_id` (SIP).

Models: `grok-voice-think-fast-1.0` (current flagship), `grok-voice-fast-1.0`
(deprecated), `grok-voice-latest` (rolling alias).

### Protocol: OpenAI Realtime compatible, with gaps

Supported client events: `session.update`, `conversation.item.create`,
`input_audio_buffer.append`, `input_audio_buffer.commit`, `input_audio_buffer.clear`,
`response.create`, `response.cancel`.

Supported server events: `session.created`, `conversation.created`, `session.updated`,
`conversation.item.created`, `input_audio_buffer.speech_started`,
`input_audio_buffer.committed`, `response.created`, **`response.output_audio.delta`**,
`response.function_call_arguments.done`, `response.done`, `error`.

> The audio delta event is `response.output_audio.delta`. OpenAI's older
> `response.audio.delta` is **not** what xAI emits. A client ported from an older OpenAI
> Realtime example will silently receive no audio.

Documented as **unsupported** despite existing in OpenAI's spec:
`conversation.item.retrieve`, `conversation.item.done`,
`conversation.item.input_audio_transcription.failed`,
`conversation.item.input_audio_transcription.segment`, `rate_limits.updated`, and the whole
`output_audio_buffer.*` family (WebRTC/SIP transport only).

### `session.update` → `session`

`voice` (built-in id or `custom_voice_id`), `instructions`, `reasoning.effort`
(`high`|`none`), `turn_detection` (`{type: "server_vad"|null, threshold 0.1–0.9,
silence_duration_ms 0–10000, prefix_padding_ms default 333, idle_timeout_ms}`),
`audio.input.format` / `audio.output.format` (`{type: "audio/pcm"|"pcmu"|"pcma"|"opus",
rate: 8000|16000|22050|24000 (default)|32000|44100|48000}`, PCM only; Opus fixed 24 kHz),
`audio.*.transport` (`json` = base64 in event payloads, or `binary` = raw codec bytes as WS
binary frames), `audio.input.transcription.language_hint` (BCP-47: bare `es` is rejected
for regional-variant languages, use `es-MX`), `audio.input.transcription.keyterms` (max 100
terms × 50 chars), `audio.output.speed` (0.7–1.5), `replace` (`{phrase: substitution}`,
case-insensitive whole-word longest-prefix), `tools`, `resumption.enabled` (replays history
across reconnects via `?conversation_id=`, expires after 30 min idle).

### xAI-only extensions

- **`force_message`**: a `conversation.item.create` with `item.type: "force_message"` speaks
  a scripted line verbatim, bypassing the model. Supports `interruptible: false`. Useful for
  disclosures and fixed prompts inside a live session; **not** a batch script renderer.
- **`replace`**: phrase substitution applied before TTS (pronunciation fixes, brand names).
- **`resumption`**: session replay across reconnects.
- Per-turn `response.create` → `response.instructions` override (e.g. switch language for
  one turn only).

### Tools

`file_search`, `web_search`, `x_search`, `mcp` (remote MCP servers), and `function`
(client-executed JSON-schema functions).

Flow: server emits `response.function_call_arguments.done` (`name`, `call_id`,
`arguments`) → client executes → client sends `conversation.item.create` with
`item.type: "function_call_output"` → client sends **one** `response.create` to resume.
The model may emit **several** `function_call_arguments.done` events (parallel calls)
before speaking; resolve all of them before issuing that single `response.create`.

### Ephemeral tokens (browser/mobile clients)

```
POST https://api.x.ai/v1/realtime/client_secrets
Authorization: Bearer $XAI_API_KEY
{"expires_after": {"seconds": 300}}   // max 3600
```

Mint server-side with the real key; hand the returned short-lived secret to the client.
Narrower than OpenAI's equivalent: **no `expires_after.anchor`** field. The client passes
it as a Bearer header, or (for browsers that cannot set WS headers) via
`sec-websocket-protocol: xai-client-secret.{TOKEN}`.

Needed **only** for client-side realtime connections. Server-side REST calls to `/v1/tts`
and `/v1/stt` use the API key directly; do not mint ephemeral tokens for those.

### SIP / telephony

`POST /v2/phone-numbers` provisions a number (`origin`: `xai_provisioned` | `byo_trunk`,
plus `name`, mutually-exclusive `agent_id`|`webhook`, `area_code`, `phone_number` (E.164,
BYO only), `sip_auth`, `webhook`). The response returns a one-time-shown
`webhook_signing_secret`; capture it on creation, it is not retrievable later.

Inbound calls POST a signed `realtime.call.incoming` webhook; verify the signature, read
`data.call_id`, then connect `wss://api.x.ai/v1/realtime?call_id={call_id}`.

Call control: `POST /v1/realtime/calls/{call_id}/refer` (`target_uri`: `tel:+E.164` or
`sip:user@host`) transfers; `POST /v1/realtime/calls/{call_id}/hangup` ends.

DTMF keypresses buffer as text input, flushed on `#`, 2.5 s idle, or when the user speaks;
each emits `input_audio_buffer.dtmf_event_received`.

Carrier routing: point trunks at `sip:{number}@sip.voice.x.ai;transport=tls`. Documented:
Twilio Elastic SIP Trunking, Telnyx SIP Connection (port 5060), Plivo, plus `byo_trunk`.

## Which API: decision rule

| You have | You want | Use |
|---|---|---|
| Fixed, final text | An audio file of exactly that text | **TTS** `POST /v1/tts` |
| Audio | A transcript | **STT** `POST`/`WSS /v1/stt` |
| A live human on a mic or phone | A conversation | **S2S** `wss://api.x.ai/v1/realtime` |

**Rendering a pre-written multi-host script to a file is TTS. Both alternatives are wrong:**

- **STT** goes the wrong direction (audio → text).
- **S2S** is a conversational loop with no verbatim-render mode. The model generates its own
  replies turn by turn under VAD-driven turn-taking, so text fidelity to a written script is
  not guaranteed, and billing is per connected minute rather than per character. The
  `force_message` extension can inject one scripted utterance into a live session, but it is
  an interjection mechanism, not a batch renderer.

TTS is also the only one of the three that is deterministic: same text + same `voice_id`
→ same delivery, which is what makes it safe to synthesize a script segment-by-segment and
concatenate without the voice drifting between segments.

## Pricing **[docs]**

| Surface | Price | Unit |
|---|---|---|
| TTS | $15.00 | per 1M **input characters** |
| STT batch | $0.10 | per hour of audio |
| STT streaming | $0.20 | per hour of audio |
| Realtime S2S audio | $0.05/min ($3.00/hr) | per minute, both directions |
| Realtime text input events | $0.004 | per `conversation.item.create` |

## LiveKit

Official plugin: `livekit-agents[xai]` (Python, `from livekit.plugins import xai`) and
`@livekit/agents-plugin-xai` (Node). It wraps the **realtime** voice-agent API as
`xai.realtime.RealtimeModel(voice="Ara")`, providing WebRTC transport, turn detection, streaming.
A separate xAI **LLM** plugin exposes Grok as a plain text LLM inside a
STT→LLM→TTS pipeline.

There is **no LiveKit plugin wrapping the unary `/v1/tts` endpoint**. The official
integration is realtime-only. For batch TTS, call the REST endpoint directly.

## Third-party hosting **[docs / vendor pages]**

- **AWS Bedrock: no Grok voice model.** Bedrock carries Grok 4.3 (GA 2026-06-17) as
  text-only; AWS's own model card states "audio, speech, and video are not supported."
  Confident negative as of 2026-07-24; do not plan a Bedrock-hosted xAI TTS path.
- **Oracle OCI Generative AI**: `xai.grok-tts`, reachable via OCI's OpenAI-compatible Audio
  Speech API plus a dedicated OCI WebSocket streaming endpoint. The most substantive
  third-party integration.
- **OpenRouter**: `x-ai/grok-voice-tts-1.0` at $15/1M chars; a pass-through router, xAI runs
  the compute.
- **Cloudflare Workers AI**: `grok-tts` in the catalog, invocable via `env.AI.run()`.
  Whether Cloudflare runs inference or proxies to x.ai is not stated.
- **Vercel AI Gateway**: Grok TTS listed since 2026-06-29, described as rolling out.

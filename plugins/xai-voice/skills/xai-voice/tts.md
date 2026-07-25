# xAI Text-to-Speech: `POST /v1/tts`

Batch/unary synthesis: fixed text in, audio bytes out. Deterministic; the model does not
paraphrase. This is the endpoint for rendering pre-written scripts, articles, podcast
segments, notifications, IVR prompts.

Every field and value below marked **[live]** was verified by direct probe against
`api.x.ai` on **2026-07-25**. Facts marked **[docs]** come from `docs.x.ai` and were not
independently confirmed. Where the two disagree, **live wins** and the disagreement is
called out in `gotchas.md`.

## Request

```
POST https://api.x.ai/v1/tts
Authorization: Bearer $XAI_API_KEY
Content-Type: application/json
```

| Field | Type | Required | Values | Notes |
|---|---|---|---|---|
| `text` | string | **yes** | ≤ 15,000 chars | Supports inline speech tags. **[live]** |
| `language` | string | **yes** | BCP-47 (`en`, `es-MX`, `pt-BR`, …) or `auto` | Required by the deserializer but **not validated** (any string, including `""`, returns 200). **[live]** |
| `voice_id` | string | no | see voice catalog | Canonical name. `voice` is an accepted **alias** for the same field. Case-insensitive. Default `eve`. **[live]** |
| `speed` | number | no | `0.7`–`1.5` (default `1.0`) | Out of range → `{"error":"speed must be between 0.7 and 1.5"}`. **[live]** |
| `output_format` | object | no | see below | A nested **object**, not a string. **[live]** |
| `text_normalization` | boolean | no | n/a | Expands numbers/dates/abbreviations into spoken form. **[live: field exists]** |
| `with_timestamps` | boolean | no | n/a | Changes the response to a JSON envelope. **[live]** |

There is **no `model` field.** Sending one is silently ignored, and the request still returns
200 and audio. Voice selection *is* model selection here. **[live]**

Fields that do **not** exist on this endpoint (silently ignored if sent): `model`, `pitch`,
`temperature`, `seed`, `instructions`, `style`, `stream`, `volume`, `emotion`,
`sample_rate` (top level), `response_format`, `format`, `optimize_streaming_latency`,
`custom_voice_id`. **[live]**

### `output_format`

All three sub-fields are optional.

| Sub-field | Values |
|---|---|
| `codec` | `mp3`, `wav`, `pcm`, `opus`, `mulaw`, `ulaw`, `alaw` **[live: exact enum from the API's own error]** |
| `sample_rate` | `8000`, `16000`, `22050`, `24000`, `44100`, `48000` **[live]** |
| `bit_rate` | mp3 only: `32000`, `64000`, `96000`, `128000`, `192000` **[live]** |

Omitting `output_format` entirely yields **mp3 / 24000 Hz / 128000 bps / mono**. **[live]**

**Output is always mono (1 channel), at every sample rate.** **[live]** There is no
channel/stereo option. Anything that concatenates xAI segments alongside stereo audio must
re-encode to stereo first.

## Response

Default: **raw audio bytes**, `Content-Type: audio/mpeg` for mp3. Not JSON, not base64. **[live]**

A `x-trace-id` response header is present on success. Capture it in logs; it is what xAI
support asks for. **[live]**

With `with_timestamps: true` the response becomes `Content-Type: application/json`: **[live]**

```json
{
  "audio": "<base64>",
  "content_type": "audio/mpeg",
  "duration": 0.84,
  "audio_timestamps": {
    "graph_chars": ["H", "e", "l", "l", "o"],
    "graph_times": [[0.12, 0.16], [0.16, 0.18], [0.2, 0.23]]
  }
}
```

`graph_times` is per-**character** start/end in seconds, index-aligned to `graph_chars`.
Use it for captions, karaoke highlighting, or aligning b-roll to narration.

### Errors

| Status | Body | Cause |
|---|---|---|
| 422 | `Failed to deserialize the JSON body into the target type: missing field \`text\`` (plain text, **not** JSON) | Missing/mistyped field. **[live]** |
| 400 | `{"error":"Field \`text\` exceeds maximum length of 15000 characters (16000 provided)."}` | Over the cap. **[live]** |
| 400 | `{"error":"speed must be between 0.7 and 1.5"}` | Bad speed. **[live]** |
| 404 | `{"error":"TTS synthesis failed: Voice 'x' not found"}` | Unknown `voice_id`. **[live]** |
| 429 | Undocumented shape. No `Retry-After` observed. | Rate limited. **[docs: 429 is used; body shape unverified]** |

Two distinct error encodings: deserialization failures are **plain text**, semantic
failures are **JSON with a flat `error` string**. Neither matches OpenAI's
`{"error":{"message","type","code"}}` envelope. A client that assumes JSON on every
non-2xx will fail to parse 422s.

## Voice catalog: `GET /v1/tts/voices`

```
GET https://api.x.ai/v1/tts/voices
Authorization: Bearer $XAI_API_KEY
```

```json
{"voices":[{"voice_id":"altair","name":"Altair","language":"multilingual","gender":"male"}]}
```

**26 voices live as of 2026-07-25** (every one `language: "multilingual"`). **[live]**

| Gender | Voices |
|---|---|
| female (7) | `ara`, `carina`, `celeste`, `eve`, `iris`, `luna`, `ursa` |
| male (19) | `altair`, `atlas`, `castor`, `cosmo`, `helios`, `helix`, `kepler`, `leo`, `lumen`, `lux`, `naksh`, `orion`, `perseus`, `rex`, `rigel`, `sal`, `sirius`, `zagan`, `zenith` |

`docs.x.ai` still documents only five (`eve`, `ara`, `leo`, `rex`, `sal`), the launch set.
**Always call `GET /v1/tts/voices` rather than hardcoding from the docs**; the roster grew
5 → 26 without a docs update. A static catalog in your code should be treated as a cache
with a refresh command, not as truth.

## Speech tags

Inline markup inside `text`. Two syntaxes: **bracket tags** fire a one-shot sound,
**angle wrappers** modulate the enclosed span.

Bracket (one-shot): `[pause]` `[long-pause]` `[laugh]` `[cry]` `[clap]` `[snap]` `[kiss]`
`[pop]` `[click]` `[breath]` `[gasp]` `[sigh]` `[yawn]` **[docs]**

Wrapping: `<loud>` `<soft>` `<whisper>` `<high>` `<low>` `<slow>` `<fast>` `<sing>`
`<giggly>` `<grumpy>` (e.g. `<whisper>this part matters</whisper>`) **[docs]**

Live-confirmed from this list: `[laugh]`, `[sigh]`, `[pause]`, `<whisper>` (all consumed and
rendered, not spoken). The rest are documented but unverified.

> **Treat the tag list as approximate.** Six separate fetches of the same docs page returned
> six different tag lists, so the exact complete set is not reliably established. Additional
> tags appearing in some extractions but not others: `[chuckle]` `[giggle]` `[cough]`
> `[sneeze]` `[inhale]` `[exhale]` `[sniff]` `[throat-clear]` `[lip-smack]` `[tongue-click]`;
> `<emphasis>` `<excited>` `<sad>` `<higher-pitch>` `<lower-pitch>` `<build-intensity>`.
> **Verify any tag you depend on with a duration A/B before shipping it**: the cost of being
> wrong is the tag name being spoken aloud (see below), and the A/B takes one curl.

### The tag gotcha that will bite you

**An unrecognized bracket tag is READ ALOUD, not dropped.** Measured on identical wording,
voice `luna`, no other changes: **[live]**

| `text` | duration |
|---|---|
| `That is wild.` | 1.44 s |
| `[laugh] That is wild.` | 3.31 s ← real laugh |
| `[laughs] That is wild.` | 2.14 s ← the **word "laughs" spoken** |
| `[sigh] That is wild.` | 2.06 s ← real sigh |
| `[flibbertigibbet] That is wild.` (nonsense) | +0.98 s ← spoken |

The documented tags are **singular** (`[laugh]`, `[sigh]`). The natural-English plural
forms an LLM will happily emit (`[laughs]`, `[sighs]`) are *not* tags and get vocalized.

Consequence for any pipeline whose text comes from an LLM: either constrain the prompt to
emit no bracketed text at all, or whitelist-filter `text` against the exact tag list above
before it reaches `/v1/tts`. Passing model output through unfiltered will eventually put
the word "laughs" in your audio.

## Limits and throughput

- **15,000 characters** per request, enforced. **[live]**
- Long text is fine: 5,000 chars returned **342 s** of audio in a single call. Synthesis
  time scales with output length; a ~10,000-char request exceeded a 2-minute client
  timeout. Size per-request timeouts off *output duration*, not input bytes. **[live]**
- **12 concurrent requests all returned 200 in ~2 s total.** No 429, no throttling
  observed at that level. **[live]**
- **No rate-limit headers** are returned (`x-ratelimit-*` absent), so a client cannot
  self-pace from response metadata. **[live]**
- `docs.x.ai/developers/rate-limits` states verbatim that the published spend-tier table
  "appl[ies] to text and embedding models" and directs voice-limit increases to
  `sales@x.ai`. **No public numeric TTS rate limit exists**, and there is no self-service
  tier upgrade for voice. **[docs]**

Practical read: TTS tolerates far more parallelism than Google Cloud TTS (150 RPM) or
Gemini AI Studio (10 RPM). 8–12 workers is comfortable; because there are no headers and
no published ceiling, keep retry-with-backoff on 429 rather than assuming the limit is
absent.

## Pricing

Billed on **input characters**, not output audio duration, so cost is exactly predictable
before the call: `len(text) / 1e6 * rate`. Nothing about the resulting audio length affects
the price.

**Rate: $15.00 per 1,000,000 input characters** per `docs.x.ai`, corroborated by OpenRouter's
listing of `x-ai/grok-voice-tts-1.0` and by Vapi's model page at the same figure. **[docs]**

> **Unresolved discrepancy.** Five independent April-2026 news aggregators (MarkTechPost,
> jls42, dapta.ai, Phemex, KuCoin) all reported **$4.20 per 1M characters** at launch. No
> dated pricing-change log was found to establish whether $15 is a later increase or the
> aggregators were simply wrong. The primary sources agree on $15 as of 2026-07-25, so budget
> at $15 and **verify against your own console billing** before committing to a cost model.

At $15/1M, a 40-segment podcast at ~600 chars/segment is ~24,000 chars ≈ **$0.36**.

## Streaming

`wss://api.x.ai/v1/tts` exists for streaming synthesis. **[docs]** Irrelevant for batch
rendering. A file-producing pipeline should use the unary POST, which returns complete
audio in one response.

## Voice cloning: `POST /v1/custom-voices` **[docs]**

Clone a voice from a reference clip of up to 120 seconds. The response is a voice record whose
`voice_id` is an 8-character lowercase alphanumeric string:

```json
{
  "voice_id": "nlbqfwie",
  "name": "Friendly Narrator",
  "gender": "female",
  "language": "en",
  "tone": "warm",
  "created_at": "2026-04-26T18:56:34.872993+00:00"
}
```

Pass that `voice_id` to `/v1/tts` exactly like a built-in voice. Cloned voices also work in
the realtime Speech-to-Speech session config (as `custom_voice_id`).

Note there is **no** top-level `custom_voice_id` field on `/v1/tts` itself; the cloned id
goes in the ordinary `voice_id` field. **[live: `custom_voice_id` is not in the TTS schema]**

## Minimal working call

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

The two-field minimum that actually works is `{"text": "...", "language": "en"}`. **[live]**

## Not OpenAI-compatible

xAI's chat surface is OpenAI-wire-compatible; **its audio surface is not.** `docs.x.ai`
states verbatim: *"The xAI TTS API does not work with the OpenAI SDK. It requires direct
HTTP requests or custom implementations."*

Concretely, versus OpenAI `/v1/audio/speech`: different path (`/v1/tts`), `text` not
`input`, `voice_id` not `voice`, a **required** `language` field with no OpenAI analogue,
`output_format` as an object rather than a flat `response_format` string, `speed` range
0.7–1.5 rather than 0.25–4.0, and no `model`. Do not point an OpenAI SDK's audio client at
this endpoint, and do not try to bridge it with `extra_body`. Write a small HTTP client.

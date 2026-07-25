# xAI voice: gotchas and doc-vs-live discrepancies

Every item was verified against `api.x.ai` on **2026-07-25**. Where `docs.x.ai` disagrees
with the live API, the live behavior is authoritative and the docs are noted as stale.

## The docs are behind the API. Probe before you trust.

`docs.x.ai` is a JS-heavy SPA that also blocks `WebFetch` on some paths
(`x.ai/news/*` returns Cloudflare 403). Several documented facts are wrong or stale. The
endpoint itself is the better source, and it is unusually cooperative about revealing its
own schema.

### Schema discovery without spending money

The TTS deserializer is `serde`-based and names the offending field on every rejection.
Two properties make this a precise oracle:

1. Send a **wrong type** for a candidate field. If the field exists you get
   `422 invalid type: integer '999', expected a boolean`, which reveals the real type. If it
   does not exist it is silently ignored.
2. Include `"voice_id": "__nope__"`. Any request that deserializes successfully then fails
   `404 Voice '__nope__' not found` **before synthesis runs**, so the probe costs nothing.

```bash
# Does `text_normalization` exist, and what type is it?
curl -s -X POST https://api.x.ai/v1/tts \
  -H "Authorization: Bearer $XAI_API_KEY" -H "Content-Type: application/json" \
  -d '{"text":"hi","language":"en","voice_id":"__nope__","text_normalization":999}'
# -> text_normalization: invalid type: integer `999`, expected a boolean   (field EXISTS)
```

Sending an invalid **enum** value returns the complete valid set, which is how the codec
list below was obtained rather than inferred:

```bash
-d '{"text":"hi","language":"en","output_format":{"codec":"__nope__"}}'
# -> unknown variant `__nope__`, expected one of `mp3`, `wav`, `pcm`, `opus`, `mulaw`, `ulaw`, `alaw`
```

This technique generalizes to any `serde`-backed Rust API.

## Confirmed discrepancies

| # | Docs say | Live reality |
|---|---|---|
| 1 | 5 voices: `eve`, `ara`, `leo`, `rex`, `sal` | **26 voices.** `GET /v1/tts/voices` is the only trustworthy roster. |
| 2 | codecs `mp3`, `wav`, `pcm`, `mulaw`, `alaw` | Also **`opus`** and **`ulaw`** (`ulaw` and `mulaw` are both accepted spellings). |
| 3 | `optimize_streaming_latency` (int 0–2) is a request field | **Not in the `/v1/tts` schema**, silently ignored. Likely WSS-only. |
| 4 | `reasoning_effort` is "only supported by grok-4.3" | **`grok-4.5` accepts it** without error. |
| 5 | Release notes list TTS GA in March 2025 | Internally inconsistent and contradicted by the corroborated **2026-04-17** standalone STT+TTS launch. Treat the 2025 dates as unreliable. |
| 6 | N/A | There is **no `model` field** on `/v1/tts`. Sending one returns 200 and is ignored; nothing warns you it had no effect. |

## Traps that produce wrong output rather than errors

These are the dangerous ones: the request succeeds, and the audio is wrong.

**1. Unrecognized bracket tags are spoken aloud.** The real tags are singular: `[laugh]`,
`[sigh]`. The plural forms an LLM naturally writes (`[laughs]`, `[sighs]`) are not tags
and get vocalized. Measured on identical wording (voice `luna`): baseline 1.44 s,
`[laugh]` 3.31 s (a real laugh), `[laughs]` 2.14 s (the word "laughs" spoken). A nonsense
tag `[flibbertigibbet]` added 0.98 s, also spoken.

> Any pipeline whose `text` comes from an LLM must either forbid bracketed text in the
> prompt or whitelist-filter against the exact tag list before calling `/v1/tts`.

**2. `language` is required but never validated.** `"language": "xx"` and `"language": ""`
both return 200 with audio. It is a hint, not a constraint: you get no error for sending
the wrong one, just possibly wrong pronunciation.

**3. Output is always mono.** Every sample rate, every codec: 1 channel. There is no stereo
option. Concatenating xAI segments into a stereo timeline requires re-encoding
(`ffmpeg -ac 2`) or the container's channel count will not match.

**4. Omitting `output_format` silently downgrades quality.** The default is 24 kHz / 128 kbps,
not the 44.1 kHz / 192 kbps you probably want for anything published. Set it explicitly.

## Error handling

**Two different error encodings on one endpoint.** Deserialization failures (422) are
**plain text**; semantic failures are **JSON** with a flat `error` string:

```
422  Failed to deserialize the JSON body into the target type: missing field `text` at line 1 column 2
404  {"error":"TTS synthesis failed: Voice 'x' not found"}
400  {"error":"Field `text` exceeds maximum length of 15000 characters (16000 provided)."}
400  {"error":"speed must be between 0.7 and 1.5"}
```

Neither is OpenAI's `{"error":{"message","type","code"}}` envelope. A client that
unconditionally `json.Unmarshal`s the error body will produce an empty message for every
422; parse defensively, falling back to the raw string.

**Retry only 429 and 5xx.** 404 (bad voice), 400 (length/speed), and 422 (bad shape) are
deterministic; retrying them burns wall-clock to reach the identical error.

## Rate limits: no signal, no published number

- No `x-ratelimit-*` response headers, so a client cannot self-pace from metadata.
- No `Retry-After` observed on any response.
- `docs.x.ai/developers/rate-limits` states its spend-tier table applies to "text and
  embedding models" and directs voice-limit increases to `sales@x.ai`. **There is no
  self-service tier upgrade for voice and no published numeric limit.**
- Measured: 12 concurrent requests all returned 200 in ~2 s with no throttling.

Plan for 8–12 workers, and keep exponential backoff on 429 anyway (an unpublished ceiling
is not an absent ceiling).

## Cost and timeouts

Billing is **per input character** ($15/1M), so cost is exactly predictable before the
call: `len(text)/1e6*15`. Nothing about the audio length affects price.

Wall-clock, however, tracks **output duration**, not input size: 5,000 chars produced 342 s
of audio in one call, and a ~10,000-char request blew through a 2-minute client deadline.
Size per-request timeouts from expected audio length, and prefer many small requests over
one 15,000-char request when you need bounded latency.

## Capture the trace id

Successful responses carry `x-trace-id`. It is what xAI support asks for. Log it on
failures *and* on suspicious-but-successful responses; there is no other correlation handle.

## Audio surface is not OpenAI-compatible

Chat is. Audio is not, and `docs.x.ai` says so verbatim: *"The xAI TTS API does not work
with the OpenAI SDK."* Different path (`/v1/tts` not `/v1/audio/speech`), `text` not
`input`, `voice_id` not `voice`, a required `language` with no OpenAI analogue,
`output_format` as an object not a flat string, `speed` 0.7–1.5 not 0.25–4.0, no `model`.
Do not bridge it with `extra_body`; write the HTTP call.

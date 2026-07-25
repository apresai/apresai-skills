# xAI voice: gotchas and doc-vs-live discrepancies

Items marked **[live]** were verified by direct probe against `api.x.ai` on **2026-07-25**.
Items marked **[docs]** come from `docs.x.ai` and were **not** independently confirmed:
that includes the "Docs say" column of the discrepancy table, the rate-limit quote, and the
pricing figure. Where the two disagree, the live behavior is authoritative and the docs are
noted as stale.

## The docs are behind the API. Probe before you trust.

`docs.x.ai` is a JS-heavy SPA that also blocks `WebFetch` on some paths
(`x.ai/news/*` returns Cloudflare 403). Several documented facts are wrong or stale. The
endpoint itself is the better source, and it is unusually cooperative about revealing its
own schema.

### Schema discovery without spending money

The TTS deserializer is `serde`-based and names the offending field on every rejection.
Two properties make this a precise oracle:

1. Send a **wrong type** for a candidate field. If the field exists you get
   `422 invalid type: map, expected a boolean`, which reveals the real type. If it
   does not exist it is silently ignored.
2. Include `"voice_id": "__nope__"`. Any request that deserializes successfully then fails
   `404 Voice '__nope__' not found` **before synthesis runs**, so the probe costs nothing.

> **The caveat that invalidates naive probes: the probe value must mismatch the field's
> ACTUAL type, and you do not know that type in advance.** Probing with `999` cannot detect
> an integer field: for an `i32` field, `999` is a *valid* value, so it deserializes fine
> and the request falls through to the `404` voice error, which looks identical to "field
> ignored". That flaw produced a false "`optimize_streaming_latency` does not exist"
> conclusion in an earlier pass of this file. **Probe with an object** (`{"__obj__":1}`),
> which mismatches every scalar type, so any existing field of any type has to reveal
> itself. Re-run every absence claim you made with an integer probe.

```bash
# Does `text_normalization` exist, and what type is it?
curl -s -X POST https://api.x.ai/v1/tts \
  -H "Authorization: Bearer $XAI_API_KEY" -H "Content-Type: application/json" \
  -d '{"text":"hi","language":"en","voice_id":"__nope__","text_normalization":{"__obj__":1}}'
# -> text_normalization: invalid type: map, expected a boolean          (field EXISTS, bool)

# Same curl, different body: this is what corrected the optimize_streaming_latency error.
  -d '{"text":"hi","language":"en","voice_id":"__nope__","optimize_streaming_latency":{"__obj__":1}}'
# -> optimize_streaming_latency: invalid type: map, expected i32        (field EXISTS, i32)
# with 999 instead of the object: 404 Voice not found                   (indistinguishable
#                                                                        from "ignored")
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
| 3 | `optimize_streaming_latency` (int 0–2) is a request field | **Not a discrepancy. The docs are right, and an earlier version of this file was wrong.** It exists on `/v1/tts` as an **i32**: `optimize_streaming_latency: invalid type: map, expected i32`. The retracted "not in the schema" claim came from probing with the integer `999`, a valid `i32` that deserializes cleanly (see the caveat above). **[live]** |
| 4 | `reasoning_effort` is "only supported by grok-4.3" | **`grok-4.5` accepts it** without error. |
| 5 | Release notes list TTS GA in March 2025 | Internally inconsistent and contradicted by the corroborated **2026-04-17** standalone STT+TTS launch. Treat the 2025 dates as unreliable. **[docs/news, not probeable]** |
| 6 | N/A | There is **no `model` field** on `/v1/tts`. Sending one returns 200 and is ignored; nothing warns you it had no effect. |

## Traps that produce wrong output rather than errors

These are the dangerous ones: the request succeeds, and the audio is wrong.

**1. Unrecognized bracket tags are not ignored.** The documented tags are singular:
`[laugh]`, `[sigh]`. The plural forms an LLM naturally writes (`[laughs]`, `[sighs]`) are
not on that list, and neither is nonsense, but the API renders *something* for all of them.
Measured at N=6 per condition on identical wording (voice `luna`), mean duration: baseline
1.272 s (sd 0.057), `[laugh]` 2.428 s (sd 0.280), `[laughs]` 2.232 s (sd 0.365),
`[flibbertigibbet]` 2.088 s (sd 0.426). **[live]**

> **What is proven:** a bracketed token, recognized or not, lengthens the output **on the mean**.
> The nonsense token's range dips just below both baseline ranges at its low end, so this is a
> shift in distribution, not a guarantee on any single render.
> Nothing is silently stripped, so unfiltered bracketed text is unsafe.
> **What is UNVERIFIED:** *which* sound is produced. The `[laugh]` and `[laughs]`
> distributions overlap heavily, and duration cannot separate "rendered a laugh" from
> "spoke the word". This file previously asserted that separation from single samples of a
> non-deterministic signal; that assertion is retracted, and settling it needs listening.

> Any pipeline whose `text` comes from an LLM must either forbid bracketed text in the
> prompt, or normalize known variants (`[laughs]` → `[laugh]`) and strip every bracketed
> token not on its whitelist before calling `/v1/tts`.

**2. `language` is required but never validated.** `"language": "xx"` and `"language": ""`
both return 200 with audio. It is a hint, not a constraint: you get no error for sending
the wrong one, just possibly wrong pronunciation.

**3. Output is always mono.** Every sample rate, every codec: 1 channel. There is no stereo
option. Concatenating xAI segments into a stereo timeline requires re-encoding
(`ffmpeg -ac 2`) or the container's channel count will not match.

**4. Omitting `output_format` silently downgrades quality.** The default is 24 kHz / 128 kbps,
not the 44.1 kHz / 192 kbps you probably want for anything published. Set it explicitly.

**5. Output is not reproducible.** Three identical requests (same text, same `voice_id`, no
other fields) returned three different durations (1.440 s / 1.224 s / 1.176 s) and three
different sha256 hashes. **[live]** Consequences: hashing audio is useless for caching or
dedupe, golden-file tests on the bytes will flap, re-rendering one segment shifts a
timeline, and any A/B on durations needs repeated samples (this is exactly what invalidated
the old single-sample tag measurements above).

**6. The 15,000 limit counts characters, not bytes.** 14,000 multi-byte characters
(28,000 UTF-8 bytes) deserialized fine. **[live]** A client that pre-checks with
`len(bytes)` will reject valid non-ASCII text at roughly half the real cap; count runes
(`utf8.RuneCountInString`) instead.

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

**Retry 429, 5xx, and transport/timeout errors only** (a context cancellation is not
retryable, and 401/403 never is: bad credentials do not heal). See the full table in
`go-client.md`. 404 (bad voice), 400 (length/speed), and 422 (bad shape) are
deterministic; retrying them burns wall-clock to reach the identical error.

## Rate limits: no signal, no published number

- No `x-ratelimit-*` response headers, so a client cannot self-pace from metadata.
- No `Retry-After` observed on any response.
- `docs.x.ai/developers/rate-limits` states its spend-tier table applies to "text and
  embedding models" and directs voice-limit increases to `sales@x.ai`. **There is no
  self-service tier upgrade for voice and no published numeric limit.**
- Measured: 12 concurrent requests all returned 200 in ~2 s with no throttling.

Start at 8 to 12 workers (one burst of 12 succeeded; that is not a sustained-rate
measurement), and keep exponential backoff on 429 regardless (an unpublished ceiling
is not an absent ceiling).

## Cost and timeouts

Billing is **per input character** ($15/1M), so cost is exactly predictable before the
call: `len(text)/1e6*15`. Nothing about the audio length affects price.

> The $15 figure is **[docs]**, not probed, and it is **disputed**: five April-2026 news
> aggregators reported **$4.20/1M** at launch, with no dated change log to reconcile the
> two. `tts.md` documents the conflict in full. Budget at $15 and verify against your own
> console billing before committing to a cost model.

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

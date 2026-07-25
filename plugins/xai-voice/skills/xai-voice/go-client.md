# Production Go client for xAI voice

Facts here are labeled **[live]** (probed against `api.x.ai` on 2026-07-25) or **[docs]**
(from `docs.x.ai` or published repos, not independently confirmed), matching `tts.md`.

## There is no Go SDK. Write the HTTP call.

As of 2026-07-24 `github.com/xai-org` publishes exactly two client artifacts:
`xai-sdk-python` (v1.17.0) and `xai-proto`. **No official Go, TypeScript, or Java SDK
exists.** The Python SDK does not cover TTS either: its surface is chat, images, video,
tools, structured outputs, tokenization. **[docs: repo listing, 2026-07-24]**

Community Go clients (`ZaguanLabs/xai-sdk-go` v0.9.0, `bibyzan/xai-go`,
`jeffypooo/xai-go`) are chat-focused; **none implements `/v1/tts`**. **[docs]**

`openai-go` pointed at `https://api.x.ai/v1` works for **chat** (`/v1/chat/completions`,
`/v1/responses`) because that surface is genuinely OpenAI-compatible. It does **not** work
for audio: `client.Audio.Speech.New` POSTs to `/audio/speech` with OpenAI's field names,
and every one of those differs from xAI's (see `tts.md` → "Not OpenAI-compatible").

So: **plain `net/http` for TTS, and optionally `openai-go` for chat.** A TTS client is
about 60 lines. Adding an SDK dependency buys nothing here.

## Reference implementation

This is an **excerpt**: `Client` (which holds `apiKey`, `httpClient`, `language`, `speed`),
the `APIError` type, and the `minAudioBytes` constant are elided for brevity. Everything
else, including the two input guards, is what you actually want in production.

```go
package xai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"
)

const ttsEndpoint = "https://api.x.ai/v1/tts"

// maxTTSChars is the /v1/tts input cap. It counts CHARACTERS, not bytes:
// 14,000 multi-byte characters (28,000 UTF-8 bytes) deserialized fine, which a
// byte cap would have rejected. Measure with utf8.RuneCountInString, never len(). [live]
const maxTTSChars = 15000

// bracketTag matches speech-tag-shaped tokens. Bracketed text is never silently
// ignored: at N=6 per condition, every bracketed form lengthened the mean output
// versus baseline, including a nonsense token. What the model vocalizes for
// an unrecognized tag is unverified, so do not pass one through. [live]
var bracketTag = regexp.MustCompile(`\[[^\]]*\]`)

// sanitizeSpeechTags strips bracketed tokens. If you want to keep the tags xAI
// documents, replace this with an allowlist that maps known tags through and drops
// the rest. The invariant that matters: nothing unrecognized reaches the API.
func sanitizeSpeechTags(text string) string {
	return strings.TrimSpace(bracketTag.ReplaceAllString(text, ""))
}

// ttsRequest mirrors POST /v1/tts. Field names are exact: `text` (not input),
// `voice_id` (not voice), and `language` is REQUIRED by the deserializer even
// though the server does not validate its value.
type ttsRequest struct {
	Text         string        `json:"text"`
	Language     string        `json:"language"`
	VoiceID      string        `json:"voice_id"`
	Speed        float64       `json:"speed,omitempty"`
	OutputFormat *outputFormat `json:"output_format,omitempty"`
}

type outputFormat struct {
	Codec      string `json:"codec"`
	SampleRate int    `json:"sample_rate"`
	BitRate    int    `json:"bit_rate,omitempty"`
}

// Synthesize renders text to audio bytes. The response body IS the audio:
// raw bytes with Content-Type: audio/mpeg, not a JSON envelope.
func (c *Client) Synthesize(ctx context.Context, text, voiceID string) ([]byte, error) {
	// Guard the input before spending a request: bracket tokens change the audio,
	// and the length cap is in characters, not bytes.
	text = sanitizeSpeechTags(text)
	if n := utf8.RuneCountInString(text); n == 0 || n > maxTTSChars {
		return nil, fmt.Errorf("xai tts: text is %d characters, want 1..%d", n, maxTTSChars)
	}

	body, err := json.Marshal(ttsRequest{
		Text:     text,
		Language: c.language, // "en"; required field
		VoiceID:  voiceID,
		Speed:    c.speed, // omit unless 0.7 <= speed <= 1.5
		OutputFormat: &outputFormat{
			Codec:      "mp3",
			SampleRate: 44100,
			BitRate:    192000,
		},
	})
	if err != nil {
		return nil, fmt.Errorf("marshal tts request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ttsEndpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build tts request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("xai tts request: %w", err)
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read tts response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		// Trace ID is what xAI support asks for.
		return nil, &APIError{
			StatusCode: resp.StatusCode,
			Message:    parseError(data),
			TraceID:    resp.Header.Get("x-trace-id"),
		}
	}
	if len(data) < minAudioBytes {
		return nil, fmt.Errorf("xai tts returned %d bytes (effectively empty)", len(data))
	}
	return data, nil
}

// parseError handles BOTH of xAI's error encodings: 422 deserialization
// failures arrive as plain text, semantic failures as {"error":"..."}.
// Assuming JSON on every non-2xx silently mangles 422s.
func parseError(data []byte) string {
	var envelope struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(data, &envelope); err == nil && envelope.Error != "" {
		return envelope.Error
	}
	return strings.TrimSpace(string(data))
}
```

## Classifying errors for retry

Retry semantics differ per status, and getting this wrong wastes either money or minutes. The
404 / 400 / 422 rows and the two error encodings (`422` arrives as plain text, semantic
failures as `{"error":"..."}`) were observed directly **[live]**; the 429 row was not, since
no rate limit was ever hit.

| Status | Retry? | Why |
|---|---|---|
| transport / timeout (no HTTP response) | **yes**, exponential backoff + jitter | Connection reset, DNS blip, deadline exceeded. Nothing was necessarily synthesized; treat like 5xx. Respect `ctx` cancellation, which is not retryable. |
| 429 | **yes**, exponential backoff + jitter | No `Retry-After` header was observed (no 429 was ever triggered in probing, so this is an assumption, not a measurement). Treat its absence as the default and honor it if present. |
| 5xx | **yes** | Transient. |
| 401 / 403 | **no** | Bad, revoked, or unentitled key. Retrying cannot fix credentials and just multiplies the failure. Surface it. |
| 404 (`Voice 'x' not found`) | **no** | The voice id is wrong; retrying is guaranteed to fail. Surface it. |
| 400 (length / speed) | **no** | Deterministic input rejection. Fix the input. |
| 422 | **no** | Your JSON shape is wrong. This is a code bug, not a runtime condition. |

Treat 401/403/404/400/422 as terminal and let them fail fast: a client that retries a bad
`voice_id` three times just burns wall-clock to reach the same error.

**Every retry rebills.** Billing is per **input character** **[docs]**, so a retried request
is charged again in full, at the same character count, whether or not the first attempt
produced audio. Cap attempts (3 is plenty) and never retry a terminal status.

## Concurrency

Measured: **one burst of 12 concurrent requests → all 200 in ~2 s**, no throttling. **[live]**
That is a single burst, not a sustained-rate measurement, so it does not establish a safe
steady-state QPS. There are no `x-ratelimit-*` headers and no published numeric limit for
voice endpoints (xAI directs voice-limit questions to `sales@x.ai`). **[docs]**

Use 8–12 workers as a **starting point** and watch for 429s under your own sustained load,
rather than treating it as a proven ceiling. Even so it has far more headroom than Google
Cloud TTS (150 RPM) or Gemini AI Studio (10 RPM). Keep the backoff path regardless: an
unpublished limit is not an absent limit.

## Timeouts

Size the per-request timeout from **expected output duration**, not input size. A 5,000-char
request produced 342 s of audio; a ~10,000-char request exceeded a 2-minute deadline. **[live]** For
short segments (< 1,000 chars) 60 s is generous. For anything approaching the 15,000-char
cap, allow several minutes or split the text.

## Chat (script generation) via the same key

`/v1/chat/completions` and `/v1/responses` are OpenAI-compatible and take the same
`Authorization: Bearer $XAI_API_KEY`. Strict schema-enforced JSON is **[live]**-verified
working on both `grok-4.5` and `grok-4.3`:

```json
{
  "model": "grok-4.5",
  "messages": [{"role": "user", "content": "..."}],
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "podcast_script",
      "schema": {
        "type": "object",
        "properties": {
          "segments": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {"speaker": {"type": "string"}, "text": {"type": "string"}},
              "required": ["speaker", "text"],
              "additionalProperties": false
            }
          }
        },
        "required": ["segments"],
        "additionalProperties": false
      },
      "strict": true
    }
  },
  "max_completion_tokens": 400
}
```

**[live]** 2026-07-25: returned schema-conformant JSON on the first attempt for both
models. `reasoning_effort` is accepted by `grok-4.5` (the REST reference claims it is
"only supported by grok-4.3", so the docs are behind). Deprecated `max_tokens` is still
accepted; prefer `max_completion_tokens`.

**[docs]** `docs.x.ai` labels Chat Completions legacy ("New features will come to the Responses API
first") and recommends `/v1/responses`, where the equivalent knob is
`text.format` = `{"type":"json_schema","name":...,"schema":...,"strict":true}`. Chat
Completions remains functional and is the simpler shape to drop into existing
OpenAI-compatible Go code when statefulness is not needed.

# Production Go client for xAI voice

## There is no Go SDK. Write the HTTP call.

As of 2026-07-24 `github.com/xai-org` publishes exactly two client artifacts:
`xai-sdk-python` (v1.17.0) and `xai-proto`. **No official Go, TypeScript, or Java SDK
exists.** The Python SDK does not cover TTS either: its surface is chat, images, video,
tools, structured outputs, tokenization.

Community Go clients (`ZaguanLabs/xai-sdk-go` v0.9.0, `bibyzan/xai-go`,
`jeffypooo/xai-go`) are chat-focused; **none implements `/v1/tts`**.

`openai-go` pointed at `https://api.x.ai/v1` works for **chat** (`/v1/chat/completions`,
`/v1/responses`) because that surface is genuinely OpenAI-compatible. It does **not** work
for audio: `client.Audio.Speech.New` POSTs to `/audio/speech` with OpenAI's field names,
and every one of those differs from xAI's (see `tts.md` → "Not OpenAI-compatible").

So: **plain `net/http` for TTS, and optionally `openai-go` for chat.** A TTS client is
about 60 lines. Adding an SDK dependency buys nothing here.

## Reference implementation

```go
package xai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const ttsEndpoint = "https://api.x.ai/v1/tts"

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

Retry semantics differ per status, and getting this wrong wastes either money or minutes:

| Status | Retry? | Why |
|---|---|---|
| 429 | **yes**, exponential backoff + jitter | No `Retry-After` header is sent, so backoff is your only signal. |
| 5xx | **yes** | Transient. |
| 404 (`Voice 'x' not found`) | **no** | The voice id is wrong; retrying is guaranteed to fail. Surface it. |
| 400 (length / speed) | **no** | Deterministic input rejection. Fix the input. |
| 422 | **no** | Your JSON shape is wrong. This is a code bug, not a runtime condition. |

Only 429/5xx are worth a retry loop. Treat 404/400/422 as terminal and let them fail fast:
a client that retries a bad `voice_id` three times just burns wall-clock to reach the same
error.

## Concurrency

Measured: **12 concurrent requests → all 200 in ~2 s**, no throttling. There are no
`x-ratelimit-*` headers and no published numeric limit for voice endpoints (xAI directs
voice-limit questions to `sales@x.ai`).

8–12 workers with no inter-request delay is a reasonable production setting, with far more
headroom than Google Cloud TTS (150 RPM) or Gemini AI Studio (10 RPM). Keep the 429
backoff path regardless: an unpublished limit is not an absent limit.

## Timeouts

Size the per-request timeout from **expected output duration**, not input size. A 5,000-char
request produced 342 s of audio; a ~10,000-char request exceeded a 2-minute deadline. For
short segments (< 1,000 chars) 60 s is generous. For anything approaching the 15,000-char
cap, allow several minutes or split the text.

## Chat (script generation) via the same key

`/v1/chat/completions` and `/v1/responses` are OpenAI-compatible and take the same
`Authorization: Bearer $XAI_API_KEY`. Strict schema-enforced JSON is **live-verified**
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

Live-verified 2026-07-25: returned schema-conformant JSON on the first attempt for both
models. `reasoning_effort` is accepted by `grok-4.5` (the REST reference claims it is
"only supported by grok-4.3", so the docs are behind). Deprecated `max_tokens` is still
accepted; prefer `max_completion_tokens`.

`docs.x.ai` labels Chat Completions legacy ("New features will come to the Responses API
first") and recommends `/v1/responses`, where the equivalent knob is
`text.format` = `{"type":"json_schema","name":...,"schema":...,"strict":true}`. Chat
Completions remains functional and is the simpler shape to drop into existing
OpenAI-compatible Go code when statefulness is not needed.

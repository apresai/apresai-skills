---
name: image-encoding
description: Modern web image encoding with AVIF and WebP. Use when the user asks to convert to AVIF, convert to WebP, optimize images for web, compress images for production, create responsive images, build a picture element cascade, use avifenc, use cwebp, batch convert image directories, decode webp or avif files, or inspect image metadata. Triggers on requests involving .avif files, .webp files, image compression, next-gen image formats, Lighthouse image format warnings, or format conversion between PNG/JPG/TIFF and AVIF/WebP.
---

# Image Encoding for the Web

In 2026, the canonical web image pipeline is: **AVIF primary, WebP fallback, JPEG/PNG safety net.**

- **AVIF**: ~95% global browser support (caniuse.com, May 2026). 20-50% smaller than WebP at equivalent quality. Lighthouse's preferred next-gen format.
- **WebP**: ~96% global support. Right choice for the fallback tier and for batch UI/screenshot work where AVIF's encode overhead doesn't pay off.
- **JPEG XL**: Chrome 145 (Feb 2026) ships jxl-rs decoder but it's off by default; Firefox 152 (Jun 2026) also behind a flag; Safari supports it natively since Safari 17 but no animation. Roughly 12-17% global support concentrated in Safari. Not yet production-viable: revisit H2 2026 if Chrome enables by default.
- **libwebp2**: Experimental playground, no release plan. Do not use.

Install: `brew install libavif libwebp`

---

## The `<picture>` Cascade (most important pattern)

Always serve AVIF to browsers that support it, WebP as fallback, JPEG/PNG as the final safety net:

```html
<picture>
  <source srcset="image.avif" type="image/avif">
  <source srcset="image.webp" type="image/webp">
  <img src="image.jpg" alt="Description" width="800" height="600">
</picture>
```

For responsive sizes with `srcset` + `sizes`:

```html
<picture>
  <source
    srcset="hero-800.avif 800w, hero-1600.avif 1600w, hero-2400.avif 2400w"
    sizes="(max-width: 800px) 100vw, (max-width: 1280px) 80vw, 1200px"
    type="image/avif">
  <source
    srcset="hero-800.webp 800w, hero-1600.webp 1600w, hero-2400.webp 2400w"
    sizes="(max-width: 800px) 100vw, (max-width: 1280px) 80vw, 1200px"
    type="image/webp">
  <img
    src="hero-800.jpg"
    alt="Hero image"
    width="1200"
    height="675"
    loading="eager"
    fetchpriority="high">
</picture>
```

Rule of thumb for `sizes`: describe how wide the image actually renders at each viewport breakpoint. The browser uses this to pick the right `srcset` descriptor before layout runs. Always provide `width` + `height` on the `<img>` to prevent layout shift.

---

## Next.js Image (most common pattern in this stack)

Next.js `<Image>` handles AVIF/WebP negotiation automatically via its optimizer. The default format priority since Next.js 14 is `['image/webp']`; to add AVIF, declare it explicitly.

Standard `next.config.ts` for AVIF + WebP:

```ts
// next.config.ts
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: {
    formats: ["image/avif", "image/webp"],  // AVIF tried first
    remotePatterns: [
      {
        protocol: "https",
        hostname: "your-cdn.example.com",
        pathname: "/**",
      },
    ],
  },
};

export default nextConfig;
```

Notes:
- AVIF compresses ~20% smaller than WebP but encodes ~50% slower on first request. Acceptable for CDN-cached assets; heavy for uncached pages with many images.
- With a custom `loaderFile` (as in the sophie project), Next.js optimization is bypassed entirely: serve pre-encoded AVIF/WebP from the CDN directly and use `<picture>` cascades for format negotiation instead.
- `priority` is deprecated in Next.js 16+. Use `loading="eager" fetchPriority="high"` for LCP images.

---

## When Each Format Wins

| Use case | Best choice |
|----------|-------------|
| Web photos, hero images, LCP images | AVIF primary, WebP fallback |
| Web UI, screenshots, dashboards | WebP (`-preset picture` / `-preset text`): AVIF marginal gain for small images |
| Line art, diagrams, icons | WebP lossless or AVIF lossless |
| Older browser compatibility required | WebP (broader support floor) |
| `avifenc` unavailable in the pipeline | WebP |
| Source archives, print | TIFF / PNG |
| Lambda / S3 thumbnail pipelines | WebP (smaller tooling footprint, sharp library) |
| Custom CDN loader (no Next.js optimizer) | Pre-encode AVIF + WebP; serve via `<picture>` |

---

## AVIF: avifenc

### Install

```bash
brew install libavif   # provides avifenc and avifdec
```

### Single file: recommended defaults

Per the [libavif man page (2025-04-11)](https://github.com/AOMediaCodec/libavif/blob/main/doc/avifenc.1.md), the codec default speed is **6** and the default job count is **all**. Speed 6 is the official default balance point; use it unless you have a reason to go slower.

```bash
avifenc -s 6 -j all -q 60 input.png output.avif
```

- `-s 6`: Speed 6 (libavif default; 0 = slowest/best, 10 = fastest). Suitable for batch web work. Drop to `-s 4` or `-s 2` for maximum compression of static hero assets where encode time is not a constraint.
- `-j all`: Use all CPU threads (libavif default).
- `-q 60`: Quality 60 (0 = worst, 100 = best). Broadly equivalent to JPEG 85 / WebP 85. Adjust 55-70 per content.
- `--sharpyuv`: Add when encoding from RGB sources to YUV420 for sharper chroma (same benefit as `-sharp_yuv` in cwebp). Requires libavif built with sharpyuv support.

For maximum compression of pre-published static assets:

```bash
avifenc -s 4 -j all -q 60 --sharpyuv input.jpg output.avif
```

Note on flags: `--min`/`--max` quantizer flags were deprecated in libavif 1.2.0. Use `-q`/`--qcolor` and `--qalpha` instead.

### Quality guidance

| Content | `-q` range | Notes |
|---------|------------|-------|
| Hero photos, LCP images | 55-65 | Start at 60, inspect for blocking artifacts |
| General web images | 60-70 | |
| Thumbnails | 50-60 | |
| Lossless | `--lossless` | Replaces `-q` flag |

### Lossless

```bash
avifenc --lossless -j all input.png output.avif
```

### Batch convert directory

```bash
for f in *.png *.jpg *.jpeg; do
  [ -f "$f" ] && avifenc -s 6 -j all -q 60 "$f" "${f%.*}.avif"
done
```

### Photo batch (quality 55 for aggressive compression)

```bash
for f in *.jpg; do
  [ -f "$f" ] && avifenc -s 6 -j all -q 55 --sharpyuv "$f" "${f%.*}.avif"
done
```

### Decode AVIF to PNG

```bash
avifdec input.avif output.png
```

---

## WebP: cwebp / dwebp / webpinfo

Requires libwebp >= 0.6.0 for `-sharp_yuv`; >= 1.6.0 for `-resize_mode`.

### Default flags

```
-q 85 -mt -sharp_yuv
```

- `-q 85`: Quality 85 (good size/quality balance)
- `-mt`: Multi-threaded encoding
- `-sharp_yuv`: Sharper chroma conversion; improves perceived quality at no file-size cost

### Single file

```bash
cwebp -q 85 -mt -sharp_yuv input.png -o output.webp
```

### With preset

| Content type | Preset |
|--------------|--------|
| Photographs | `-preset photo` |
| Screenshots, UI | `-preset picture` |
| Line art, diagrams | `-preset drawing` |
| Small icons | `-preset icon` |
| Text-heavy images | `-preset text` |

```bash
cwebp -q 85 -mt -sharp_yuv -preset photo image.jpg -o image.webp
```

### Lossless

```bash
cwebp -lossless -mt input.png -o output.webp
```

### With resize

```bash
# Resize to width 800, auto height (preserves aspect ratio)
cwebp -q 85 -mt -sharp_yuv -resize 800 0 input.jpg -o output.webp
```

New in libwebp 1.6.0: `-resize_mode 1` restricts resize so it only shrinks (never upscales). Useful for batch pipelines where source dimensions are variable:

```bash
cwebp -q 85 -mt -sharp_yuv -resize 1200 0 -resize_mode 1 input.jpg -o output.webp
```

### Preserve metadata

```bash
cwebp -q 85 -mt -sharp_yuv -metadata all input.jpg -o output.webp
```

### Batch convert directory

```bash
for f in *.png *.jpg *.jpeg; do
  [ -f "$f" ] && cwebp -q 85 -mt -sharp_yuv "$f" -o "${f%.*}.webp"
done
```

With preset:

```bash
for f in *.jpg; do
  [ -f "$f" ] && cwebp -q 85 -mt -sharp_yuv -preset photo "$f" -o "${f%.*}.webp"
done
```

### Decode from WebP

```bash
# To PNG (default)
dwebp input.webp -o output.png

# To other formats
dwebp input.webp -bmp -o output.bmp
dwebp input.webp -tiff -o output.tiff
```

### Batch decode

```bash
for f in *.webp; do
  [ -f "$f" ] && dwebp "$f" -o "${f%.webp}.png"
done
```

### Inspect

```bash
webpinfo -summary image.webp
```

---

## Post-gimage WebP Conversion

`gimage generate` outputs PNG (1-3 MB typical). Always convert before using in production:

```bash
# Generate, then convert (preferred for photos)
gimage generate "prompt" -o generated.png
cwebp -q 85 -mt -sharp_yuv -preset photo generated.png -o generated.webp

# Or use gimage's built-in convert
gimage convert --input generated.png --format webp

# For AVIF (better compression, slower encode)
avifenc -s 6 -j all -q 60 generated.png generated.avif
```

---

## Full Pipeline: JPEG → AVIF + WebP + `<picture>`

```bash
# Encode both formats from source JPEG
avifenc -s 6 -j all -q 60 hero.jpg hero.avif
cwebp -q 85 -mt -sharp_yuv -preset photo hero.jpg -o hero.webp

# Then use the cascade in HTML
```

```html
<picture>
  <source srcset="hero.avif" type="image/avif">
  <source srcset="hero.webp" type="image/webp">
  <img src="hero.jpg" alt="Hero" width="1200" height="675">
</picture>
```

Real project pattern (podcaster portal, media card with mobile variant):

```tsx
// Mobile-specific WebP swap via <picture> + media query (no AVIF tier needed
// when Next.js Image optimization is bypassed and sources are pre-encoded WebP)
<picture>
  <source
    media="(max-width: 767px)"
    srcSet={feature.image.replace(".webp", "-mobile.webp")}
  />
  <img
    src={feature.image}
    alt={feature.title}
    loading="lazy"
    decoding="async"
    className="..."
  />
</picture>
```

Note: none of the projects in this stack use a full AVIF + WebP `<picture>` cascade in JSX: they rely on the Next.js `<Image>` optimizer for format negotiation (except sophie, which uses a custom CDN loader that bypasses optimization and serves pre-encoded files directly).

---

## Output Location

Output to the same directory as the source file unless the user specifies otherwise.

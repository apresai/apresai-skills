---
name: image-encoding
description: Modern web image encoding with AVIF and WebP. Use when the user asks to convert to AVIF, convert to WebP, optimize images for web, compress images for production, create responsive images, build a picture element cascade, use avifenc, use cwebp, batch convert image directories, decode webp or avif files, or inspect image metadata. Triggers on requests involving .avif files, .webp files, image compression, next-gen image formats, Lighthouse image format warnings, or format conversion between PNG/JPG/TIFF and AVIF/WebP.
---

# Image Encoding for the Web

In 2026, the canonical web image pipeline is: **AVIF primary, WebP fallback, JPEG/PNG safety net.**

- **AVIF**: ~94% global browser support, 20-50% smaller than WebP at equivalent quality. Lighthouse's preferred next-gen format.
- **WebP**: ~96% global support. Still the right choice for the fallback tier and for batch UI/screenshot work where AVIF's encode overhead doesn't pay off.
- **JPEG XL**: Safari-only by default; Chrome 145 ships it behind a flag. Not yet production-viable.
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

For responsive sizes:

```html
<picture>
  <source
    srcset="hero-800.avif 800w, hero-1600.avif 1600w"
    sizes="(max-width: 800px) 100vw, 800px"
    type="image/avif">
  <source
    srcset="hero-800.webp 800w, hero-1600.webp 1600w"
    sizes="(max-width: 800px) 100vw, 800px"
    type="image/webp">
  <img src="hero-800.jpg" alt="Hero image" width="800" height="450">
</picture>
```

---

## When Each Format Wins

| Use case | Best choice |
|----------|-------------|
| Web photos, hero images, LCP images | AVIF primary, WebP fallback |
| Web UI, screenshots, dashboards | WebP (`-preset picture` / `-preset text`) — AVIF marginal gain for small images |
| Line art, diagrams, icons | WebP lossless or AVIF lossless |
| Older browser compatibility required | WebP (broader support floor) |
| `avifenc` unavailable in the pipeline | WebP |
| Source archives, print | TIFF / PNG |
| Lambda / S3 thumbnail pipelines | WebP (smaller tooling footprint) |

---

## AVIF — avifenc

### Install

```bash
brew install libavif   # provides avifenc and avifdec
```

### Single file — recommended defaults

```bash
avifenc -s 4 -j all -q 60 input.png output.avif
```

- `-s 4`: Speed 4 (0 = slowest/best, 10 = fastest). Speed 4 balances quality and encode time well for production batch work; drop to `-s 2` or `-s 0` for maximum compression of static assets.
- `-j all`: Use all CPU threads.
- `-q 60`: Quality 60 (0 = worst, 100 = best). Roughly equivalent to JPEG/WebP quality 85. Adjust 50-70 per content; lower for photos at acceptable quality.

### Quality guidance

| Content | `-q` range | Notes |
|---------|------------|-------|
| Hero photos, LCP images | 55-65 | Start at 60, inspect artifacts |
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
  [ -f "$f" ] && avifenc -s 4 -j all -q 60 "$f" "${f%.*}.avif"
done
```

### Photo batch (quality 55 for aggressive compression)

```bash
for f in *.jpg; do
  [ -f "$f" ] && avifenc -s 4 -j all -q 55 "$f" "${f%.*}.avif"
done
```

### Decode AVIF to PNG

```bash
avifdec input.avif output.png
```

---

## WebP — cwebp / dwebp / webpinfo

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

## Full Pipeline: JPEG → AVIF + WebP + `<picture>`

```bash
# Encode both formats from source JPEG
avifenc -s 4 -j all -q 60 hero.jpg hero.avif
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

---

## Output Location

Output to the same directory as the source file unless the user specifies otherwise.

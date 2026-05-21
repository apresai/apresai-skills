---
name: webp
description: Convert images to/from WebP format using cwebp/dwebp CLI tools. Use when the user asks to convert images to webp, optimize images for web, batch convert image directories, decode webp files, or inspect webp metadata. Triggers on requests involving .webp files, image compression, or format conversion between PNG/JPG/TIFF and WebP.
---

# WebP Image Conversion

Convert images using the libwebp CLI tools: `cwebp` (encode), `dwebp` (decode), `webpinfo` (inspect).

## Default Flags

Always use these flags unless the user specifies otherwise:

```
-q 85 -mt -sharp_yuv
```

- `-q 85`: Quality 85 (good balance of size/quality)
- `-mt`: Multi-threaded encoding
- `-sharp_yuv`: Sharper color conversion (better for graphics)

## Encode to WebP

### Single file

```bash
cwebp -q 85 -mt -sharp_yuv input.png -o output.webp
```

### With preset (choose based on content)

| Content Type | Preset |
|--------------|--------|
| Photographs | `-preset photo` |
| Screenshots, UI | `-preset picture` |
| Line art, diagrams | `-preset drawing` |
| Small icons | `-preset icon` |
| Text-heavy images | `-preset text` |

```bash
cwebp -q 85 -mt -sharp_yuv -preset photo image.jpg -o image.webp
```

### Lossless (for graphics needing exact pixels)

```bash
cwebp -lossless -mt input.png -o output.webp
```

### With resize

```bash
# Resize to width 800, auto height (preserves aspect ratio)
cwebp -q 85 -mt -sharp_yuv -resize 800 0 input.jpg -o output.webp
```

### Preserve metadata

```bash
cwebp -q 85 -mt -sharp_yuv -metadata all input.jpg -o output.webp
```

## Batch Convert Directory

Convert all images in a directory:

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

## Decode from WebP

### To PNG (default)

```bash
dwebp input.webp -o output.png
```

### To other formats

```bash
dwebp input.webp -bmp -o output.bmp
dwebp input.webp -tiff -o output.tiff
dwebp input.webp -ppm -o output.ppm
```

### Batch decode

```bash
for f in *.webp; do
  [ -f "$f" ] && dwebp "$f" -o "${f%.webp}.png"
done
```

## Inspect WebP Files

```bash
webpinfo -summary image.webp
```

## Output Location

Output to the same directory as the source file unless the user specifies a different location.

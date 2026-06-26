# VBXE_1024 — 1024-colour image packer for 4×256 palette hardware

`palettize4.py` takes a high-colour image and packs it into **four 256-entry
palettes** that can be switched **per 8-pixel cell** via a colour-attribute map,
so up to 1024 distinct colours can appear on screen at once. It emits raw
pixel data, four palette files, and the attribute map in the byte layouts this
project expects.

---

## The hardware model

The target can display 256 colours per palette and holds 4 palettes (1024
colours total), under three constraints:

1. A scanline normally draws through a single palette (≤256 colours per line).
2. A colour-attribute map can override which palette is active, but the
   override granularity is **8 pixels** — one attribute byte governs a run of 8
   horizontal pixels on one scanline. That run is called a **cell**.
3. Pixel data is a single 8-bit index per pixel. The index selects a *slot*;
   the active palette decides what colour that slot holds. The same index in
   two different palettes can be two different colours.

The decisive consequence of (2) and (3): **every colour inside one cell must
live in the same palette.** If colour A and colour B ever share a cell, they
are forced into the same palette; by transitivity whole chains of colours get
welded together. That, not "1024 colours," is the real constraint the packer
solves.

---

## How the packer works

### 1. Co-occurrence graph and components
Each cell's colours are unioned together (union-find). The connected
components are groups of colours that **cannot** be separated into different
palettes without duplicating or substituting a colour. The size of the largest
component is the single most important feasibility number.

### 2. Phase A — lossless packing (preferred)
If the largest component fits in one palette, the components are packed into
four bins of 256 using best-fit-decreasing. If they pack, every cell inherits
its component's palette and **no colour is lost or duplicated**. This is the
ideal outcome.

### 3. Phase B — lossy fallback
If a component is larger than a palette, or the bins won't pack, the tool drops
to cell-level assignment:
- seed 4 palettes by k-means clustering the colours in **OKLab** (perceptual)
  space;
- assign each cell greedily to the palette that adds the fewest new colours,
  preferring palettes that still have room;
- for any palette that still overflows 256, substitute its **rarest** colours
  with their nearest perceptual neighbour already in that palette.

Substitution error is measured and written to `{name}_report.txt`.

### Feasibility note
At *exactly* 1024 distinct colours there is zero slack (4×256 − 1024 = 0):
every palette must be exactly full and perfectly disjoint, which photographic
images almost never allow because gradients tangle neighbouring cells together.
If a clean result matters, quantize the source to ~950–1000 colours first
(`--colors 960`); that slack absorbs the unavoidable boundary duplication.

---

## Usage

```
python3 palettize4.py INPUT.png --out OUTDIR [options]
```

Requires Python 3 with `numpy` and `Pillow` (`pip install numpy pillow`).

| Option        | Default | Meaning                                                        |
|---------------|---------|----------------------------------------------------------------|
| `--out DIR`   | `out`   | Output directory.                                              |
| `--name BASE` | input stem | Base name for the `.map`/`.raw`/`.pal` files (default: input filename without extension). |
| `--cell N`    | `8`     | Pixels per attribute cell.                                     |
| `--palettes N`| `4`     | Number of palettes.                                            |
| `--slots N`   | `256`   | Entries per palette.                                           |
| `--reserve0` / `--no-reserve0` | on | Reserve slot 0 as transparent in every palette (255 usable). On by default. |
| `--colors N`  | auto    | Pre-quantize the source to N colours (auto = palettes × slots).|
| `--resize WxH`| off     | Resample to WxH before packing, e.g. `320x240` or `160x240`.   |
| `--filter F`  | lanczos | Resampling filter: `nearest box bilinear hamming bicubic lanczos`. |
| `--fit MODE`  | stretch | Aspect handling: `stretch`, `cover`, or `fit` (see below).      |
| `--display-aspect R` | 4:3 | True on-screen aspect for `cover`/`fit`, e.g. `4:3`.      |
| `--color-bias 0..1` | 0.0 | Slider: 0 = fewest artifacts (fidelity), 1 = most colours. |
| `--max-colors`| off     | Shorthand for `--color-bias 1.0`.                              |
| `--coherence L` | 1.5 | Spatial smoothing of the attribute map (higher = fewer block artifacts). |
| `--optimize` / `--no-optimize` | on | Reduce cross-palette duplication in the fidelity strategy. |
| `--dither ALGO` | none | Error-diffusion dither during colour reduction (breaks gradient banding): `none floyd atkinson jjn stucki sierra burkes`. |
| `--dither-strength 0..1` | 1.0 | Fraction of error diffused (lower = subtler). |
| `--seed N`    | `0`     | RNG seed for the k-means seeding in Phase B.                   |
| `--quiet`     | off     | Suppress the stdout report (files still written).             |
| `--json`      | off     | Print machine-readable stats as JSON to stdout (implies quiet text). |

If the source has more than `palettes × slots` unique colours it is first
reduced with a weighted median-cut quantizer.

Example:

```
python3 palettize4.py myart.png --out build --colors 960
```

---

## Input formats

The input does **not** have to be a PNG. The file is opened with Pillow and
immediately converted to RGB, so any format Pillow can decode is accepted —
on a normal install that includes **JPEG, PNG, BMP, GIF, TIFF, WebP, TGA,
PCX, ICO, PPM/PNM** and more. Format is detected from the file contents, not
the extension, so the filename's extension does not have to match.

```
python3 palettize4.py portrait.jpg --out build --resize 320x240 --filter lanczos --fit cover
python3 palettize4.py sprite.bmp   --out build --resize 320x240 --filter nearest
```

Caveats:

- **Source alpha is flattened.** Converting to RGB drops the input's alpha
  channel; an RGBA PNG or a GIF with a transparent index is composited to opaque
  (transparent areas typically become black) before packing. The output's own
  transparency is index 0 (see below), independent of the source alpha.
- **Prefer lossless originals for photos.** JPEG compression adds subtle colour
  noise across smooth regions (skin tones, gradients), inflating the unique-colour
  count and pushing portraits deeper into the lossy Phase B. If you have the image
  as PNG/TIFF/BMP, feed that instead of a re-saved JPEG. JPEG still works — just
  check the substitution percentage in `{name}_report.txt`.
- **First frame only.** Animated GIFs and multi-page TIFFs are read as their
  first frame. Video and vector formats are not supported.

---

## Dithering (gradient banding)

Smooth-gradient sources (plasmas, skies, soft shading) have far more colours than
the 1020-colour budget, so the median-cut reduction snaps them into visible
**bands** (contour rings). `--dither` applies error-diffusion *during that
reduction*, spreading each pixel's quantization error to its neighbours so the
gradient becomes fine texture instead of bands.

Available kernels: `floyd` (Floyd–Steinberg, the classic), `atkinson` (diffuses
only ¾ of the error — cleanest/least noisy on limited palettes, good default to
try first), `jjn` (Jarvis-Judice-Ninke), `stucki`, `sierra`, `burkes`.
`--dither-strength` (0–1) scales how much error is diffused for a subtler effect.

```
python palettize4.py plasma.png --out build --dither atkinson
```

Dithering happens before the palette packing, so the result is still subject to
the 8×1-pixel cell constraint — but because the dither's two bracketing colours
are local neighbours, they almost always land in the same cell palette and
survive. In testing on a full-screen plasma it removed the banding while only
raising recoloured pixels from ~2.9% to ~3.5%. A few isolated cells can still
pick up a stray recoloured pixel where the dithered colours don't all fit one
palette; raising `--color-bias` (more colours available) or using `atkinson`
(less noise) minimizes those. Requires `scipy` (`pip install scipy`); only needed
when `--dither` is used.

---

## Maximizing colour count

When the output uses fewer colours than you hoped, the cause is almost always
**cross-palette duplication**, not the source being short of colours. Because a
colour can only display through a palette a cell is using, a colour that appears
in cells scattered across the image must be copied into every palette those cells
land on — and each copy consumes one of the 4×255 slots. Images with colours
spread all over (a "pixelated" or busy look, where the same shades recur
everywhere) duplicate heavily; the duplicates fill the slots and the colours that
no longer fit get merged away. Smooth images, where each colour lives in a
localized region, barely duplicate and keep almost everything.

The report makes this visible: compare `master colours` (input) with `output
colours` (result), and read `duplicated across palettes`. A large duplicated
count with `output < master` is the signature of this problem.

Colour count and per-pixel accuracy trade off against each other, controlled by
**`--color-bias`** (0.0–1.0):

- **`--color-bias 0.0` (default, "fidelity").** Every pixel keeps its exact
  colour; colours are duplicated across palettes as needed and only merged when a
  palette overflows. No block artifacts. Optimal — zero loss — whenever the
  colours fit the slot budget, and the right choice for photographs.
- **`--color-bias 1.0` (= `--max-colors`).** Display as many distinct colours as
  possible. Each colour is placed in the palette where it's most used and the
  remaining slots go to the highest-demand duplicates; pixels whose colour isn't
  in their cell's palette are recoloured to the nearest available one. Maximizes
  colours but, because a whole 8-pixel cell commits to one palette, can produce
  visible recoloured **blocks** where cells straddle a colour boundary.
- **Intermediate values** slide smoothly between the two. The colour count rises
  monotonically with the bias while the spare slots available to suppress blocks
  fall. `0.5`–`0.75` is often the sweet spot for busy/pixelated images: most of
  the extra colours, far fewer blocks than `1.0`.

The bias slider chooses how to spend the slot budget: low bias spends slots on
duplicates (exact colours, no blocks, fewer distinct colours); high bias spends
them on distinct colours (more colours, more recolouring). Check `recoloured
pixels` / `mean OKLab error` in the report to judge a given bias.

**Block artifacts and `--coherence`.** When `--color-bias > 0`, the attribute map
is built by repeatedly assigning each cell to the palette that minimizes the
cell's total perceptual (OKLab) error and re-deriving the palette contents, so
the two agree. Because each 8-pixel cell commits to one palette, neighbouring
cells deciding independently can produce visible blocks/streaks in mixed or
smooth regions. `--coherence` (default 1.5) adds a penalty for a cell disagreeing
with its neighbours, so regions settle on one palette and the blocks disappear;
raise it if you still see blocky patches, lower it (toward 0) for the most
literal per-cell choice. This keeps perceptual error roughly flat as colour count
climbs, so high bias values stay clean rather than blocky.

---

## Resizing and pixel aspect ratio

The packer works pixel-for-pixel: without `--resize` the source must already be
at the target resolution. With `--resize` it resamples first.

**Choosing a filter.** Use `--filter nearest` for pixel art / indexed art — it
blends nothing, adds no new colours, and keeps hard edges crisp. Use
`--filter lanczos` (the default) for photographs and portraits; `box` is a good
alternative for clean area-average downscales.

**Pixel aspect.** 320×240 is 4:3, so its pixels display roughly **square**.
160×240 is 2:3, so its pixels display about **twice as wide as tall** (2:1).
The clean rule: start from a square-pixel **4:3 master** and resample to the
exact target grid — the on-screen proportions then come out right in *both*
modes, because the hardware's horizontal stretch cancels the lost horizontal
samples in 160-wide mode.

**When the source is not 4:3** (most portrait photos), `--fit` controls it:
- `stretch` (default) — resample straight to WxH. Correct for a 4:3 master;
  distorts other aspects.
- `cover` — centre-crop the source to the on-screen aspect, then resample.
  Fills the frame with no distortion (trims edges). Best for portraits.
- `fit` — letterbox/pillarbox the source to the on-screen aspect, then resample.
  Shows the whole image, no distortion. The padding bars are written as
  **index 0 (transparent)** in every palette, so they read as the background
  rather than consuming a real palette colour.

`cover` and `fit` use `--display-aspect` (default `4:3`) as the true on-screen
shape, so the 160-wide 2:1-pixel case is handled correctly without extra math.

Examples:

```
# portrait photo -> 320x240, crop to fill, high-quality downscale
python3 palettize4.py portrait.jpg --out build --resize 320x240 --filter lanczos --fit cover

# same portrait into the 2:1-pixel 160-wide mode (still looks 4:3 on screen)
python3 palettize4.py portrait.jpg --out build --resize 160x240 --filter lanczos --fit cover

# pixel art already at native size, just pack it (no resize)
python3 palettize4.py sprite.png --out build

# pixel art that must be scaled, keep it crisp
python3 palettize4.py sprite.png --out build --resize 320x240 --filter nearest
```

---

## Output files

Written into the `--out` directory. `{name}` is set by `--name`, or defaults to
the input filename without its extension (e.g. `dragon.png` → `dragon`):

| File            | Size                 | Format                                                       |
|-----------------|----------------------|--------------------------------------------------------------|
| `{name}.raw`    | width × height bytes | One 8-bit palette index per pixel, **row-major**.            |
| `{name}0.pal`   | 768 bytes            | 256 entries, each an **R, G, B** byte triplet.               |
| `{name}1.pal`   | 768 bytes            | same                                                         |
| `{name}2.pal`   | 768 bytes            | same                                                         |
| `{name}3.pal`   | 768 bytes            | same                                                         |
| `{name}.pal`    | 4 × 768 = 3072 bytes | all palettes concatenated, palette-major (palette 0 first).  |
| `{name}.map`    | cells × height bytes | One byte per cell: palette id (0–3) **× 16** → `0,16,32,48`. Sequential row-major. |
| `{name}_preview.png` | —                    | Reconstruction as the hardware would display it.            |
| `{name}_palettes.png` | —                    | Swatch sheet of all palettes (visual reference).            |
| `{name}_report.txt` | —                    | Stats: components, lossless/lossy, substitution error, etc. |
| `{name}_stats.json` | —                    | The same stats, machine-readable (for tools / a GUI).       |

`{name}_preview.png`, `{name}_palettes.png`, and `{name}_report.txt` are references for inspection
and are not part of the data the hardware consumes.

### Scripting / batch use
For driving the converter from a GUI or batch script, use `--quiet` to silence the
text report and read `{name}_stats.json` (always written) for results, or use
`--json` to print the same stats object to stdout. Keys include `output_colours`,
`master_colours`, `recoloured_pixels`, `recoloured_pct`, `mean_oklab_error`,
`strategy`, `color_bias`, `coherence`, `duplicated_across_palettes`, `lossless`,
`per_palette`, and a `files` map of every output filename produced.

### Index / scan ordering details
- **`{name}.raw`** is laid out one full scanline at a time, left to right, top to
  bottom.
- **`{name}.map`** matches that order: all of scanline 0's cells (left to
  right), then scanline 1's, and so on. Each byte holds the palette id (0–3)
  shifted into the high nibble, i.e. multiplied by 16, giving `0,16,32,48`
  (so the palette number sits in bits 4–7). Cells-per-line is
  `ceil(width / cell_width)`; if the width is not a multiple of the cell width,
  the last cell of each line simply covers the remaining pixels.
- **`{name}#.pal`** stores three straight 8-bit bytes per entry in R, G, B
  order. If your palette hardware expects a packed form (e.g. 12-bit `0RGB` or
  15-bit BGR) the writer needs a small change.

### Transparency (slot 0)
By default (`--reserve0`, on) **slot 0 is reserved as transparent in every
palette** and never assigned to a real colour, leaving 255 usable entries per
palette. Pixel index 0 therefore means "transparent / background" regardless of
which palette a cell uses. The reconstruction stores `(0,0,0)` there so previews
show it as black. Letterbox/pillarbox bars from `--fit fit` are written as index
0 so they read as transparent. Pass `--no-reserve0` to disable this and reclaim
the 256th slot (do this only if you do not need a transparent index).

### Reconstructing in code (reference)
For each pixel `(x, y)`:

```
cell     = x / cell_width
palette  = {name}.map[y * cells_per_line + cell] / 16    # high nibble -> 0..3
index    = {name}.raw[y * width + x]
colour   = {name}{palette}.pal[index * 3 .. index * 3 + 2]   # R, G, B
```

---

## Correctness

The pipeline is verified by an independent round-trip: rebuilding the image
purely from `{name}.raw` + the four `{name}#.pal` files + `{name}.map` reproduces
`{name}_preview.png` pixel-for-pixel. Test cases:

- A "blocky" image with four clean 250-colour regions packs **losslessly**
  (Phase A; each palette 250/256; infinite PSNR).
- A smooth gradient quantized to 1024 colours, with a tangled 515-colour
  component that cannot fit one palette, lands in **Phase B**: ~1.5% of pixels
  substituted at a mean OKLab error of ~0.012 (below the visible-difference
  threshold), ~41 dB PSNR.

---

## Open items to confirm against the real hardware

These are deliberately left as defaults until verified:

1. **Attribute-map scan order** — currently row-major matching `{name}.raw`. If
   the display walks attributes column-major or per-tile, the writer must
   follow that pattern.
2. **Palette entry format** — currently three full 8-bit RGB bytes (768 bytes
   per palette). Confirm whether the hardware wants packed/reduced-depth
   entries or a different channel order.
3. **Reserved indices** — slot 0 is reserved as transparent by default
   (`--reserve0`). If a *different* slot is the special one, or none is, adjust
   accordingly (`--no-reserve0` frees slot 0).

Tell me the exact expectations for any of these and the relevant writer can be
adjusted to emit them directly.

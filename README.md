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

Substitution error is measured and written to `report.txt`.

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
| `--cell N`    | `8`     | Pixels per attribute cell.                                     |
| `--palettes N`| `4`     | Number of palettes.                                            |
| `--slots N`   | `256`   | Entries per palette.                                           |
| `--reserve0`  | off     | Keep slot 0 unused (e.g. transparent); 255 usable per palette. |
| `--colors N`  | auto    | Pre-quantize the source to N colours (auto = palettes × slots).|
| `--seed N`    | `0`     | RNG seed for the k-means seeding in Phase B.                   |

If the source has more than `palettes × slots` unique colours it is first
reduced with a weighted median-cut quantizer.

Example:

```
python3 palettize4.py myart.png --out build --colors 960
```

---

## Output files

Written into the `--out` directory:

| File            | Size                 | Format                                                       |
|-----------------|----------------------|--------------------------------------------------------------|
| `image.raw`     | width × height bytes | One 8-bit palette index per pixel, **row-major**.            |
| `palette0.pal`  | 768 bytes            | 256 entries, each an **R, G, B** byte triplet.               |
| `palette1.pal`  | 768 bytes            | same                                                         |
| `palette2.pal`  | 768 bytes            | same                                                         |
| `palette3.pal`  | 768 bytes            | same                                                         |
| `attrib.map`    | cells × height bytes | One byte per cell (palette **0–3**), sequential row-major.   |
| `preview.png`   | —                    | Reconstruction as the hardware would display it.            |
| `palettes.png`  | —                    | Swatch sheet of all palettes (visual reference).            |
| `report.txt`    | —                    | Stats: components, lossless/lossy, substitution error, etc. |

`preview.png`, `palettes.png`, and `report.txt` are references for inspection
and are not part of the data the hardware consumes.

### Index / scan ordering details
- **`image.raw`** is laid out one full scanline at a time, left to right, top to
  bottom.
- **`attrib.map`** matches that order: all of scanline 0's cells (left to
  right), then scanline 1's, and so on. Cells-per-line is
  `ceil(width / cell_width)`; if the width is not a multiple of the cell width,
  the last cell of each line simply covers the remaining pixels.
- **`palette#.pal`** stores three straight 8-bit bytes per entry in R, G, B
  order. If your palette hardware expects a packed form (e.g. 12-bit `0RGB` or
  15-bit BGR) the writer needs a small change.

### Reconstructing in code (reference)
For each pixel `(x, y)`:

```
cell     = x / cell_width
palette  = attrib.map[y * cells_per_line + cell]
index    = image.raw[y * width + x]
colour   = palette#{palette}.pal[index * 3 .. index * 3 + 2]   # R, G, B
```

---

## Correctness

The pipeline is verified by an independent round-trip: rebuilding the image
purely from `image.raw` + the four `.pal` files + `attrib.map` reproduces
`preview.png` pixel-for-pixel. Test cases:

- A "blocky" image with four clean 250-colour regions packs **losslessly**
  (Phase A; each palette 250/256; infinite PSNR).
- A smooth gradient quantized to 1024 colours, with a tangled 515-colour
  component that cannot fit one palette, lands in **Phase B**: ~1.5% of pixels
  substituted at a mean OKLab error of ~0.012 (below the visible-difference
  threshold), ~41 dB PSNR.

---

## Open items to confirm against the real hardware

These are deliberately left as defaults until verified:

1. **Attribute-map scan order** — currently row-major matching `image.raw`. If
   the display walks attributes column-major or per-tile, the writer must
   follow that pattern.
2. **Palette entry format** — currently three full 8-bit RGB bytes (768 bytes
   per palette). Confirm whether the hardware wants packed/reduced-depth
   entries or a different channel order.
3. **Reserved indices** — if index 0 (or any slot) is special (transparent /
   border), run with `--reserve0` so the packer never assigns it.

Tell me the exact expectations for any of these and the relevant writer can be
adjusted to emit them directly.

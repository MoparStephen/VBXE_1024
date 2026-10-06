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
| `--dither ALGO` | none | Dither during reduction to break banding. Error-diffusion: `floyd atkinson jjn stucki sierra burkes`; ordered: `bayer2 bayer4 bayer8 blue`. |
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

## The GUI — VBXE PAL Studio

Four of the options above — `--dither`, `--dither-strength`, `--color-bias`
and `--coherence` — cannot be judged from a number. You have to look at the
result, and from a command line that means edit, re-run, open the PNG, and try
to remember what the last one looked like. `Convertor/palgui/` is a PySide6
front end that closes that loop.

```
run_palgui.cmd            (Windows — works from anywhere, including Explorer)
./run_palgui.sh           (elsewhere)
```

Both force the venv's interpreter and `Convertor` as the working directory;
by hand it is `cd Convertor && ..\.venv\Scripts\python -m palgui`. One-off
setup:

```
python -m venv .venv
.venv\Scripts\python -m pip install PySide6 Pillow numpy scipy
```

The venv needs **numpy, Pillow and scipy as well as Qt**, because Preview
shells out to `palettize4.py` under the same interpreter. Miss scipy and
everything works until the first dithered run.

### Standalone Windows build (no Python)

For anyone who just wants to run it: download **`VBXE PAL Studio v<version>.zip`**
from the [Releases](../../releases) page, unzip it anywhere writable (Desktop,
Documents, a data drive — not `C:\Program Files`), and double-click
**`VBXE PAL Studio.exe`**. No Python, no `pip`, no `PATH`, nothing to install.
The same folder also has **`palettize4.exe`** — the converter with the exact
options above, for the command line. Output lands in `VBXE PAL Studio\out\`,
saved presets in `VBXE PAL Studio\presets\`.

Building the zip yourself: `pwsh ./build_app.ps1` from the repo root, or push a
`v*` tag to let GitHub Actions build it. See [`packaging/README.md`](packaging/README.md).

**Preview runs the real converter.** It shells out to `palettize4.py --json`
into a scratch directory and shows the `{name}_preview.png` it wrote, so what
is on screen is byte for byte what Convert will put on disk — there is no
second implementation of the packer in the GUI that could drift away from this
one. The GUI drives the converter entirely through the `--quiet` / `--json` /
`{name}_stats.json` interface described under *Scripting / batch use* below,
plus `resize_image()` imported as a function — it holds no copy of the packing
logic. (The one change the GUI prompted inside `palettize4.py` was the
diagonal-at-a-time error diffusion described under *Dithering*, which speeds up
the CLI equally and leaves its output unchanged.)

What it adds over the command line:

- **A flip, not a side-by-side.** Source and result share one zoom and one pan,
  and hold SPACE (or press A / B) to swap them in place. Two pictures six
  inches apart tell you almost nothing about a dither; one that swaps under the
  same magnifier turns the difference into motion. The source pane shows the
  image *resampled the way the run will resample it*, so the flip compares a
  dither rather than a resize. Nearest-neighbour at every zoom — a smooth scale
  is precisely a filter for removing the grain you are trying to judge.
- **The numbers, ranked.** Colours out against the budget, what the loss cost,
  then the duplication and component figures that explain why you did not get
  more — with the README's own advice attached when they point somewhere.
- **The four palettes**, read back out of the `.pal` files, with unused slots
  hatched so 12/255 cannot be mistaken for 254/255.
- **A warning when `--dither` did nothing.** Dithering only happens inside the
  pre-quantization branch, so on a source already within the budget the flag is
  accepted and ignored. Without the warning, comparing three dithers on a piece
  of pixel art gives three identical pictures and no explanation.
- **One folder per image.** A conversion writes into `out/<name>/` rather than
  dropping eleven files into a flat `out/`, so converting a second picture
  cannot bury or overwrite the first. The `Copy command line` button and the
  `run with` block both name that folder, so the line still reproduces the run
  when you paste it.
- **Preview snapshots** (off by default, a tick box under *Output*). Every
  Preview then leaves a numbered pair in `out/<name>/previews/`:
  `Preview_01.png`, the converted 320x240 picture with its exact colours, and
  `Preview_01.txt`, holding the command line that would reproduce it, every row
  of the Result tab, and `palettize4`'s own report in full. This is what makes
  a dither comparison survive the afternoon — a preview otherwise lives in a
  scratch directory the next one overwrites. Numbering is max + 1, so deleting
  `Preview_02` never causes a later run to overwrite `Preview_03`. The `.txt`
  ends with a `[data]` line holding the settings and the stats verbatim, so the
  pair can be read back in full — see below.
- **Stepping back through a folder of previews** (the *Previews* panel, or
  `File > Browse previews...`). Point it at an `out/<image>/previews` directory
  and every pair becomes a row. Landing on one puts its picture in the middle
  pane, its summary in the Report tab, its numbers in the Result tab **and its
  settings back in the options panel** — so when one of thirty wins, `Convert`
  is the next click. `Alt+Left` / `Alt+Right` (or the toolbar arrows) step
  without moving your eye off the picture; they walk the queue's finished jobs
  instead when no previews are loaded. Snapshots written before the `[data]`
  footer existed still give back every setting, because the command line in
  them is parsed — only their numbers are missing, and the row says so rather
  than showing a blank.
- **How far the result is from the ideal, and how blocky.** Every run now
  measures the picture the viewer will show against the same image resized and
  reduced to the same colours but with *no* 8-pixel cell restriction — the
  result the hardware is not allowed to produce. `RMSE` / `PSNR` say how far
  apart they are; `cells damaged` says how much of the picture sits inside a
  compromised cell; `cell seams` says whether the cell grid has become
  **visible**, as a multiple of the seam the ideal image already had (`1.00x` =
  the grid added nothing). Queue one image at three colour biases and read the
  trade straight off the result column: the colour count climbs while the dB
  falls. This is the number for choosing 700 clean colours over 900 blocky
  ones — **RMSE and PSNR cannot see blockiness**, because the same total error
  scores the same whether it lands as noise or as stripes.
- **A batch queue, with two ways to run it.** Queue the same image several
  times with different dithers, or a set of images with one recipe, and read
  the colour counts down the table. Clicking a finished row brings back
  everything it produced — its picture, its report and its settings — so a
  batch is something you walk through afterwards rather than a column of
  numbers.
  - **Run all** converts: one output directory per image. A conversion is
    named after its image, so *fifteen jobs on one picture all write the same
    eleven filenames* and you keep only the last. The queue says so before you
    press it rather than after.
  - **Preview all** (`Ctrl+F5`) runs the same jobs as previews and keeps a
    numbered snapshot of each, so all fifteen survive side by side in
    `out/<image>/previews/` — and the Previews panel opens on them when the
    queue finishes. This is the one to use for comparing variants of a single
    image. It switches the snapshot tick box on if it is off, because
    otherwise the run would keep nothing.
- **A queue is a file, and a file is a script.** `Save...` / `Load...` in the
  queue panel (also `File > Save queue...`) write a `.json` holding the jobs
  and deliberately *not* their results — a stale colour count from a source
  that has since been edited would be a lie that looks exactly like a fact.
  **`Retarget...`** points every job in the queue at a different image and
  clears each job's output name, so one saved experiment runs over any
  picture: load, retarget, Preview all, step through.
- **Presets** (`Convertor/palgui/presets/*.json`, a recipe without the paths)
  and a **Copy command line** button that puts the equivalent
  `palettize4.py ...` invocation on the clipboard.
- **Every conversion keeps its recipe** (0.19). A real Convert — single or
  queued — also writes `out/<name>/{name}_summary.txt`: the same file a
  `Preview_NN.txt` is, i.e. the `run with` line, every row of the Result tab,
  `palettize4`'s report in full, and the `[data]` settings footer. It is the
  record to go back to when an image needs converting again.
  **`File > Load settings from...`** puts every setting (input and description
  included) back into the panel from a `_summary.txt`, a `Preview_NN.txt` or a
  `_stats.json` — one image's recipe, without saving a preset per image.
- **Re-converting what is already converted.** `File > Build re-conversion
  queue...` (or `python recover_queue.py out --search "..\Images To Convert"`)
  looks at every `out/<image>/` folder, recovers the settings it was made with,
  and fills the queue with one job per image, each writing back into its own
  folder — then `Run queue (convert)`. Settings come from, best first: the
  `_summary.txt`; a `previews/Preview_NN.png` that is pixel-identical to the
  conversion's `_preview.png` (that snapshot's settings made it); or the
  `_stats.json` + `_report.txt`, with an unrecorded dither settled by
  re-running `none` and `blue` and keeping the one that reproduces the old
  picture exactly. Each row says which (`exact` / `preview match` /
  `verified` / `best guess`). Source images that have moved are found by
  filename under the search folder. Old long-named files a re-conversion will
  not replace (`Charger 01.v1k` beside the new `CHARGER0.v1k`) are listed, not
  touched.
- **Changing a description after converting.** `File > Edit descriptions...`
  lists every conversion under a folder with its description editable; Save
  rewrites the four files that carry it — `_stats.json` (what Gather puts in
  `images.lst`), `_report.txt`, the `.nfo` Info screen and `_summary.txt` —
  exactly as a conversion with `--description` would have, and never touches
  the picture. From a shell: `python set_description.py out --export
  descriptions.txt`, edit the `folder = description` lines, then
  `python set_description.py out --apply descriptions.txt --go`.
- **Deleting previews.** Tick the `del` box on rows in the Previews panel and
  press `Delete marked...`; after a Yes / No confirmation naming every file,
  their `.png` and `.txt` are removed from disk.
- **`File > Close image`** (`Ctrl+F4`) empties the picture panes and the image
  fields (input, name, description) and keeps every other setting.
- The version is in the title bar and in `Help > About`.
- **Panels you cannot lose.** All five docks are closable, and `View > Panels`
  lists them as checkable items (plus `Show all`); `View > Reset panels` puts
  the whole layout back where it started. The arrangement, the window geometry
  and the snapshot tick box are remembered between sessions.

**The GUI targets one hardware configuration and does not offer the four flags
that would change it.** `--resize` is fixed at `320x240`, `--cell` at `8`,
`--palettes` at `4` and `--slots` at `256`, because that is the mode the VBXE
viewer runs; a conversion at any other setting produces files it cannot
display, so those controls could only ever be used by accident. The panel
states them instead. `--filter`, `--fit` and `--display-aspect` are still
controls, because *how* a source is fitted into 320x240 remains a real choice.
Everything else — a wider cell, a cut-down palette, the 2:1-pixel `160x240`
mode — is still available from `palettize4.py` on the command line, which is
unchanged.

Checking an install:

```
run_palgui.cmd --selftest                              # builds every pane offscreen,
                                                       #   runs one real conversion
cd Convertor && python -m unittest discover -s palgui/tests -t .
```

The selftest writes only into temporary directories; it never touches `out/`.

The tests run on the **system Python with nothing installed** — nothing below
`palgui/ui/` imports Qt. One of them scrapes `palettize4.py --help` and fails
if the GUI cannot produce a flag the converter offers, which is what will catch
a twenty-second option being added here and forgotten there.

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

Two families are available:

- **Error-diffusion** — `floyd` (classic), `atkinson` (gentlest), `jjn`, `stucki`,
  `sierra`, `burkes`. Smooth and organic, but can leave faint random colour
  speckle, and because it concentrates error into some cells, occasionally
  produces a stray recoloured pixel after packing. Sequential in principle, but
  computed a diagonal at a time rather than a pixel at a time (see below), so
  it is no longer the slow option it was.
- **Ordered** — `bayer2/4/8` (fast, deterministic, but show a regular grid
  texture) and **`blue`** (blue-noise via void-and-cluster). Vectorized and fast.

**`blue` is the recommended choice for smooth sources.** Blue-noise spreads its
perturbations evenly, so it breaks banding with a fine, even grain that has
neither Bayer's grid pattern nor error-diffusion's random speckle — and because
every 8×1 cell receives a balanced set of colours, it survives the palette
packing best (fewest stray pixels, and it retained the most output colours in
testing). The mask is generated once and cached, so bulk runs stay fast.

```
python palettize4.py plasma.png --out build --dither blue
```

**Why error diffusion is not slow any more.** Each pixel's error goes to
neighbours below and to the right, so the obvious implementation is a per-pixel
Python loop with one nearest-colour query each — which on an 800×600 source took
about 7 seconds. Numbering the diagonals `k = x + 3y` puts every pixel a given
pixel depends on strictly earlier, so a whole diagonal can be resolved in one
vectorized step. That is ~15x faster (800×600 floyd: 6.8s → 0.4s) for
**byte-identical output** — the diagonals impose the same read ordering the
scan did. The tests check the fast path against a plain serial implementation
on every kernel, so the two cannot drift apart.

`--dither-strength` scales the effect: for error-diffusion it's the fraction of
error diffused; for ordered/blue it scales the perturbation amplitude (1.0 is a
good default, higher breaks wider bands at the cost of more visible grain).

Dithering happens before palette packing, so the result is still subject to the
8×1 cell constraint — but the dither's bracketing colours are local neighbours
that almost always share a cell palette and survive. Requires `scipy`
(`pip install scipy`); only needed when `--dither` is used.

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
them on distinct colours (more colours, more recolouring).

To judge a given bias, read the report's **`accuracy vs the ideal`** block
rather than `mean OKLab error` on its own — that one averages over *recoloured
pixels only*, so it can fall while a run gets worse simply because the run
recoloured more pixels more gently. The block compares the displayed image
against the same image quantized to the same colours with no cell restriction,
so the quantization loss cancels and what remains is exactly what the 8-pixel
cell cost:

```
accuracy vs the ideal (what the 8-px cell rule cost):
  identical pixels   : 75016 / 76800  (97.68% of opaque px)
  RMSE (sRGB)        : 2.84     <- the norm distance
  PSNR               : 39.1 dB
  mean OKLab error   : 0.0006  (every pixel, not just the recoloured ones)
  worst OKLab error  : 0.2009
  cells damaged      : 674 / 9600  (7.0%)
  cell seams         : 1.38x
```

`cell seams` is the blockiness measure, and it is the reason the block exists:
the run above scores 39 dB and damages only 7% of its cells, yet its cell
boundaries jump **38% harder than the ideal's do**, which is visible striping.
No distance metric can report that — the same total error scores identically
whether it arrives as scattered noise or as 8-pixel stripes — so the ratio of
the jump across cell boundaries to the jump everywhere else is measured
directly, and divided by the same ratio taken on the ideal so that a source
with genuine vertical edges on the 8-pixel grid does not read as blocky when
nothing went wrong. Letterbox pixels are excluded from every count.

In practice: `1.0x`–`1.1x` shows nothing, and past roughly `1.3x` the grid is
plain. Raising the bias buys colours and spends seams; lowering it does the
reverse. (Both notes appear in the GUI's Result tab and will therefore give you
opposite advice at once — that contradiction *is* the trade.)

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
| `{name}_report.txt` | —                    | Human-readable stats: colour counts, lossless/lossy, substitution error, etc. Fixed 80-column layout (see below). |
| `{name}.nfo`     | records × 160 bytes  | The same report as the Atari viewer's **"About" screen** consumes it — see below. |
| `{name}_stats.json` | —                    | The same stats, machine-readable (for tools / a GUI), plus `args` (every option the run was given) and `convertor_version`. |
| `{name}_summary.txt` | —                   | GUI conversions only: Result tab + `run with` + report + restorable `[data]` settings. |

`{name}_preview.png`, `{name}_palettes.png`, and `{name}_report.txt` are references for inspection
and are not part of the data the hardware consumes.

### The report — `_report.txt` and `.nfo`

`{name}_report.txt` is a plain-text summary of the conversion in a **fixed
80-column layout** — every line is `Label : value`, wrapped continuation lines
align under the value, and no line exceeds 80 characters. The first line is the
banner
`===============================palettize_4 report===============================`,
and each field is identified by the label before the `:`.

`{name}.nfo` is the **same report** re-encoded as the byte image of the Atari
viewer's 80-column VBXE text screen, so the viewer can blit it straight to the
display with no parsing. It is a run of fixed **160-byte line records**: 80
`{glyph, attr}` cell pairs, `glyph` = the ASCII byte, `attr` = `$07` (bright
white, transparent background), space-padded, **no line terminators**. One
final all-`$00` record marks end-of-text. This layout is a contract with
`Viewer/view1024.asm` (`NFO_BUF_VRAM`, `BLT_NFO_DRAW`); a report line longer
than 80 chars (usually a long `Input` filename) is clipped to 80 in the `.nfo`
— `_report.txt` keeps the full line.

| Field | Meaning |
|-------|---------|
| `Input` | Source image filename (basename only). |
| `Description` | The text the viewer's selector status line shows for this image (`--description`, else the input filename without its extension); wrapped onto a continuation line past 57 characters so the `.nfo` never clips it. |
| `Dimensions` | Pixel size of the **source file**, before any resample. |
| `Resampled` | Working size the packer ran at, the filter, and the fit mode — or `none (native WxH)` when `--resize` was not used. |
| `Cell width` | `cell_w` px per attribute cell, and the resulting cell grid (`cells/line × lines`). |
| `Palettes x slots` | Palette count × slots each, and the usable slots per palette (255 when slot 0 is reserved transparent). |
| `Pre-quantized` | Distinct colours in the source file. `-> reduced to N` is appended only when that count exceeds the master budget, i.e. a genuine pre-quantisation happened (resampling a small-palette source can still push the *working* image over budget without this note). |
| `Master colours` | Colours going into the packer after any pre-quantisation — the pool it distributes across the four palettes. |
| `Output colours` | Distinct RGB values actually visible in the packed result. `Output < Master` means colours were merged away to cross-palette duplication (see [Maximizing colour count](#maximizing-colour-count)). |
| `Convertor Version` | The release (`palgui/__init__.py` `__version__`) of the converter that wrote the file. |
| `Strategy` | `lossless`, or `fidelity (bias b)` / `balanced (bias b)` for Phase B (see [`--color-bias`](#maximizing-colour-count)). |
| `RESULT: LOSSLESS / LOSSY` | Whether any pixel had to be recoloured. |
| `recoloured pixels` / `mean OKLab error` | (LOSSY only) How many pixels were substituted and the mean perceptual error over *just those* pixels. |
| `Accuracy vs the ideal` block | What the 8-pixel cell rule cost, measured against the same image quantised to the same colours with **no** cell restriction — see [Maximizing colour count](#maximizing-colour-count). `not measured in this conversion` on reports migrated from the older `_report.txt` format. |
| `Per-palette colours` | `P0: n P1: n P2: n P3: n / cap colours` — per palette, how many of its colours appear in **no other** palette; `cap` is the usable slots per palette (255 or 256). The following `duplicated across palettes` line gives the total distinct colours across all four and how many palette entries are duplicates. |

### `IMAGES.LST` — descriptions for the viewer's selector

`gather_v1k.py ROOT OUTDIR` (also the GUI's **File ▸ Gather images for Atari**)
copies every `.v1k` + `.nfo` under `ROOT` into one staging folder with legal
8-char names and writes that folder's `images.lst` — one `$9B`-terminated
record of an 8-byte base-name key plus the image's **description**: the
`_stats.json` `description`, else the `.nfo` `Description` row, else the
`Input` filename minus its extension. Copy the folder to the disk and the
viewer shows it on the selector status line. (The separate *Build images.lst*
step is gone: a manifest built apart from the copy could name files the disk
does not hold.)

### Scripting / batch use
For driving the converter from a GUI or batch script, use `--quiet` to silence the
text report and read `{name}_stats.json` (always written) for results, or use
`--json` to print the same stats object to stdout. Keys include `output_colours`,
`master_colours`, `source_colours`, `source_width`, `source_height`,
`recoloured_pixels`, `recoloured_pct`, `mean_oklab_error`, `components`,
`largest_component`, `strategy`, `color_bias`, `coherence`,
`duplicated_across_palettes`, `lossless`, `per_palette`, `description`,
`convertor_version`, `args` (every option the run was given, so it can be
repeated exactly), and a `files` map of every output filename produced.

`ideal_vs_output` is a nested object holding the accuracy block described
above: `compared_pixels`, `identical_pixels`, `identical_pct`, `rgb_rmse`,
`psnr_db`, `mean_oklab_error`, `max_oklab_error`, `cells_compared`,
`cells_damaged`, `cells_damaged_pct` and `seam_index`. It is nested rather than
flattened because `mean_oklab_error` already exists at the top level meaning
something narrower (recoloured pixels only). `psnr_db` is `null` — not
`Infinity`, which is not valid JSON — when the output is identical to the
ideal, and `seam_index` is `null` for an image with no column detail to
measure. `identical_pixels + recoloured_pixels == compared_pixels` always
holds, because a pixel whose colour was not substituted is reproduced exactly.

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

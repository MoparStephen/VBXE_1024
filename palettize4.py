#!/usr/bin/env python3
"""
palettize4.py
=============
Pack a high-colour image into 4 palettes of 256 entries each, where the
palette in use can be switched per 8-pixel cell (a "colour attribute map").

Model
-----
  * Atomic unit = one CELL = `cell_w` consecutive pixels on a scanline.
  * Every pixel in a cell resolves through the SAME palette, so every colour
    in a cell must coexist in one palette (<= 256 colours per palette).
  * Two colours that ever share a cell are forced into the same palette.
    -> build the colour co-occurrence graph; its connected components are
       indivisible groups.

Strategy
--------
  Phase A (lossless): if the components pack into 4 bins of <=256, assign each
  component to a bin. Zero error, zero duplication.

  Phase B (lossy fallback): if some component is too big or packing fails,
  drop to cell-level assignment seeded by k-means in OKLab, greedily place
  each cell into the palette that adds the fewest new colours, then resolve
  any over-full palette by substituting its rarest colours with their nearest
  perceptual neighbour. Error is reported.

Outputs (into --out dir)
------------------------
  image.raw      width * height bytes (8-bit pixel index, row-major)
  palette0.pal   256 entries * (R,G,B) = 768 bytes  (one file per palette)
  palette1.pal     ...
  palette2.pal
  palette3.pal
  attrib.map     one byte per cell (palette id 0-3), sequential row-major
  preview.png    reconstruction as the hardware would show it
  palettes.png   swatch sheet of the palettes
  report.txt     statistics and any quality warnings
"""

import argparse, os, sys
import numpy as np
from PIL import Image


# ----------------------------------------------------------------------------
# colour space: sRGB -> OKLab (perceptual, for k-means + nearest-neighbour)
# ----------------------------------------------------------------------------
def srgb_to_linear(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)

def rgb_to_oklab(rgb):
    rgb = srgb_to_linear(rgb.astype(np.float64))
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = np.cbrt(l), np.cbrt(m), np.cbrt(s)
    L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    return np.stack([L, A, B], axis=-1)


# ----------------------------------------------------------------------------
# union-find for connected components of the co-occurrence graph
# ----------------------------------------------------------------------------
class DSU:
    def __init__(self, n):
        self.p = list(range(n)); self.r = [0] * n
    def find(self, x):
        while self.p[x] != x:
            self.p[x] = self.p[self.p[x]]; x = self.p[x]
        return x
    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra == rb: return
        if self.r[ra] < self.r[rb]: ra, rb = rb, ra
        self.p[rb] = ra
        if self.r[ra] == self.r[rb]: self.r[ra] += 1


# ----------------------------------------------------------------------------
def kmeans(X, k, iters=40, seed=0):
    """tiny k-means++ (X is small: <= ~4096 colours)."""
    rng = np.random.default_rng(seed)
    n = len(X)
    if n <= k:
        return np.arange(n) % k, X.copy()
    idx = [int(rng.integers(n))]
    d2 = ((X - X[idx[0]]) ** 2).sum(1)
    for _ in range(1, k):
        p = d2 / d2.sum()
        j = int(rng.choice(n, p=p)); idx.append(j)
        d2 = np.minimum(d2, ((X - X[j]) ** 2).sum(1))
    C = X[idx].copy()
    lab = np.zeros(n, dtype=np.int32)
    for _ in range(iters):
        dist = ((X[:, None, :] - C[None, :, :]) ** 2).sum(2)
        lab = dist.argmin(1)
        for j in range(k):
            mask = lab == j
            if mask.any(): C[j] = X[mask].mean(0)
    return lab, C


# ----------------------------------------------------------------------------
def median_cut(colors, counts, target):
    """Weighted median-cut down to `target` representative colours.
    Returns (palette[target,3] uint8, mapping[len(colors)] -> palette idx)."""
    colors_i = colors.astype(np.int64)

    def make_box(idx):
        c = colors_i[idx]
        ext = c.max(0) - c.min(0)
        ax = int(ext.argmax())
        return [idx, int(ext[ax]), ax]

    boxes = [make_box(np.arange(len(colors)))]
    while len(boxes) < target:
        best = max(range(len(boxes)),
                   key=lambda i: boxes[i][1] if len(boxes[i][0]) > 1 else -1)
        if len(boxes[best][0]) < 2:
            break
        idx, _, ax = boxes.pop(best)
        order = np.argsort(colors_i[idx][:, ax], kind="stable")
        idx = idx[order]
        cum = np.cumsum(counts[idx])
        split = int(np.searchsorted(cum, cum[-1] / 2.0))
        split = max(1, min(len(idx) - 1, split))
        boxes.append(make_box(idx[:split]))
        boxes.append(make_box(idx[split:]))

    pal = np.zeros((len(boxes), 3), np.uint8)
    mapping = np.zeros(len(colors), np.int64)
    for bi, (idx, _, _) in enumerate(boxes):
        w = counts[idx]
        rep = np.round((colors_i[idx] * w[:, None]).sum(0) / w.sum())
        pal[bi] = rep.astype(np.uint8)
        mapping[idx] = bi
    return pal, mapping


# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Pack an image into 4x256 palettes with 8-pixel cell overrides.")
    ap.add_argument("input", help="input image (PNG/anything PIL reads)")
    ap.add_argument("--out", default="out", help="output directory")
    ap.add_argument("--cell", type=int, default=8, help="pixels per palette-override cell (default 8)")
    ap.add_argument("--palettes", type=int, default=4, help="number of palettes (default 4)")
    ap.add_argument("--slots", type=int, default=256, help="entries per palette (default 256)")
    ap.add_argument("--reserve0", action="store_true", help="reserve slot 0 (e.g. transparent) -> 255 usable")
    ap.add_argument("--colors", type=int, default=0, help="pre-quantize source to this many colours (0 = auto = palettes*cap)")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    NP = args.palettes
    cap = args.slots - (1 if args.reserve0 else 0)
    start_slot = 1 if args.reserve0 else 0
    cell_w = args.cell
    os.makedirs(args.out, exist_ok=True)

    # ---- load + extract master colours -------------------------------------
    img = Image.open(args.input).convert("RGB")
    target = args.colors if args.colors > 0 else NP * cap
    # count uniques first
    arr = np.asarray(img)
    H, W, _ = arr.shape
    uniq, inv0, ucounts = np.unique(arr.reshape(-1, 3), axis=0,
                                    return_inverse=True, return_counts=True)
    inv0 = inv0.reshape(-1)
    prequant = False
    if len(uniq) > NP * cap:
        prequant = True
        tgt = min(target, NP * cap)
        pal, mapping = median_cut(uniq, ucounts, tgt)
        arr = pal[mapping[inv0]].reshape(H, W, 3)

    flat = arr.reshape(-1, 3)
    colors, inv = np.unique(flat, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    pix = inv.reshape(H, W)              # colour id per pixel
    N = len(colors)
    colors_lab = rgb_to_oklab(colors)
    color_count = np.bincount(inv, minlength=N)

    cells_per_line = (W + cell_w - 1) // cell_w

    # ---- precompute per-cell unique colours + build co-occurrence ----------
    dsu = DSU(N)
    cells = []   # (y, cx, unique_color_ids ndarray)
    for y in range(H):
        row = pix[y]
        for cx in range(cells_per_line):
            seg = row[cx * cell_w: (cx + 1) * cell_w]
            u = np.unique(seg)
            cells.append((y, cx, u))
            if len(u) > 1:
                f = int(u[0])
                for c in u[1:]:
                    dsu.union(f, int(c))

    # ---- connected components ----------------------------------------------
    root = np.array([dsu.find(i) for i in range(N)])
    roots = np.unique(root)
    r2c = {int(r): i for i, r in enumerate(roots)}
    comp_of = np.array([r2c[int(r)] for r in root])
    ncomp = len(roots)
    comp_size = np.zeros(ncomp, dtype=np.int64)
    for ci in range(N):
        comp_size[comp_of[ci]] += 1
    max_comp = int(comp_size.max())

    cell_pal = np.full((H, cells_per_line), -1, dtype=np.int16)
    remaps = [np.arange(N) for _ in range(NP)]   # per-palette colour substitution
    final_colors = [set() for _ in range(NP)]
    lossless = False
    sub_pixels = 0
    sub_err_sum = 0.0

    # ---- Phase A: pack components into NP bins of `cap` (best-fit decr.) ----
    if max_comp <= cap:
        order = sorted(range(ncomp), key=lambda i: -comp_size[i])
        binsize = [0] * NP
        comp_bin = [-1] * ncomp
        ok = True
        for ci in order:
            fits = [b for b in range(NP) if binsize[b] + comp_size[ci] <= cap]
            if not fits:
                ok = False; break
            b = max(fits, key=lambda b: binsize[b])   # best-fit (tightest)
            comp_bin[ci] = b; binsize[b] += comp_size[ci]
        if ok:
            lossless = True
            for cid in range(N):
                final_colors[comp_bin[comp_of[cid]]].add(cid)
            for (y, cx, u) in cells:
                if len(u):
                    cell_pal[y, cx] = comp_bin[comp_of[int(u[0])]]
                else:
                    cell_pal[y, cx] = 0

    # ---- Phase B: cell-level greedy + substitution -------------------------
    if not lossless:
        lab, _ = kmeans(colors_lab, NP, seed=args.seed)
        palette = [set() for _ in range(NP)]
        binsize = [0] * NP
        cidx = sorted(range(len(cells)), key=lambda i: -len(cells[i][2]))
        for i in cidx:
            y, cx, u = cells[i]
            if len(u) == 0:
                cell_pal[y, cx] = 0; continue
            # dominant k-means cluster of this cell (pixel-weighted)
            pref = int(np.bincount(lab[u], weights=color_count[u],
                                   minlength=NP).argmax())
            adds = [sum(1 for c in u if int(c) not in palette[b]) for b in range(NP)]
            room = [b for b in range(NP) if binsize[b] + adds[b] <= cap]
            cand = room if room else list(range(NP))
            b = min(cand, key=lambda b: (adds[b], 0 if b == pref else 1, binsize[b]))
            for c in u:
                if int(c) not in palette[b]:
                    palette[b].add(int(c)); binsize[b] += 1
            cell_pal[y, cx] = b

        # palette membership per pixel (expand cells across width)
        pal_pp = np.repeat(cell_pal, cell_w, axis=1)[:, :W]

        # resolve over-capacity palettes by substitution
        for b in range(NP):
            mask = pal_pp == b
            cc = np.bincount(pix[mask].ravel(), minlength=N)
            used = np.nonzero(cc)[0]
            if len(used) <= cap:
                final_colors[b] = set(int(c) for c in used)
                continue
            # keep the `cap` most frequent colours in this palette
            keep = used[np.argsort(cc[used])[::-1][:cap]]
            drop = np.setdiff1d(used, keep, assume_unique=False)
            keep_lab = colors_lab[keep]
            for c in drop:
                d = ((keep_lab - colors_lab[c]) ** 2).sum(1)
                nn = int(keep[d.argmin()])
                remaps[b][c] = nn
                sub_pixels += int(cc[c])
                sub_err_sum += float(np.sqrt(d.min())) * int(cc[c])
            final_colors[b] = set(int(c) for c in keep)

    # ---- build palette RAM + slot lookup -----------------------------------
    pal_rgb = np.zeros((NP, args.slots, 3), dtype=np.uint8)
    slot_of = np.full((NP, N), 0, dtype=np.int32)
    for b in range(NP):
        kept = sorted(final_colors[b])
        for k, c in enumerate(kept):
            slot = start_slot + k
            slot_of[b, c] = slot
            pal_rgb[b, slot] = colors[c]

    # ---- emit indices + reconstruction -------------------------------------
    pal_pp = np.repeat(cell_pal, cell_w, axis=1)[:, :W]
    out_idx = np.zeros((H, W), dtype=np.uint8)
    out_rgb = np.zeros((H, W, 3), dtype=np.uint8)
    for b in range(NP):
        mask = pal_pp == b
        cids = remaps[b][pix[mask]]
        out_idx[mask] = slot_of[b, cids]
        out_rgb[mask] = colors[cids]

    # ---- write files --------------------------------------------------------
    # image.raw : one byte per pixel, row-major
    out_idx.tofile(os.path.join(args.out, "image.raw"))
    # palette#.pal : 256 entries x (R,G,B) = 768 bytes each
    for b in range(NP):
        pal_rgb[b].astype(np.uint8).tofile(os.path.join(args.out, f"palette{b}.pal"))
    # attrib.map : one byte per cell (palette 0-3), sequential row-major over cells
    cell_pal.astype(np.uint8).tofile(os.path.join(args.out, "attrib.map"))
    # human-facing previews
    Image.fromarray(out_rgb, "RGB").save(os.path.join(args.out, "preview.png"))

    # palette swatch sheet
    sw = 12
    sheet = np.zeros((NP * sw, args.slots * sw, 3), dtype=np.uint8)
    for b in range(NP):
        for s in range(args.slots):
            sheet[b*sw:(b+1)*sw, s*sw:(s+1)*sw] = pal_rgb[b, s]
    Image.fromarray(sheet, "RGB").save(os.path.join(args.out, "palettes.png"))

    # ---- report -------------------------------------------------------------
    total_px = H * W
    lines = []
    lines.append("palettize4 report")
    lines.append("=" * 48)
    lines.append(f"input            : {args.input}")
    lines.append(f"dimensions       : {W} x {H}  ({total_px} px)")
    lines.append(f"cell width       : {cell_w} px  ->  {cells_per_line} cells/line, {cells_per_line*H} cells")
    lines.append(f"palettes x slots : {NP} x {args.slots}  (usable {cap}/palette"
                 + (", slot 0 reserved" if args.reserve0 else "") + ")")
    if prequant:
        lines.append(f"pre-quantized    : source exceeded {NP*cap} colours -> reduced to {N}")
    lines.append(f"master colours   : {N}")
    lines.append(f"components        : {ncomp}  (largest = {max_comp})")
    lines.append("")
    if lossless:
        lines.append("RESULT: LOSSLESS  - components packed into "
                     f"{NP} palettes with no colour loss.")
    else:
        pct = 100.0 * sub_pixels / total_px
        mean_err = (sub_err_sum / sub_pixels) if sub_pixels else 0.0
        lines.append("RESULT: LOSSY     - cells could not be partitioned cleanly.")
        lines.append(f"  substituted pixels : {sub_pixels} ({pct:.3f}% of image)")
        lines.append(f"  mean OKLab error   : {mean_err:.4f}  (on substituted pixels only)")
        if max_comp > cap:
            lines.append(f"  note: a single component needs {max_comp} colours (> {cap}); "
                         "duplication/substitution was unavoidable.")
    lines.append("")
    lines.append("per-palette colour usage:")
    for b in range(NP):
        lines.append(f"  palette {b}: {len(final_colors[b]):4d} / {cap} colours")
    report = "\n".join(lines)
    with open(os.path.join(args.out, "report.txt"), "w") as f:
        f.write(report + "\n")
    print(report)


if __name__ == "__main__":
    main()

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
  attrib.map     one byte per cell, palette id (0-3) * 16 -> 0,16,32,48; row-major
  preview.png    reconstruction as the hardware would show it
  palettes.png   swatch sheet of the palettes
  report.txt     statistics and any quality warnings
"""

import argparse, os, sys
import numpy as np
from PIL import Image

# resampling filters (robust across Pillow versions)
_R = getattr(Image, "Resampling", Image)
FILTERS = {
    "nearest":  _R.NEAREST,   # pixel art / indexed art: no blending, no new colours
    "box":      _R.BOX,       # pure area-average; good for clean downscales
    "bilinear": _R.BILINEAR,
    "hamming":  _R.HAMMING,
    "bicubic":  _R.BICUBIC,
    "lanczos":  _R.LANCZOS,   # best general photo downscale
}

def _parse_wh(s):
    w, h = s.lower().split("x")
    return int(w), int(h)

def _parse_aspect(s):
    if ":" in s:
        a, b = s.split(":"); return float(a) / float(b)
    return float(s)

def _parse_rgb(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))

def resize_image(img, target_wh, flt_name, fit, display_aspect):
    """Resample img to target W,H. Returns (image, pad_mask) where pad_mask is a
    HxW bool array (True = letterbox/pillarbox padding -> index 0/transparent),
    or None when nothing is padded.
       stretch -> straight resample to WxH (correct for a 4:3 square-pixel master)
       cover   -> crop source to the on-screen aspect, then resample (fills frame)
       fit     -> resample source into a centred box, pad the rest (letterbox)
    cover/fit use `display_aspect` (the TRUE on-screen aspect, default 4:3) so that
    non-square-pixel modes like 160-wide come out correctly proportioned."""
    tw, th = target_wh
    flt = FILTERS[flt_name]
    if fit == "stretch":
        return img.resize((tw, th), flt), None

    dar = _parse_aspect(display_aspect)
    sw, sh = img.size
    src_ar = sw / sh
    if fit == "cover":
        if src_ar > dar:                       # source too wide -> crop sides
            nw = int(round(sh * dar)); x0 = (sw - nw) // 2
            img = img.crop((x0, 0, x0 + nw, sh))
        else:                                  # source too tall -> crop top/bottom
            nh = int(round(sw / dar)); y0 = (sh - nh) // 2
            img = img.crop((0, y0, sw, y0 + nh))
        return img.resize((tw, th), flt), None

    # fit (letterbox / pillarbox), computed directly in target-grid space.
    # PAR = on-screen pixel width/height; the source (square-pixel aspect src_ar)
    # must occupy a target rectangle gw x gh with (gw*PAR)/gh == src_ar.
    par = dar * th / tw
    gw = tw
    gh = int(round(gw * par / src_ar))
    if gh > th:                                # too tall -> fit by height instead
        gh = th
        gw = int(round(gh * src_ar / par))
    gw = max(1, min(tw, gw)); gh = max(1, min(th, gh))
    inner = img.resize((gw, gh), flt)
    canvas = Image.new("RGB", (tw, th), (0, 0, 0))
    ox, oy = (tw - gw) // 2, (th - gh) // 2
    canvas.paste(inner, (ox, oy))
    mask = np.ones((th, tw), dtype=bool)       # True = padding
    mask[oy:oy + gh, ox:ox + gw] = False
    return canvas, mask



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
    ap.add_argument("--reserve0", action=argparse.BooleanOptionalAction, default=True,
                    help="reserve slot 0 as transparent in every palette -> 255 usable (on by default; use --no-reserve0 to disable)")
    ap.add_argument("--colors", type=int, default=0, help="pre-quantize source to this many colours (0 = auto = palettes*cap)")
    ap.add_argument("--resize", default=None, metavar="WxH",
                    help="resample to WxH before packing, e.g. 320x240 or 160x240")
    ap.add_argument("--filter", default="lanczos", choices=list(FILTERS),
                    help="resampling filter (default lanczos; use 'nearest' for pixel art)")
    ap.add_argument("--fit", default="stretch", choices=["stretch", "cover", "fit"],
                    help="aspect handling when source AR != display AR (default stretch); 'fit' letterboxes with transparent index 0")
    ap.add_argument("--display-aspect", default="4:3", metavar="R",
                    help="true on-screen aspect for cover/fit (default 4:3; handles non-square pixels e.g. 160-wide modes)")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    NP = args.palettes
    cap = args.slots - (1 if args.reserve0 else 0)
    start_slot = 1 if args.reserve0 else 0
    cell_w = args.cell
    os.makedirs(args.out, exist_ok=True)

    # ---- load (+ optional resample) + extract master colours --------------
    img = Image.open(args.input).convert("RGB")
    pad_mask = None
    if args.resize:
        img, pad_mask = resize_image(img, _parse_wh(args.resize), args.filter,
                                     args.fit, args.display_aspect)
    target = args.colors if args.colors > 0 else NP * cap
    # count uniques first
    arr = np.asarray(img)
    H, W, _ = arr.shape
    # transparent (letterbox/pillarbox) pixels -> always index 0
    transparent = pad_mask if pad_mask is not None else np.zeros((H, W), dtype=bool)
    tflat = transparent.reshape(-1)
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
    color_count = np.bincount(inv[~tflat], minlength=N)   # ignore transparent

    cells_per_line = (W + cell_w - 1) // cell_w

    # ---- precompute per-cell unique colours + build co-occurrence ----------
    # transparent pixels contribute no colour to a cell (they become index 0)
    dsu = DSU(N)
    cells = []   # (y, cx, unique_color_ids ndarray)
    for y in range(H):
        row = pix[y]
        trow = transparent[y]
        for cx in range(cells_per_line):
            a, b = cx * cell_w, (cx + 1) * cell_w
            seg = row[a:b][~trow[a:b]]
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

        # resolve over-capacity palettes by substitution (ignore transparent px)
        for b in range(NP):
            mask = (pal_pp == b) & (~transparent)
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
    out_idx = np.zeros((H, W), dtype=np.uint8)   # transparent pixels stay 0
    out_rgb = np.zeros((H, W, 3), dtype=np.uint8)
    for b in range(NP):
        mask = (pal_pp == b) & (~transparent)
        cids = remaps[b][pix[mask]]
        out_idx[mask] = slot_of[b, cids]
        out_rgb[mask] = colors[cids]
    # transparent (letterbox) pixels: index 0, shown as palette slot 0 (black)
    out_idx[transparent] = 0
    out_rgb[transparent] = pal_rgb[0, 0]

    # ---- write files --------------------------------------------------------
    # image.raw : one byte per pixel, row-major
    out_idx.tofile(os.path.join(args.out, "image.raw"))
    # palette#.pal : 256 entries x (R,G,B) = 768 bytes each
    for b in range(NP):
        pal_rgb[b].astype(np.uint8).tofile(os.path.join(args.out, f"palette{b}.pal"))
    # attrib.map : one byte per cell, palette id (0-3) << 4  ->  0,16,32,48
    (cell_pal * 16).astype(np.uint8).tofile(os.path.join(args.out, "attrib.map"))
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
    unique_out = len(np.unique(out_rgb.reshape(-1, 3), axis=0))
    lines = []
    lines.append("palettize4 report")
    lines.append("=" * 48)
    lines.append(f"input            : {args.input}")
    lines.append(f"dimensions       : {W} x {H}  ({total_px} px)")
    if args.resize:
        lines.append(f"resampled        : -> {args.resize} via {args.filter} (fit={args.fit}"
                     + (f", display-aspect={args.display_aspect}" if args.fit != "stretch" else "") + ")")
    lines.append(f"cell width       : {cell_w} px  ->  {cells_per_line} cells/line, {cells_per_line*H} cells")
    lines.append(f"palettes x slots : {NP} x {args.slots}  (usable {cap}/palette"
                 + (", slot 0 = transparent" if args.reserve0 else "") + ")")
    if int(transparent.sum()):
        lines.append(f"transparent px   : {int(transparent.sum())} letterbox/pillarbox -> index 0")
    if prequant:
        lines.append(f"pre-quantized    : source exceeded {NP*cap} colours -> reduced to {N}")
    lines.append(f"master colours   : {N}")
    lines.append(f"output colours   : {unique_out}  (distinct RGB on screen)")
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
    # how many palettes each colour appears in (to find entries unique to one)
    pal_count = np.zeros(N, dtype=np.int32)
    for b in range(NP):
        for c in final_colors[b]:
            pal_count[c] += 1
    all_pal_colors = set().union(*final_colors) if NP else set()
    total_entries = sum(len(final_colors[b]) for b in range(NP))
    duplicated = total_entries - len(all_pal_colors)
    lines.append("per-palette colour usage:")
    for b in range(NP):
        uniq_b = sum(1 for c in final_colors[b] if pal_count[c] == 1)
        lines.append(f"  palette {b}: {len(final_colors[b]):4d} / {cap} colours"
                     f"  ({uniq_b:4d} unique to this palette)")
    lines.append(f"  duplicated across palettes: {duplicated} "
                 f"entr{'y' if duplicated == 1 else 'ies'} "
                 f"({len(all_pal_colors)} distinct colours in all palettes)")
    report = "\n".join(lines)
    with open(os.path.join(args.out, "report.txt"), "w") as f:
        f.write(report + "\n")
    print(report)


if __name__ == "__main__":
    main()

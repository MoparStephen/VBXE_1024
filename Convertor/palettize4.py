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

Outputs (into --out dir; {name} defaults to the input filename without extension,
or --name)
------------------------
  {name}.raw     width * height bytes (8-bit pixel index, row-major)
  {name}0.pal    256 entries * (R,G,B) = 768 bytes  (one file per palette)
  {name}1.pal      ...
  {name}2.pal
  {name}3.pal
  {name}.pal     all palettes concatenated, palette-major (NP*256*3 bytes)
  {name}.map     one byte per cell, palette id (0-3) * 16 -> 0,16,32,48; row-major
  {name}_preview.png   reconstruction as the hardware would show it
  {name}_palettes.png  swatch sheet of the palettes
  {name}_report.txt    statistics and any quality warnings (human-readable, fixed 80-col layout)
  {name}.nfo           the same report as the Atari viewer's "About" screen eats it:
                       fixed 160-byte line records of 80 {glyph,attr} cell pairs
                       (attr $07), no terminators, one all-$00 record marks the end
"""

import argparse, os, sys, json
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
# error-diffusion dithering kernels: (dx, dy, weight) with weights summing to 1
DITHER_KERNELS = {
    "floyd":    [(1, 0, 7/16), (-1, 1, 3/16), (0, 1, 5/16), (1, 1, 1/16)],
    "jjn":      [(1, 0, 7/48), (2, 0, 5/48),
                 (-2, 1, 3/48), (-1, 1, 5/48), (0, 1, 7/48), (1, 1, 5/48), (2, 1, 3/48),
                 (-2, 2, 1/48), (-1, 2, 3/48), (0, 2, 5/48), (1, 2, 3/48), (2, 2, 1/48)],
    "stucki":   [(1, 0, 8/42), (2, 0, 4/42),
                 (-2, 1, 2/42), (-1, 1, 4/42), (0, 1, 8/42), (1, 1, 4/42), (2, 1, 2/42),
                 (-2, 2, 1/42), (-1, 2, 2/42), (0, 2, 4/42), (1, 2, 2/42), (2, 2, 1/42)],
    "atkinson": [(1, 0, 1/8), (2, 0, 1/8), (-1, 1, 1/8), (0, 1, 1/8), (1, 1, 1/8), (0, 2, 1/8)],
    "sierra":   [(1, 0, 5/32), (2, 0, 3/32),
                 (-2, 1, 2/32), (-1, 1, 4/32), (0, 1, 5/32), (1, 1, 4/32), (2, 1, 2/32),
                 (-1, 2, 2/32), (0, 2, 3/32), (1, 2, 2/32)],
    "burkes":   [(1, 0, 8/32), (2, 0, 4/32),
                 (-2, 1, 2/32), (-1, 1, 4/32), (0, 1, 8/32), (1, 1, 4/32), (2, 1, 2/32)],
}

# Diagonal slope for the wavefront in dither_to_palette: pixels are walked in
# order of k = x + _WAVEFRONT_C*y.  Valid only while every kernel entry
# satisfies dx + C*dy > 0 (see the comment there), so that is checked here
# rather than assumed - a seventh kernel with a wider left reach would need a
# larger C, and would otherwise read neighbours that had not been written yet.
_WAVEFRONT_C = 3
assert all(dx + _WAVEFRONT_C * dy > 0
           for _k in DITHER_KERNELS.values() for dx, dy, _w in _k), \
    "a dither kernel reaches further left than _WAVEFRONT_C allows"

def _bayer(n):
    if n == 1:
        return np.zeros((1, 1))
    m = _bayer(n // 2)
    return np.block([[4 * m, 4 * m + 2], [4 * m + 3, 4 * m + 1]])

def _bayer_threshold(n):
    return (_bayer(n) + 0.5) / (n * n) - 0.5          # in [-0.5, 0.5)

_BLUE_CACHE = {}
def _blue_threshold(size=64):
    """Tileable blue-noise threshold mask via void-and-cluster (cached on disk)."""
    if size in _BLUE_CACHE:
        return _BLUE_CACHE[size]
    import tempfile
    path = os.path.join(tempfile.gettempdir(), f"palettize4_blue{size}.npy")
    if os.path.exists(path):
        m = np.load(path); _BLUE_CACHE[size] = m; return m
    from scipy.ndimage import gaussian_filter
    rng = np.random.default_rng(0); n = size * size
    pat = np.zeros((size, size), bool)
    pat.flat[rng.choice(n, n // 10, replace=False)] = True
    filt = lambda p: gaussian_filter(p.astype(float), 1.5, mode="wrap")
    while True:
        e = filt(pat); e[~pat] = -1
        cy, cx = np.unravel_index(e.argmax(), e.shape); pat[cy, cx] = False
        e = filt(pat); e[pat] = 1e9
        vy, vx = np.unravel_index(e.argmin(), e.shape); pat[vy, vx] = True
        if (cy, cx) == (vy, vx):
            break
    rank = np.zeros((size, size), int); ones = int(pat.sum())
    work = pat.copy()
    for r in range(ones - 1, -1, -1):
        e = filt(work); e[~work] = -1
        y, x = np.unravel_index(e.argmax(), e.shape); work[y, x] = False; rank[y, x] = r
    work = pat.copy()
    for r in range(ones, n):
        e = filt(work); e[work] = 1e9
        y, x = np.unravel_index(e.argmin(), e.shape); work[y, x] = True; rank[y, x] = r
    m = (rank + 0.5) / n - 0.5
    try: np.save(path, m)
    except OSError: pass
    _BLUE_CACHE[size] = m
    return m

ORDERED = {"bayer2": lambda: _bayer_threshold(2), "bayer4": lambda: _bayer_threshold(4),
           "bayer8": lambda: _bayer_threshold(8), "blue": lambda: _blue_threshold(64)}

def dither_to_palette(arr, pal, algo, strength=1.0):
    """Quantize arr (HxWx3 uint8) to the colours in `pal`, dithering to break
    gradient banding. Error-diffusion kernels (floyd/atkinson/...) spread each
    pixel's error to neighbours; ordered masks (bayer*/blue) perturb each pixel by
    a fixed threshold pattern. Requires scipy for nearest-colour lookup."""
    try:
        from scipy.spatial import cKDTree
    except ImportError:
        sys.exit("--dither needs scipy: pip install scipy")
    tree = cKDTree(pal.astype(np.float64))
    H, W, _ = arr.shape
    if algo in ORDERED:                                # ordered / blue-noise
        mask = ORDERED[algo]()
        mh, mw = mask.shape
        gap = tree.query(pal.astype(np.float64), k=2)[0][:, 1].mean()  # palette spacing
        amp = gap * 1.5 * strength
        ty, tx = np.indices((H, W))
        pert = arr.astype(np.float64) + (mask[ty % mh, tx % mw] * amp)[..., None]
        j = tree.query(pert.reshape(-1, 3))[1]
        return pal[j].reshape(H, W, 3).astype(np.uint8)
    # ---- error diffusion, one anti-diagonal at a time ----------------------
    # ERROR DIFFUSION IS SEQUENTIAL BUT NOT AS SEQUENTIAL AS IT LOOKS.  Pixel
    # (y,x) reads from (y-dy, x-dx) for each kernel entry, so numbering the
    # diagonals k = x + C*y puts that source on k - (dx + C*dy).  When
    # dx + C*dy > 0 for EVERY entry of every kernel, every dependency lies on a
    # strictly earlier diagonal - which makes the pixels WITHIN one diagonal
    # independent of each other, and the whole diagonal one vectorized step.
    # The worst entry across the six kernels is (dx=-2, dy=1), so C=3 does it;
    # _WAVEFRONT_C is asserted against the kernels at import rather than
    # trusted.
    #
    # This replaced a per-pixel Python loop that ran one cKDTree.query() per
    # pixel: ~15x faster (800x600 floyd, 6.8s -> 0.4s) for byte-identical
    # output.  Identical is not a hope - the diagonals impose the same read
    # ordering the scan did, and tests/test_palgui.py TestDither checks it
    # against a straight serial implementation on every kernel.
    kernel = DITHER_KERNELS[algo]
    work = arr.astype(np.float64)
    out = np.empty((H, W), np.int64)
    C = _WAVEFRONT_C
    for k in range((W - 1) + C * (H - 1) + 1):
        # The pixels on diagonal k, derived rather than searched for: x = k-C*y
        # bounded by the image.  (An argsort over every pixel would do the same
        # job and cost three more full-size arrays on a big source.)
        y0 = max(0, -(-(k - W + 1) // C))               # ceil((k-W+1)/C)
        y1 = min(H - 1, k // C)
        if y0 > y1:
            continue
        ys = np.arange(y0, y1 + 1)
        xs = k - C * ys
        old = work[ys, xs]
        j = tree.query(old)[1]                          # one batched query
        out[ys, xs] = j
        err = (old - pal[j]) * strength
        for dx, dy, wt in kernel:
            yy, xx = ys + dy, xs + dx
            m = (xx >= 0) & (xx < W) & (yy >= 0) & (yy < H)
            # Distinct sources on one diagonal map to distinct targets for a
            # given kernel entry, so a plain += is safe here; np.add.at would
            # be correct too and several times slower.
            work[yy[m], xx[m]] += err[m] * wt
    return pal[out].astype(np.uint8)


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


def reduce_duplication(cell_pal, cells, NP, cap, max_passes=16):
    """Local search that moves whole cells between palettes to cut cross-palette
    duplication (each colour copied into fewer palettes -> more distinct colours
    survive). Hypergraph-partitioning style: a colour is a hyperedge over the
    cells that use it; we shrink the number of palettes each hyperedge spans.
    Never lets a palette exceed `cap` distinct colours. Mutates cell_pal."""
    cnt = [dict() for _ in range(NP)]            # palette -> {colour: #cells using it}
    for (y, cx, u) in cells:
        b = int(cell_pal[y, cx])
        for c in u:
            c = int(c); cnt[b][c] = cnt[b].get(c, 0) + 1
    for _ in range(max_passes):
        moved = 0
        for (y, cx, u) in cells:
            if len(u) == 0:
                continue
            p = int(cell_pal[y, cx])
            uu = [int(c) for c in u]
            leave_p = sum(1 for c in uu if cnt[p].get(c, 0) == 1)   # colours freed from p
            best_gain, best_q = 0, p
            for q in range(NP):
                if q == p:
                    continue
                enter = sum(1 for c in uu if c not in cnt[q])       # new colours into q
                if len(cnt[q]) + enter > cap:
                    continue
                gain = leave_p - enter
                if gain > best_gain:
                    best_gain, best_q = gain, q
            if best_q != p:
                for c in uu:
                    cnt[p][c] -= 1
                    if cnt[p][c] == 0:
                        del cnt[p][c]
                    cnt[best_q][c] = cnt[best_q].get(c, 0) + 1
                cell_pal[y, cx] = best_q
                moved += 1
        if moved == 0:
            break
    return cell_pal


def balanced_cluster(colors_lab, NP, cap, seed=0):
    """Partition the N colours into NP clusters, each <= cap, by OKLab similarity.
    Returns home[N] giving each colour's single owning palette (-> zero cross-
    palette duplication)."""
    N = len(colors_lab)
    lab, C = kmeans(colors_lab, NP, seed=seed)
    D = ((colors_lab[:, None, :] - C[None, :, :]) ** 2).sum(2)   # N x NP
    pref = np.argsort(D, axis=1)                                  # nearest clusters
    # decisiveness = gap between nearest and 2nd-nearest centroid
    part = np.partition(D, 1, axis=1)
    gap = part[:, 1] - part[:, 0]
    counts = [0] * NP
    home = np.full(N, -1, dtype=np.int32)
    for i in np.argsort(-gap):            # place most-decisive colours first
        for q in pref[i]:
            if counts[q] < cap:
                home[i] = q; counts[q] += 1; break
    return home


def _column_jump(rgb, opaque, cell_w):
    """Mean colour jump between adjacent columns, split by cell boundary.

    Returns (at boundaries, everywhere else). Rows where either pixel of the
    pair is transparent are skipped, so letterbox bars -- perfectly flat and
    perfectly wide -- cannot dilute either average.
    """
    W = rgb.shape[1]
    pair = opaque[:, 1:] & opaque[:, :-1]
    g = np.abs(rgb[:, 1:] - rgb[:, :-1]).mean(2)      # H x (W-1)
    on, off = [], []
    for x in range(1, W):
        m = pair[:, x - 1]
        if not m.any():
            continue
        (on if x % cell_w == 0 else off).append(float(g[:, x - 1][m].mean()))
    return (float(np.mean(on)) if on else None,
            float(np.mean(off)) if off else None)


def compare_to_ideal(pix, out_cid, colors, colors_lab, transparent, cell_w):
    """The displayed image measured against the one the cell rule forbade.

    `pix` is the colour id every pixel WOULD have shown -- the source after
    resampling and after any pre-quantization to the colour target, but before
    a single cell/palette restriction. `out_cid` is the id actually displayed.
    The quantization loss is therefore baked into both sides and cancels, and
    what is left is exactly what the 8-pixel attribute cell cost.

    Transparent (letterbox) pixels are excluded from every count: they are
    padding rather than picture, and a letterboxed source would otherwise score
    better the wider its bars.

    RMSE AND PSNR CANNOT SEE BLOCKINESS. The same total error scattered as
    noise and collapsed into 8-pixel blocks scores identically, which is the
    whole reason the last two numbers exist. `cells_damaged` says how much of
    the picture sits inside a compromised block; `seam_index` says whether the
    grid has become VISIBLE, by asking how much harder the image jumps across a
    cell boundary than it does anywhere else -- and dividing by the same ratio
    measured on the ideal, so a source that genuinely has vertical edges on the
    8-pixel grid does not read as blocky when nothing went wrong.
    """
    H, W = pix.shape
    opaque = ~transparent
    n = int(opaque.sum())
    acc = {"compared_pixels": n, "identical_pixels": 0, "identical_pct": 0.0,
           "rgb_rmse": 0.0, "psnr_db": None,
           "mean_oklab_error": 0.0, "max_oklab_error": 0.0,
           "cells_compared": 0, "cells_damaged": 0, "cells_damaged_pct": 0.0,
           "seam_index": None}
    if n == 0:
        return acc

    same = (out_cid == pix) & opaque
    acc["identical_pixels"] = int(same.sum())
    acc["identical_pct"] = 100.0 * acc["identical_pixels"] / n

    ref_rgb = colors[pix].astype(np.float64)
    got_rgb = colors[out_cid].astype(np.float64)
    d = (ref_rgb - got_rgb)[opaque]
    mse = float((d * d).sum() / (3.0 * n))
    acc["rgb_rmse"] = float(np.sqrt(mse))
    # null rather than inf: json.dump writes a bare Infinity, which is not
    # valid JSON and would quietly poison anything else reading the sidecar.
    acc["psnr_db"] = (None if mse <= 0.0
                      else float(10.0 * np.log10(255.0 * 255.0 / mse)))

    dl = colors_lab[pix] - colors_lab[out_cid]
    dE = np.sqrt((dl * dl).sum(2))[opaque]
    acc["mean_oklab_error"] = float(dE.mean())
    acc["max_oklab_error"] = float(dE.max())

    # ---- blockiness: the cell is 8 px wide and ONE px tall, so the only seam
    # the hardware can create is a vertical one, at a column boundary.
    changed = same ^ opaque                      # opaque and not identical
    cells_per_line = (W + cell_w - 1) // cell_w
    live = damaged = 0
    for cx in range(cells_per_line):
        a, b = cx * cell_w, min((cx + 1) * cell_w, W)
        seg = opaque[:, a:b].any(1)
        live += int(seg.sum())
        damaged += int((changed[:, a:b].any(1) & seg).sum())
    acc["cells_compared"] = live
    acc["cells_damaged"] = damaged
    acc["cells_damaged_pct"] = (100.0 * damaged / live) if live else 0.0

    ref_on, ref_off = _column_jump(ref_rgb, opaque, cell_w)
    got_on, got_off = _column_jump(got_rgb, opaque, cell_w)
    if ref_on and ref_off and got_off:
        acc["seam_index"] = (got_on / got_off) / (ref_on / ref_off)
    return acc

# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Pack an image into 4x256 palettes with 8-pixel cell overrides.")
    ap.add_argument("input", help="input image (PNG/anything PIL reads)")
    ap.add_argument("--out", default="out", help="output directory")
    ap.add_argument("--name", default=None,
                    help="base name for the .map/.raw/.pal output files (default: input filename without extension)")
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
    ap.add_argument("--color-bias", type=float, default=0.0, metavar="0..1",
                    help="slider between fewest artifacts (0.0 = fidelity) and most colours (1.0). Intermediate values trade block artifacts for colour count smoothly.")
    ap.add_argument("--max-colors", action="store_true",
                    help="shorthand for --color-bias 1.0 (maximum distinct colours).")
    ap.add_argument("--optimize", action=argparse.BooleanOptionalAction, default=True,
                    help="reduce cross-palette duplication via local search so more colours survive (fidelity strategy; default on)")
    ap.add_argument("--coherence", type=float, default=1.5, metavar="L",
                    help="spatial smoothing of the attribute map (higher = neighbouring cells share a palette more, fewer block artifacts; 0 = off). Used by --color-bias > 0.")
    ap.add_argument("--dither", default="none",
                    choices=["none", "floyd", "atkinson", "jjn", "stucki", "sierra", "burkes",
                             "bayer2", "bayer4", "bayer8", "blue"],
                    help="dithering during colour reduction to break gradient banding. Error-diffusion: floyd atkinson jjn stucki sierra burkes. Ordered: bayer2 bayer4 bayer8 blue (default none)")
    ap.add_argument("--dither-strength", type=float, default=1.0, metavar="0..1",
                    help="fraction of quantization error to diffuse (default 1.0; lower = subtler dither)")
    ap.add_argument("--quiet", action="store_true", help="suppress the human-readable report on stdout (files still written)")
    ap.add_argument("--json", action="store_true", help="print machine-readable stats as JSON to stdout (implies --quiet for the text report)")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    NP = args.palettes
    cap = args.slots - (1 if args.reserve0 else 0)
    start_slot = 1 if args.reserve0 else 0
    cell_w = args.cell
    os.makedirs(args.out, exist_ok=True)

    # ---- load (+ optional resample) + extract master colours --------------
    img = Image.open(args.input).convert("RGB")
    orig_w, orig_h = img.size            # source dimensions before any resample
    src_colours = int(np.unique(np.asarray(img).reshape(-1, 3), axis=0).shape[0])
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
        if args.dither != "none":
            arr = dither_to_palette(arr, pal, args.dither, args.dither_strength)
        else:
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

    # ---- Phase B: two strategies -------------------------------------------
    def run_fidelity():
        """Keep every pixel's true colour; duplicate colours across palettes as
        needed; substitute only when a palette overflows. Optimal when colours
        fit the slot budget; loses colours to duplication overflow otherwise."""
        cp = np.zeros((H, cells_per_line), dtype=np.int16)
        rmaps = [np.arange(N) for _ in range(NP)]
        fcolors = [set() for _ in range(NP)]
        sp = 0; se = 0.0
        lab, _ = kmeans(colors_lab, NP, seed=args.seed)
        palette = [set() for _ in range(NP)]; binsize = [0] * NP
        for i in sorted(range(len(cells)), key=lambda i: -len(cells[i][2])):
            y, cx, u = cells[i]
            if len(u) == 0:
                cp[y, cx] = 0; continue
            pref = int(np.bincount(lab[u], weights=color_count[u], minlength=NP).argmax())
            adds = [sum(1 for c in u if int(c) not in palette[b]) for b in range(NP)]
            room = [b for b in range(NP) if binsize[b] + adds[b] <= cap]
            cand = room if room else list(range(NP))
            b = min(cand, key=lambda b: (adds[b], 0 if b == pref else 1, binsize[b]))
            for c in u:
                if int(c) not in palette[b]:
                    palette[b].add(int(c)); binsize[b] += 1
            cp[y, cx] = b
        if args.optimize:
            reduce_duplication(cp, cells, NP, cap)
        pp = np.repeat(cp, cell_w, axis=1)[:, :W]
        for b in range(NP):
            mask = (pp == b) & (~transparent)
            cc = np.bincount(pix[mask].ravel(), minlength=N)
            used = np.nonzero(cc)[0]
            if len(used) <= cap:
                fcolors[b] = set(int(c) for c in used); continue
            keep = used[np.argsort(cc[used])[::-1][:cap]]
            drop = np.setdiff1d(used, keep)
            keep_lab = colors_lab[keep]
            for c in drop:
                d = ((keep_lab - colors_lab[c]) ** 2).sum(1)
                nn = int(keep[d.argmin()])
                rmaps[b][c] = nn; sp += int(cc[c]); se += float(np.sqrt(d.min())) * int(cc[c])
            fcolors[b] = set(int(c) for c in keep)
        return cp, rmaps, fcolors, sp, se

    def run_balanced(w, k_floor, refine_iters=4):
        """Continuum anchored at fidelity (w=0 -> ~k_floor colours) and max colours
        (w=1). Picks K = interp(k_floor, K_max) colours to display, places each in
        the palette where it's used most, fills spare slots with the best
        duplicates. Then iterates: reassign each cell to the palette that minimizes
        the cell's total perceptual (OKLab) error -- not plurality -- and re-pick
        slots, so the attribute map and palette contents agree. This makes mixed
        regions choose one palette coherently (killing the cell-to-cell streaks)."""
        home = balanced_cluster(colors_lab, NP, cap, seed=args.seed)
        # cache each cell's (colour ids, counts), transparent excluded
        cellcc = []
        for y in range(H):
            row = pix[y]; trow = transparent[y]
            for cx in range(cells_per_line):
                a, bb = cx * cell_w, (cx + 1) * cell_w
                seg = row[a:bb][~trow[a:bb]]
                if len(seg) == 0:
                    cellcc.append(None)
                else:
                    u, c = np.unique(seg, return_counts=True)
                    cellcc.append((u, c))
        cp = np.zeros((H, cells_per_line), dtype=np.int16)
        # initial assignment: plurality of colour home cluster
        for i, cc in enumerate(cellcc):
            y, cx = divmod(i, cells_per_line)
            cp[y, cx] = 0 if cc is None else int(np.bincount(home[cc[0]], weights=cc[1], minlength=NP).argmax())

        def select_slots(cp):
            pp = np.repeat(cp, cell_w, axis=1)[:, :W]
            dem = np.stack([np.bincount(pix[(pp == b) & (~transparent)].ravel(), minlength=N)
                            for b in range(NP)])
            used = np.nonzero(dem.sum(0))[0]
            K = max(1, min(len(used), int(round(k_floor + w * (len(used) - k_floor)))))
            display = used[np.argsort(dem.max(0)[used])[::-1][:K]]
            counts = [0] * NP; Sb = [set() for _ in range(NP)]
            for c in display:
                c = int(c)
                for b in np.argsort(dem[:, c])[::-1]:
                    if dem[b, c] == 0: break
                    if counts[b] < cap:
                        Sb[b].add(c); counts[b] += 1; break
            cand = [(int(dem[b, c]), int(c), b) for b in range(NP) for c in display
                    if int(c) not in Sb[b] and dem[b, int(c)] > 0]
            cand.sort(reverse=True)
            for val, c, b in cand:
                if counts[b] < cap and c not in Sb[b]:
                    Sb[b].add(c); counts[b] += 1
            return Sb

        Sb = select_slots(cp)
        lam = float(args.coherence)
        for it in range(refine_iters):
            E = np.zeros((N, NP)); rmaps = []
            for b in range(NP):
                kb = np.array(sorted(Sb[b])) if Sb[b] else np.array([0])
                d = ((colors_lab[:, None, :] - colors_lab[kb][None, :, :]) ** 2).sum(2)
                j = d.argmin(1)
                E[:, b] = np.sqrt(d[np.arange(N), j])
                rmaps.append(kb[j])
            new_cp = cp.copy()
            for i, cc in enumerate(cellcc):
                if cc is None:
                    continue
                y, cx = divmod(i, cells_per_line)
                u, c = cc
                err = (E[u] * c[:, None]).sum(0)        # total OKLab error per palette
                if lam > 0:                              # prefer agreeing with neighbours
                    nb = []
                    if y > 0: nb.append(cp[y - 1, cx])
                    if y < H - 1: nb.append(cp[y + 1, cx])
                    if cx > 0: nb.append(cp[y, cx - 1])
                    if cx < cells_per_line - 1: nb.append(cp[y, cx + 1])
                    for b in range(NP):
                        err[b] += lam * sum(1 for v in nb if v != b)
                new_cp[y, cx] = int(err.argmin())
            if np.array_equal(new_cp, cp):
                cp = new_cp; break
            cp = new_cp
            Sb = select_slots(cp)

        # final remaps from final Sb
        rmaps = []
        for b in range(NP):
            kb = np.array(sorted(Sb[b])) if Sb[b] else np.array([], dtype=int)
            rb = np.arange(N)
            if len(kb):
                notin = np.ones(N, bool); notin[kb] = False
                ni = np.nonzero(notin)[0]
                if len(ni):
                    d = ((colors_lab[ni][:, None, :] - colors_lab[kb][None, :, :]) ** 2).sum(2)
                    rb[ni] = kb[d.argmin(1)]
            rmaps.append(rb)
        fcolors = [set() for _ in range(NP)]; sp = 0; se = 0.0
        pp = np.repeat(cp, cell_w, axis=1)[:, :W]
        for b in range(NP):
            kb = np.array(sorted(Sb[b])) if Sb[b] else np.array([], dtype=int)
            cids = pix[(pp == b) & (~transparent)].ravel()
            if len(cids):
                off = ~np.isin(cids, kb)
                if off.any():
                    oc = cids[off]; sp += int(off.sum())
                    se += float(np.sqrt(((colors_lab[oc] - colors_lab[rmaps[b][oc]]) ** 2).sum(1)).sum())
                fcolors[b] = set(int(c) for c in np.unique(rmaps[b][cids]))
        return cp, rmaps, fcolors, sp, se

    strategy = "lossless"
    if not lossless:
        bias = 1.0 if args.max_colors else max(0.0, min(1.0, args.color_bias))
        fid = run_fidelity()
        if bias <= 0.0:
            chosen = fid; strategy = "fidelity (bias 0.00)"
        else:
            k_floor = len(set().union(*fid[2]))        # fidelity colour count = anchor
            chosen = run_balanced(bias, k_floor); strategy = f"balanced (bias {bias:.2f})"
        cell_pal, remaps, final_colors, sub_pixels, sub_err_sum = chosen

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
    out_cid = pix.copy()                         # transparent px keep their id
    for b in range(NP):
        mask = (pal_pp == b) & (~transparent)
        cids = remaps[b][pix[mask]]
        out_idx[mask] = slot_of[b, cids]
        out_rgb[mask] = colors[cids]
        out_cid[mask] = cids
    # transparent (letterbox) pixels: index 0, shown as palette slot 0 (black)
    out_idx[transparent] = 0
    out_rgb[transparent] = pal_rgb[0, 0]

    # ---- what the cell rule cost, against the same image without it --------
    acc = compare_to_ideal(pix, out_cid, colors, colors_lab, transparent,
                           cell_w)

    # ---- write files --------------------------------------------------------
    base = args.name if args.name else os.path.splitext(os.path.basename(args.input))[0]
    # The Atari viewer (SpartaDOS X) only sees 8.3 short names, so the .map/.raw
    # /.pal/.nfo set has to be renamed to something like IMG0.* when it is staged
    # onto the disk.  Warn if the base is not already 8.3-safe - a mismatch there
    # is the most common way the About screen ends up loading the wrong .nfo.
    _bad = set(base) - set("abcdefghijklmnopqrstuvwxyz"
                           "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    if len(base) > 8 or _bad:
        sys.stderr.write("warning: output base %r is not an 8.3 short name - "
                         "the Atari viewer (SDX) needs e.g. --name IMG0\n" % base)
    # {base}.raw : one byte per pixel, row-major
    out_idx.tofile(os.path.join(args.out, base + ".raw"))
    # {base}#.pal : 256 entries x (R,G,B) = 768 bytes each
    for b in range(NP):
        pal_rgb[b].astype(np.uint8).tofile(os.path.join(args.out, f"{base}{b}.pal"))
    # {base}.pal : all palettes concatenated (palette-major), NP*256*3 bytes
    pal_rgb.astype(np.uint8).tofile(os.path.join(args.out, base + ".pal"))
    # {base}.map : one byte per cell, palette id (0-3) << 4  ->  0,16,32,48
    (cell_pal * 16).astype(np.uint8).tofile(os.path.join(args.out, base + ".map"))
    # human-facing previews
    Image.fromarray(out_rgb, "RGB").save(os.path.join(args.out, base + "_preview.png"))

    # palette swatch sheet
    sw = 12
    sheet = np.zeros((NP * sw, args.slots * sw, 3), dtype=np.uint8)
    for b in range(NP):
        for s in range(args.slots):
            sheet[b*sw:(b+1)*sw, s*sw:(s+1)*sw] = pal_rgb[b, s]
    Image.fromarray(sheet, "RGB").save(os.path.join(args.out, base + "_palettes.png"))

    # ---- report -----------------------------------------------------------
    # Fixed 80-column layout: label padded to 21, then ": ", value at col 24;
    # wrapped lines align under the value (23 spaces).  This drives the Atari
    # viewer's "About" screen, so the layout must stay stable and parseable -
    # see Convertor/out/Sample_report.txt for the canonical form.
    total_px = H * W
    unique_out = len(np.unique(out_rgb.reshape(-1, 3), axis=0))

    def row(label, value):
        return f"{label:<21}: {value}"

    def cont(text):
        return " " * 23 + text

    lines = []
    lines.append("=" * 31 + "palettize_4 report" + "=" * 31)   # 80-col banner
    lines.append(row("Input", os.path.basename(args.input)))
    lines.append(row("Dimensions", f"{orig_w} x {orig_h}  ({orig_w*orig_h} px)"))
    if args.resize:
        lines.append(row("Resampled", f"{W}x{H} via {args.filter} (fit={args.fit}"
                     + (f", display-aspect={args.display_aspect}" if args.fit != "stretch" else "") + ")"))
    else:
        lines.append(row("Resampled", f"none (native {W}x{H})"))
    lines.append(row("Cell width", f"{cell_w} px  ->  {cells_per_line} cells/line "
                     f"* {H} lines = {cells_per_line*H} cells"))
    lines.append(row("Palettes x slots", f"{NP} x {args.slots}  (usable {cap}/palette"
                 + (", slot 0 = transparent" if args.reserve0 else "") + ")"))
    if int(transparent.sum()):
        lines.append(row("Transparent px", f"{int(transparent.sum())} letterbox/pillarbox -> index 0"))
    if prequant and src_colours > N:
        lines.append(row("Pre-quantized", f"{src_colours} source colours -> reduced to {N}"))
    else:
        lines.append(row("Pre-quantized", f"{src_colours} source colours"))
    lines.append(row("Master colours", N))
    lines.append(row("Output colours", f"{unique_out}  (distinct RGB on screen)"))
    lines.append("")
    lines.append(row("Strategy", strategy))
    if lossless:
        lines.append(f"{'RESULT: LOSSLESS':<23}components packed into "
                     f"{NP} palettes with no colour loss.")
    else:
        pct = 100.0 * sub_pixels / total_px
        mean_err = (sub_err_sum / sub_pixels) if sub_pixels else 0.0
        lines.append(f"{'RESULT: LOSSY':<23}cells could not be partitioned cleanly.")
        lines.append(row("  recoloured pixels", f"{sub_pixels} ({pct:.3f}% of image)"))
        lines.append(row("  mean OKLab error", f"{mean_err:.4f}  (on recoloured pixels only)"))
        if max_comp > cap and strategy.startswith("fidelity"):
            lines.append(f"  note: a single component needs {max_comp} colours (> {cap});")
            lines.append("  raise --color-bias (e.g. 0.5 or 1.0) to recover more colours.")
    lines.append("")
    lines.append("Accuracy vs the ideal (what the 8-px cell rule cost):")
    lines.append(row("  the ideal here =",
                     f"this source {'resized and ' if args.resize else ''}reduced to {N} colours"))
    lines.append(cont("with no cell restriction applied"))
    seam = acc["seam_index"]
    lines.append(row("  identical pixels", f"{acc['identical_pixels']} / "
                     f"{acc['compared_pixels']}  ({acc['identical_pct']:.2f}% of opaque px)"))
    lines.append(row("  RMSE (sRGB)", f"{acc['rgb_rmse']:.2f}     <- the norm distance"))
    lines.append(row("  PSNR", "identical - the cell rule cost nothing"
                     if acc["psnr_db"] is None else f"{acc['psnr_db']:.1f} dB"))
    lines.append(row("  mean OKLab error",
                     f"{acc['mean_oklab_error']:.4f}  (every pixel, not just the recoloured ones)"))
    lines.append(row("  worst OKLab error", f"{acc['max_oklab_error']:.4f}"))
    lines.append(row("  cells damaged", f"{acc['cells_damaged']} / "
                     f"{acc['cells_compared']}  ({acc['cells_damaged_pct']:.1f}%)"))
    if seam is None:
        lines.append(row("  cell seams", "n/a (no column detail to measure)"))
    else:
        lines.append(row("  cell seams", f"{seam:.2f}x  (the cell grid added no visible seam)"))
        lines.append(cont("RMSE and PSNR above cannot see this"))
    lines.append("")
    # how many palettes each colour appears in (to find entries unique to one)
    pal_count = np.zeros(N, dtype=np.int32)
    for b in range(NP):
        for c in final_colors[b]:
            pal_count[c] += 1
    all_pal_colors = set().union(*final_colors) if NP else set()
    total_entries = sum(len(final_colors[b]) for b in range(NP))
    duplicated = total_entries - len(all_pal_colors)
    per_palette = []
    parts = []                              # "Pn: <colours unique to palette n>"
    for b in range(NP):
        uniq_b = sum(1 for c in final_colors[b] if pal_count[c] == 1)
        per_palette.append({"colours": len(final_colors[b]), "unique_to_palette": uniq_b})
        parts.append(f"P{b}: {uniq_b}")
    lines.append(row("Per-palette colours", " ".join(parts) + f" / {cap} colours"))
    lines.append(f"  duplicated across palettes: {duplicated} "
                 f"entr{'y' if duplicated == 1 else 'ies'} "
                 f"({len(all_pal_colors)} distinct colours in all palettes)")
    report = "\n".join(lines)
    with open(os.path.join(args.out, base + "_report.txt"), "w") as f:
        f.write(report + "\n")

    # ---- the same report as a viewer-native .nfo -------------------------
    # The Atari viewer blits this straight onto its 80-col VBXE text screen,
    # so the file IS that screen's byte image: fixed 160-byte line records,
    # 80 cells of {glyph, attr=$07}, space-padded, no line terminators; a
    # trailing all-$00 record marks end-of-text.  Every report line is <= 80
    # chars by construction (row()/cont() above) - assert it so a later edit
    # to the layout can't silently produce an unreadable About screen.
    NFO_COLS, NFO_MAX_LINES = 80, 127
    if len(lines) > NFO_MAX_LINES:
        raise SystemExit("report is %d lines, over the .nfo viewer cap of %d"
                         % (len(lines), NFO_MAX_LINES))
    # The screen is 80 columns; the .txt keeps full-length lines, the binary
    # .nfo clips each record to fit (a long Input filename is the usual cause).
    nfo = bytearray()
    for ln in lines:
        for ch in ln[:NFO_COLS].ljust(NFO_COLS):
            nfo.append(ord(ch) & 0xFF)
            nfo.append(0x07)
    nfo.extend(b"\x00" * (NFO_COLS * 2))          # end-of-text sentinel record
    with open(os.path.join(args.out, base + ".nfo"), "wb") as f:
        f.write(nfo)

    # ---- machine-readable stats (sidecar JSON, always written) -------------
    eff_bias = 1.0 if args.max_colors else max(0.0, min(1.0, args.color_bias))
    stats = {
        "input": args.input,
        "name": base,
        "out_dir": args.out,
        "width": W, "height": H, "pixels": total_px,
        "source_width": orig_w, "source_height": orig_h,
        "source_colours": src_colours,
        "cell_width": cell_w, "cells_per_line": cells_per_line,
        "cells": cells_per_line * H,
        "palettes": NP, "slots": args.slots, "usable_per_palette": cap,
        "reserve0": bool(args.reserve0),
        "resized": bool(args.resize),
        "resize": args.resize, "filter": args.filter if args.resize else None,
        "fit": args.fit if args.resize else None,
        "prequantized": bool(prequant),
        "master_colours": int(N),
        "output_colours": int(unique_out),
        "components": int(ncomp), "largest_component": int(max_comp),
        "transparent_pixels": int(transparent.sum()),
        "lossless": bool(lossless),
        "strategy": strategy,
        "color_bias": eff_bias, "coherence": float(args.coherence),
        "recoloured_pixels": int(sub_pixels),
        "recoloured_pct": (100.0 * sub_pixels / total_px) if total_px else 0.0,
        "mean_oklab_error": (sub_err_sum / sub_pixels) if sub_pixels else 0.0,
        # NESTED, and not flattened in beside the key above: that one means
        # the average over RECOLOURED pixels only, this block measures the
        # whole picture.  Two keys of the same name meaning different things
        # is the bug that ships.
        "ideal_vs_output": acc,
        "duplicated_across_palettes": int(duplicated),
        "distinct_in_all_palettes": int(len(all_pal_colors)),
        "per_palette": per_palette,
        "files": {
            "raw": base + ".raw",
            "map": base + ".map",
            "palettes_combined": base + ".pal",
            "palettes": [f"{base}{b}.pal" for b in range(NP)],
            "preview": base + "_preview.png",
            "palettes_png": base + "_palettes.png",
            "report": base + "_report.txt",
            "nfo": base + ".nfo",
            "stats": base + "_stats.json",
        },
    }
    with open(os.path.join(args.out, base + "_stats.json"), "w") as f:
        json.dump(stats, f, indent=2)

    if args.json:
        print(json.dumps(stats))
    elif not args.quiet:
        print(report)


if __name__ == "__main__":
    main()

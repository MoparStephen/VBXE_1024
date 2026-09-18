# VBXE 1024 Colour Image Viewer
Slideshow viewer for new format 1024 colour images

## Image list

At startup the `Scan_Images` init step opens `D:*.MAP` as a directory (the
wildcard does the filtering) and stores every base name it finds - space-padded
to 8 bytes - into VBXE bank `$40`, addressed through the `$2000` window, with
`ImageCount` holding the total. No CPU RAM is spent on the list. If nothing
matches, the loading screen shows "No images found" and the program exits.

At runtime `Build_Filename` composes `D:<name>.PAL` / `.MAP` / `.RAW` on demand
for the three `LoadData` calls in `Load_Image`. Navigation:

- **Space** - next image, wraps past the last back to the first
- **Backspace** - previous image, wraps the other way
- **0-4** - overlay palette / colour-map select for the current image
- **Q** - quit
- **Esc** - reserved for the (not-yet-built) viewer UI; currently a no-op

`Sort_Image_List` (alphabetical, in place) is written but **not wired in** - the
list is left in disk order for now; a future UI can enable the sort.

### `IMAGES.LST` - long filenames on the selector status line

The Atari disk only holds 8.3 short names, so the original source filename
(`isabelle_fuhrman_eyes.jpg`) is lost from `IMG0.MAP`. If an `IMAGES.LST` file
sits in the same directory as the images, the selector reads it once per
directory scan (`Nfo_Name_LoadManifest`) and shows `Src: <name>` on row 26 for
the highlighted image. Each record is an 8-byte key (the `.MAP` base name as
it lands on the Atari disk - illegal chars like space stripped, `_` kept,
upper-cased, first 8, space-padded) + the source name + `$9B`; the viewer
matches a record to a row by that key, so extra or out-of-order records are
harmless.
No `IMAGES.LST` -> the line is just blank.

Build it with **`build_images_lst.py <folder>`** or the converter GUI's
**File > Build images.lst...**. Run it on the folder you build the disk image
from, after any renaming to `IMGn`, so the keys match the on-disk names. The
names themselves come from each image's `.NFO` record 1 (the converter's
`Input : <name>` line).

**`MAX_IMAGES` = 255, by design.** Each image is a ~90 kB `.PAL`/`.MAP`/`.RAW`
set, so 255 already far exceeds any realistic slideshow on one partition, and a
single-byte count keeps every navigation and sort loop small. There is no plan
to raise it.

## TODOs (ATARI Viewer)

- About screen #1 (shows the convertor's report.txt for each image)
- About screen #2 (shows all 4 palettes in 4 distinct quadrants)
- `.NFO` (report info) as a 4th per-image file; let the user read the about
  text without loading ~90 kB of image data
- Tighter error handling around opening & reading each of the per-image files
- Wire `Sort_Image_List` into a viewer-UI option



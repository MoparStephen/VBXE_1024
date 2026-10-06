 ; .loadsym "C:\Users\Stephen\source\Claude\VBXE_1024\Viewer\out\view1024.lab"
 
;-----------------------------------------------------------------------------
; Memory Map
;-----------------------------------------------------------------------------
; Load Address = 
; Run Address = 
; VBXE:
;    XDLs            = $00000 - $00068 (image attribute + image normal +
;                      XDL_MainMenu's 8 chained blocks, well clear of $00100)
;    BCBs            = $00100 - $001FF
;    NTSC_Palette    = $00200 - $004FF (256 RGB triplets; restores Palette 0 on exit)
;    PAL_Palette     = $00500 - $007FF (256 RGB triplets; restores Palette 0 on exit)
;    Text pal buffer = $00800 - $00AFF (UI_Apply_TextPalette de-interleave scratch)
;    VRAM            = $01000 - $13BFF (Video Ram)
;    CRAM_Buffer     = $14000 - $1657F (Compressed palette bytes)
;    CRAM            = $17000 - $205FF (Colour Ram)
;    Palette_Buffers = $21000 - $21FFF (Temp 4kB buffer for loading palettes)
;    Text fonts      = $22000 - $22FFF (CGA.F08 @ $22000 / ATARI.F08 @ $22800;
;                      F toggles XDL_MainMenu's two CHBASE bytes between them -
;                      see text80.asm)
;    Text screen RAM = $23000 - $23E5F (23 rows x 160 {glyph,attr} bytes = 3680;
;                      ONE contiguous buffer for both text bands of the menu/
;                      info XDL - rows 0-19 = main content, rows 20-22 = footer,
;                      the on-screen gap between them is a display-time-only XDL
;                      gap, not a VRAM gap - see TEXT_MAIN_ROWS/TEXT_FOOTER_ROWS)
;    Menu banner     = $30000 - $32CFF (banks $30-$32: MENU_BANNER_VRAM, 36 rows
;                      x 320 bytes, attribute-mapped, static logo/banner for the
;                      Main Menu + Info XDL's graphics band)
;    Menu separator  = $33000 - $3309F (MENU_SEP_VRAM: 1 row x 160 bytes, lo-res
;                      no-attribute-map divider line, shared by all three separator
;                      bands of the menu/info XDL; a pattern table loaded at load
;                      time from Assets/MENU_SEP.RAW - see Load_Menu_Sep)
;    Menu banner pal = $34000 - $34BFF (MENU_BANNER_PAL_VRAM: the banner's
;                      palette bytes, resident and assembly-embedded (Load_
;                      Menu_Ramps, init_vbxe.asm) - registers 1-3 are
;                      refreshed from here on every Enter_Selector with no
;                      disk access; see Apply_Menu_Banner_Palette)
;    Menu banner map = $35000 - $3667F (MENU_BANNER_MAP_VRAM: the banner's
;                      expanded attribute map, resident, dedicated - NOT the
;                      shared CRAM $017000, so it's never clobbered by Load_
;                      Image and never needs a reload)
;    NFO display buf = $25000 - $29FFF (banks $25-$29: the <name>.NFO file loaded
;                      verbatim - up to NFO_MAX_LINES fixed 160-byte {glyph,attr}
;                      line records, TEXT_PITCH stride; blitted to the text
;                      screen a window at a time by BLT_NFO_DRAW)
;    (banks $2A-$2D are free - the NFO name cache moved to $37000 when it grew)
;    Menu demo ramp  = $2E000 - $2E0FF (MENU_RAMP_VRAM: 256-byte ascending
;                      0..255 pixel-source square for the banner's 4-palette
;                      demo overlay, built at boot by Build_Menu_Ramp_Table;
;                      rest of bank $2E free)
;    Text win save   = $2F000 - $2FFFF (WIN_SAVE_VRAM: save-under for the D
;                      window and the Q quit-confirm window)
;    NFO name cache  = $37000 - $3EFFF (banks $37-$3E: the selector status line's
;                      image descriptions, NFO_NAME_SLOT bytes/image, loaded
;                      once from D:IMAGES.LST per dir rescan, wiped before each)
;    (bank $3F is free)
;    Image name list = $40000 - $40FFF (bank $40: up to MAX_IMAGES=255 rows -
;                      "..", sub-dirs and *.V1K files, 8 bytes each; + a 10-char
;                      display field is formatted in place at draw time)
;    (bank $41 is free - the old folder browser used it)
;
; MAX_IMAGES is a hard design ceiling of 255 - each image is a ~90kB
; .V1K file, so 255 far exceeds any real slideshow, and a one-byte
; count keeps every nav/sort loop small. Not intended to ever be raised.

;-----------------------------------------------------------------------------
;  HARDWARE EQUATES
;-----------------------------------------------------------------------------
    icl 'equates.asm'

;-----------------------------------------------------------------------------
; Structure Declarations
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Variables go here
;-----------------------------------------------------------------------------
; Page 0 user data ($80 to $FF with some reserved for OS)
.zpvar Reg1				.byte			; Multi-Use Variables
.zpvar Reg2				.byte			; Multi-Use Variables
.zpvar Reg3				.byte			; Multi-Use Variables
.zpvar Reg4				.byte			; Multi-Use Variables
.zpvar Reg5				.byte			; Multi-Use Variables
.zpvar Reg6				.byte			; Multi-Use Variables
.zpvar Reg7				.byte			; Multi-Use Variables
.zpvar Reg8				.byte			; Multi-Use Variables
.zpvar Ptr_Lo			.byte			; Lo byte of pointer
.zpvar Ptr_Hi			.byte			; Hi byte of pointer
.zpvar Name_Ptr			.word			; Scan write-cursor / Build_Filename source ptr
.zpvar Sort_Ptr			.word			; Sort_Range 2nd record ptr

; Non Page-0 Variables
;	$480 to $4FF free
;	$600 to $6FF free
; When using PMG the 1st $300 bytes are always free
.var SDMCTL_OLD			.byte = $480	; Save DMA
.var CRSINH_OLD			.byte = $481	; Save CRSINH (Mouse Pointer)
.var LMARGIN_OLD		.byte = $482	; Save LMARGIN
.var COLOR2_OLD			.byte = $483	; Save COLOR2
.var SP_REG_OLD			.byte = $484	; Save the Stack Pointer
.var SDLSTL_OLD			.byte = $485	; Save the Display List Pointer
.var SDLSTH_OLD			.byte = $486	; Save the Display List Pointer
.var DOSINIL_OLD		.byte = $487	; Save the DOSINI Pointer
.var DOSINIH_OLD		.byte = $488	; Save the DOSINI Pointer
.var Video_Flag			.byte = $489	; PAL = 0, NTSC = 1
.var File_Index			.byte = $48A	; 0-based image ordinal (0 .. ImageCount-1)
.var ImageCount			.word = $48B	; Images found by Rescan_Images (hi byte always 0)
.var Path_Buf			:56 .byte = $48D	; Built "D[n]:PATH>NAME.EXT",$00 for LoadData ($48D-$4C4)
.var Dir_IOCB			.byte = $4C5	; IOCB used by Build_Image_List
; --- viewer UI state (ui.asm) ---
.var UI_Mode			.byte = $4C6	; 0 selector / 1 image / 2 slideshow / 3 drive picker / 4 info / 6 P-preview
.var Sel_Index			.byte = $4C7	; highlighted list entry (0-based)
.var Sel_Top			.byte = $4C8	; list index of the first visible row (scroll)
.var Slide_Secs			.byte = $4C9	; slideshow delay, seconds (1..30)
.var Slide_FrameCtr		.word = $4CA	; slideshow countdown, frames
.var Scan_Drive			.byte = $4CC	; '1'..'8', or $00 for a bare "D:"
.var Name_Row_Buf		:12 .byte = $4CD	; one name record / formatted row, NUL-terminated
.var Dir_Count			.byte = $4D9	; selector list: number of sub-directory rows
.var FileStart			.byte = $4DA	; selector list: index of the first *.V1K row (= upCount + Dir_Count)
.var Drive_Pick_Index	.byte = $4DB	; drive picker (UI_Mode 3): 0 = "D:", 1..8 = "Dn:"
.var Nfo_Top			.word = $4DC	; info viewer: first visible line record (0-based)
.var Nfo_LineCount		.word = $4DE	; info viewer: line records in the loaded .NFO
.var Font_Sel			.byte = $4E0	; text font: 0 = CGA ($44), 1 = Atari ($45)
.var Nfo_Name_Ord		.byte = $4E1	; selector status line: file ordinal being fetched
; --- single-file .V1K image loader (Image_Open / Image_Read_Segment) ---
.var Load_IOCB			.byte = $4E2	; IOCB offset of the open .V1K file
.var Seg_Bank			.byte = $4E3	; VBXE bank the next 4K chunk lands in
.var Seg_Chunks			.byte = $4E4	; full 4K chunks left in this segment
.var Seg_Tail			.word = $4E5	; bytes in the segment's final partial chunk
;	$4E7 to $4FF free
.var Dir_Line_Buf		:$28 .byte = $600	; One GET RECORD dir line ($600-$627)
.var Scan_Path			:$28 .byte = $628	; subdirectory part, ">DIR>DIR>" or empty ($628-$64F)
.var Scan_Spec			:$30 .byte = $650	; assembled "D[n]:PATH*.V1K",$9B ($650-$67F)
.var Txt_Line			:$30 .byte = $680	; scratch line assembled for Text_PutStrAt ($680-$6AF)
; One IMAGES.LST record (8-byte key + <=NFO_NAME_CAP description + $9B) for
; Nfo_Name_LoadManifest, and the padded status-line text Nfo_Name_Emit builds
; for Selector_DrawStatus.  8+75+1 = 84 bytes fits no free gap, so it OVERLAYS
; Scan_Spec + Txt_Line ($650-$6A3).  Safe because neither is live across
; either use: Scan_Spec is only read by the CIO OPEN before the record loop
; (and rebuilt before every scan), Txt_Line is per-draw scratch that
; Text_PutStrAt does not touch, and Nfo_WalkBank ($650) is only live inside
; Info_Count_Lines (UI_Mode 4, no status line).
.var Nfo_Name_Line		:84 .byte = $650	; 8 key + 75 desc + $9B ($650-$6A3)
;	$6B7 to $6FF free (text80.asm uses $6B0-$6B6)
; Info viewer (.nfo): Info_Count_Lines maps NFO buffer banks through the $2000
; window and needs one byte to track which.  Overlays Scan_Spec ($650-$67F),
; idle whenever UI_Mode = 4 - the next disk scan rebuilds it on the way out.
.var Nfo_WalkBank		.byte = $650	; NFO buffer VBXE bank currently mapped ($25..$29)
;	$651-$6AF free while UI_Mode = 4 (Scan_Spec / Txt_Line otherwise)

;-----------------------------------------------------------------------------
; Defines go here
;-----------------------------------------------------------------------------
.def	__VBXE_AUTO__
.def	VBXE_WINDOW						= $2000
.def	VBXE_WINDOW_SIZE_4k				= $1000
.def	VBXE_WINDOW_SIZE_8k				= $2000
.def	LOAD_ADDRESS					= VBXE_WINDOW + VBXE_WINDOW_SIZE_4k

; Image name list (built by Rescan_Images - see ui.asm)
.def	IMAGE_BANK						= $40	; VBXE bank holding the name list
.def	MAX_IMAGES						= 255	; Hard ceiling - see Memory Map note
.def	ImageNames						= VBXE_WINDOW	; List base once IMAGE_BANK is mapped
.def	ImageNames_End					= ImageNames + (MAX_IMAGES * 8)
.def	Dir_Line_Len					= $28	; Max length of one dir GET RECORD line

; Single-file image: <name>.V1K = .PAL block + .MAP block + .RAW block, no
; header - every block is fixed-size, so every offset is a constant.
; Load_Image streams each block to the same VRAM the old 3-file load used.
.def	V1K_PAL_LEN						= $0C00		; 4 palettes x 768     = 3072
.def	V1K_MAP_LEN						= $2580		; 40 cells x 240 rows  = 9600
.def	V1K_RAW_LEN						= $12C00	; 320 x 240 pixels     = 76800
.def	V1K_PAL_BANK					= $21		; -> $21000 (read back by Apply_Image_Palette)
.def	V1K_MAP_BANK					= $14		; -> $14000 (CRAM_Buffer, Setup_Cmap1 expands it)
.def	V1K_RAW_BANK					= $01		; -> $01000 (framebuffer)

; VBXE text screen (text80.asm + XDL_MainMenu in xdl.asm - these MUST agree).
; Chosen clear of the image framebuffer/CRAM ($01000-$205FF), palette buffer
; ($21000), the name list ($40000) and the dir browser ($41000).
.def	TEXT_FONT_VRAM					= $22000	; CGA.F08 (2048 bytes) lands here
.def	TEXT_FONT_BANK					= TEXT_FONT_VRAM / $1000	; = $22  (LoadData target bank)
.def	TEXT_CHBASE						= TEXT_FONT_VRAM / $800	; = $44  (XDL_MainMenu CHBASE bytes, CGA - boot default)
.def	TEXT_FONT2_VRAM					= TEXT_FONT_VRAM + $800	; $22800 - Atari font (2nd 2K slot in bank $22)
.def	TEXT_CHBASE2					= TEXT_FONT2_VRAM / $800	; = $45  (XDL_MainMenu CHBASE bytes, Atari)
.def	TEXT_SCREEN_VRAM				= $23000	; ONE contiguous {glyph,attr} buffer,
													; TEXT_ROWS rows x TEXT_PITCH bytes
.def	TEXT_SCREEN_BANK				= TEXT_SCREEN_VRAM / $1000	; = $23  (first bank of screen RAM)
.def	TEXT_COLS						= 80
.def	TEXT_PITCH						= TEXT_COLS * 2	; $A0 = 160
; The menu/info XDL displays this ONE linear buffer as two on-screen bands
; (a blank+separator gap between them is a display-time XDL gap only, not a
; VRAM gap - text80.asm's Text_PutStrAt just walks linear rows 0..TEXT_ROWS-1):
.def	TEXT_MAIN_ROWS					= 20		; rows 0-19: grid/Location/NFO scroll content
.def	TEXT_FOOTER_ROWS				= 3		; rows 20-22: status/delay/legend, or an info hint line
.def	TEXT_ROWS						= TEXT_MAIN_ROWS + TEXT_FOOTER_ROWS	; = 23 total buffer rows
.def	TEXT_SCREEN_BYTES				= TEXT_ROWS * TEXT_PITCH	; 23*160 = 3680
.def	TEXT_FOOTER_VRAM				= TEXT_SCREEN_VRAM + (TEXT_MAIN_ROWS * TEXT_PITCH)	; row 20 of the same buffer

; Menu/info XDL graphics bands (XDL_MainMenu in xdl.asm) - the top banner and
; the two (shared) 1-line separators.  Both sit in the previously-undocumented,
; genuinely-unreferenced $30000-$3FFFF gap, well clear of every other region.
.def	MENU_BANNER_VRAM				= $30000
.def	MENU_BANNER_BANK				= MENU_BANNER_VRAM / $1000	; = $30
.def	MENU_BANNER_ROWS				= 36
.def	MENU_BANNER_PITCH				= 320		; = $140, matches XDL_Image_* OVSTEP
.def	MENU_BANNER_BYTES				= MENU_BANNER_ROWS * MENU_BANNER_PITCH	; = 11520 = $2D00
.def	MENU_SEP_VRAM					= $33000	; next free bank after the banner (3 banks)
.def	MENU_SEP_PITCH					= 160		; 160-byte pattern table, Palette 0 (modified) indices -
														; Assets/MENU_SEP.RAW, loaded once by Load_Menu_Sep (init_vbxe.asm)

; Banner palette + attribute map: never touched at runtime (unlike the real
; image viewer's $21000/$017000 scratch, which Load_Image legitimately
; overwrites for every image view).  Dedicated, resident VRAM - see
; Load_Menu_Banner_Raw / Apply_Menu_Banner_Palette (below).
; The palette bytes are assembly-embedded (Load_Menu_Ramps, init_vbxe.asm),
; not disk-loaded.  The attribute map has no file either: it is left all
; zeros (= palette 0) by the boot-time clear_vbxe, and Set_Menu_Demo_Attrs
; sets just the ramp squares' cells.
.def	MENU_BANNER_PAL_VRAM			= $34000	; same 4x768-byte .PAL layout Load_Image
													; uses ($0000/$0300/$0600/$0900); slot 0 unused
													; - palette register 0 is reserved for text
.def	MENU_BANNER_MAP_VRAM			= $35000	; expanded attribute map (40 cells x 36 rows x
													; 4 bytes = 5760 bytes, same layout as CRAM);
													; XDL_MainMenu's banner MAPADR points here, NOT
													; at the shared $017000 CRAM

; Menu banner palette-demo overlay: a 32x33px 2x2 grid of identical 16x16
; ramp squares, repeated at both banner edges. Left edge: TL=pal0, TR=pal1,
; BL=pal2, BR=pal3. Right edge: same pixel data (Menu_Demo_Dest_Table is
; unchanged) but horizontally mirrored via the attribute map only -
; TL=pal1, TR=pal0, BL=pal3, BR=pal2 - see Build_Menu_Ramp_Table, Draw_Menu_Demo_
; Squares, Set_Menu_Demo_Attrs (below).
.def	MENU_RAMP_VRAM					= $2E000	; 256-byte ascending 0..255 pixel-source table
.def	MENU_RAMP_BANK					= MENU_RAMP_VRAM / $1000	; = $2E ("free" bank)
.def	MENU_DEMO_SQUARE				= 16		; one ramp square is 16x16 px
.def	MENU_DEMO_ROW_TOP				= 0			; first row of the top squares
.def	MENU_DEMO_ROW_BOT				= MENU_DEMO_ROW_TOP+MENU_DEMO_SQUARE+1	; = 19, first row of the bottom squares
.def	MENU_DEMO_COL_LEFT				= 0			; left-edge block, x
.def	MENU_DEMO_COL_RIGHT				= MENU_BANNER_PITCH-(MENU_DEMO_SQUARE*2)	; = 288, right-edge block, x
.def	MENU_ATTR_ROW_BYTES				= 160		; expanded attribute map stride (40 cells x 4 bytes)
; The 4 demo block origins (top-left pixel of each block's TL square) -
; Menu_Demo_Dest_Table (below) adds MENU_DEMO_SQUARE to reach each block's TR/BR square.
.def	MENU_DEMO_ADDR_L_TOP			= MENU_BANNER_VRAM+(MENU_DEMO_ROW_TOP*MENU_BANNER_PITCH)+MENU_DEMO_COL_LEFT
.def	MENU_DEMO_ADDR_L_BOT			= MENU_BANNER_VRAM+(MENU_DEMO_ROW_BOT*MENU_BANNER_PITCH)+MENU_DEMO_COL_LEFT
.def	MENU_DEMO_ADDR_R_TOP			= MENU_BANNER_VRAM+(MENU_DEMO_ROW_TOP*MENU_BANNER_PITCH)+MENU_DEMO_COL_RIGHT
.def	MENU_DEMO_ADDR_R_BOT			= MENU_BANNER_VRAM+(MENU_DEMO_ROW_BOT*MENU_BANNER_PITCH)+MENU_DEMO_COL_RIGHT

; P (Pal) preview overlay: reuses the menu banner's ramp-square source
; (MENU_RAMP_VRAM) blitted 4x into the image framebuffer at 7x zoom
; (112x112px/square) as one non-mirrored 2x2 grid (TL=pal0, TR=pal1,
; BL=pal2, BR=pal3), centered on the 320x239 visible image screen.  See
; Selector_Handle_P (ui.asm), Fill_Pal_Preview_Cmap, Draw_Pal_Preview_Squares.
.def	PAL_PREVIEW_VRAM				= $001000	; image framebuffer (same target Load_Image's .RAW uses)
.def	PAL_PREVIEW_PITCH				= MENU_BANNER_PITCH	; = 320, same screen pitch
.def	PAL_PREVIEW_ZOOM				= 7			; 7x7 zoom -> 112x112px/square
.def	PAL_PREVIEW_SQUARE				= MENU_DEMO_SQUARE*PAL_PREVIEW_ZOOM	; = 112
.def	PAL_PREVIEW_VIS_ROWS			= 239		; visible scanlines (XDL_Image_* chains 239, not the 240-row buffer height)
.def	PAL_PREVIEW_TOP_ROW				= (PAL_PREVIEW_VIS_ROWS-(PAL_PREVIEW_SQUARE*2))/2	; = 7
.def	PAL_PREVIEW_BOT_ROW				= PAL_PREVIEW_TOP_ROW+PAL_PREVIEW_SQUARE			; = 119
.def	PAL_PREVIEW_LEFT_COL			= (320-(PAL_PREVIEW_SQUARE*2))/2	; = 48
.def	PAL_PREVIEW_RIGHT_COL			= PAL_PREVIEW_LEFT_COL+PAL_PREVIEW_SQUARE			; = 160
; 4 destination pixel addresses (framebuffer) - Pal_Preview_Dest_Table (below).
.def	PAL_PREVIEW_ADDR_TL				= PAL_PREVIEW_VRAM+(PAL_PREVIEW_TOP_ROW*PAL_PREVIEW_PITCH)+PAL_PREVIEW_LEFT_COL
.def	PAL_PREVIEW_ADDR_TR				= PAL_PREVIEW_VRAM+(PAL_PREVIEW_TOP_ROW*PAL_PREVIEW_PITCH)+PAL_PREVIEW_RIGHT_COL
.def	PAL_PREVIEW_ADDR_BL				= PAL_PREVIEW_VRAM+(PAL_PREVIEW_BOT_ROW*PAL_PREVIEW_PITCH)+PAL_PREVIEW_LEFT_COL
.def	PAL_PREVIEW_ADDR_BR				= PAL_PREVIEW_VRAM+(PAL_PREVIEW_BOT_ROW*PAL_PREVIEW_PITCH)+PAL_PREVIEW_RIGHT_COL
; CRAM_Buffer (1 byte/cell, 40 cells/row scratch at $14000) cell addresses for
; the attribute fills - TL needs no fill (Clear_Screen already zeroed the
; whole buffer, and palette 0 = $00 is the zero default).
.def	CRAM_BUFFER_VRAM				= $14000
.def	CRAM_BUFFER_ROW_BYTES			= 40
.def	PAL_PREVIEW_CELL_LEFT			= PAL_PREVIEW_LEFT_COL/8	; = 6
.def	PAL_PREVIEW_CELL_RIGHT			= PAL_PREVIEW_RIGHT_COL/8	; = 20
.def	PAL_PREVIEW_CELL_W				= PAL_PREVIEW_SQUARE/8		; = 14 cells wide
.def	PAL_PREVIEW_CMAP_TR				= CRAM_BUFFER_VRAM+(PAL_PREVIEW_TOP_ROW*CRAM_BUFFER_ROW_BYTES)+PAL_PREVIEW_CELL_RIGHT
.def	PAL_PREVIEW_CMAP_BL				= CRAM_BUFFER_VRAM+(PAL_PREVIEW_BOT_ROW*CRAM_BUFFER_ROW_BYTES)+PAL_PREVIEW_CELL_LEFT
.def	PAL_PREVIEW_CMAP_BR				= CRAM_BUFFER_VRAM+(PAL_PREVIEW_BOT_ROW*CRAM_BUFFER_ROW_BYTES)+PAL_PREVIEW_CELL_RIGHT

; NFO display buffer: the <name>.NFO file, loaded verbatim by Info_Load.  The
; converter emits it as this exact byte image of the text screen - fixed
; 160-byte line records of 80 {glyph,attr} cell pairs (attr $07), no
; terminators, one all-$00 record marking end-of-text.  Info_Draw blits an
; NFO_VISROWS window of it (source = NFO_BUF_VRAM + Nfo_Top*TEXT_PITCH) straight
; onto the text screen with BLT_NFO_DRAW - one plain rect copy, no reformat.
.def	NFO_BUF_VRAM					= $25000	; banks $25-$29 (5 * 4K = 20480 = 128 * 160)
.def	NFO_BUF_BANK					= NFO_BUF_VRAM / $1000	; = $25  (LoadData target)

; Selector status-line description cache.  One NFO_NAME_SLOT-byte slot per
; image ordinal, filled by Nfo_Name_LoadManifest from D:IMAGES.LST on every
; Rescan_Images (the converter writes that file - 8-byte key + description per
; record).  Slot byte 0: $00 = no name, >=$20 = a NUL-terminated name.  128
; divides 4K so no slot straddles a bank; 255*128 = $7F80 -> banks $37-$3E.
; Nfo_Name_ClearCache (blitter) wipes it just before each refill.
.def	NFO_NAME_VRAM					= $37000
.def	NFO_NAME_BANK					= NFO_NAME_VRAM / $1000	; = $37
.def	NFO_NAME_SLOT					= 128		; bytes per image slot
.def	NFO_NAME_CAP						= 75		; chars shown on the status line
														; ("Src: " + 75 = 80 cols; = the
														; converter's DESC_CAP)

; Save-under text window (Text_Window_Save/Restore/Frame in text80.asm).  The
; covered {glyph,attr} rectangle is blit-copied here at screen pitch (160) and
; blitted back on close.  $2F000 sits above the NFO buffer + its free tail.
.def	WIN_SAVE_VRAM					= $2F000
; Drive picker (UI_Mode 3) geometry - a small overlay of "D:" + "D1:".."D8:".
.def	DRIVE_WIN_ROW					= 6
.def	DRIVE_WIN_COL					= 30
.def	DRIVE_WIN_W						= 12		; cells wide  (border + "  Dn:  ")
.def	DRIVE_WIN_H						= 13		; rows        (border + title + 9 + border)

; Quit-confirm popup (UI_Mode 5) - "Are You Sure To Quit" + boxed Y / N buttons
; (Sel_Key_Quit / Quit_Draw, ui.asm), Selector only.
.def	QUIT_WIN_ROW					= 8
.def	QUIT_WIN_COL					= 28		; centred: (80 - QUIT_WIN_W) / 2
.def	QUIT_WIN_W						= 24		; cells wide  (border + " Are You Sure To Quit " + border)
.def	QUIT_WIN_H						= 6		; rows        (border + question + 3-row buttons + border)
.def	QUIT_BTN_W						= 5		; Y / N button boxes, 5 x 3 cells
.def	QUIT_BTN_Y_COL					= QUIT_WIN_COL+6	; buttons centred, 2 cells apart
.def	QUIT_BTN_N_COL					= QUIT_WIN_COL+13

; BCB field byte offsets
.def	Src_Adr0						= $00
.def	Src_Adr1						= $01
.def	Src_Adr2						= $02
.def	Dest_Adr0						= $06
.def	Dest_Adr1						= $07
.def	Dest_Adr2						= $08
.def	Dest_Step_Y0					= $09	; Destination step y, low byte
.def	Dest_Step_Y1					= $0A	; Destination step y, high bits
.def	Blt_W0							= $0C	; Width-1  low byte
.def	Blt_W1							= $0D	; Width-1  bit 8
.def	Blt_H							= $0E	; Height-1
.def	Blt_And							= $0F	; And mask (0 = constant source)
.def	Blt_Xor							= $10	; Xor mask (= fill value when And = 0)
.def	Blt_Zoom						= $12	; X/Y zoom (bits 0-2=ZOOMX, 4-6=ZOOMY; factor = field+1)
.def	Blt_Ctrl						= $14

; Temp debug stuff
.def	V_0								= $10	; 0 (Screen code used for Version in loading screen)
.def	V_1								= $12	; 2 (Screen code used for Version in loading screen)
.def	V_2								= $10	; 0 (Screen code used for Version in loading screen)
.def	V_3								= $00	; 61=a (Screen code used for Version in loading screen)

;-----------------------------------------------------------------------------
; VBXE Helpers
;-----------------------------------------------------------------------------
	org LOAD_ADDRESS
.pages 3								; DO NOT go past $3300
	icl 'fileio.lib'
	icl 'vbxe_min.asm'					; Use my VBXE_SetPalette2 to load linear palete

;-----------------------------------------------------------------------------
; Clean up and exit
;-----------------------------------------------------------------------------
Cleanup_Exit
	lda #$00
	sta SDMCTL

	jsr Restore_Palette0

	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL
	vbsta VBXE_VIDEO_CONTROL			; Disable XDL

	lda LMARGIN_OLD
	sta LMARGIN							; Restore LMARGIN

	lda DOSINIL_OLD
	sta DOSINI
	lda DOSINIH_OLD
	sta DOSINI + 1						; Restore DOSINI

	lda #$FF
	sta CH								; Clear last key pressed

	lda SDMCTL_OLD
	sta SDMCTL							; Restore SDMCTL

	jsr SDX_Console_Restore				; Re-enable the SDX soft console if it was up at startup

	jmp (DOSVEC)						; Return to DOS

Wait_For_Key_Exit
	lda #$FF
	sta CH								; Clear last key pressed
Wait_For_Key_Exit_L1
	lda CH
	cmp #$FF
	beq Wait_For_Key_Exit_L1			; Wait for Key Press
	rts									; Exit on  Key Press

;-----------------------------------------------------------------------------
; Restores VBXE Palette 0 based on NTSC/PAL test.
; MUST stay in this resident block: Cleanup_Exit calls it, and Cleanup_Exit is
; reached from the init-time abort paths (no images / VBXE not found) while the
; main segment is not yet loaded.
;-----------------------------------------------------------------------------
Restore_Palette0
	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

	lda Video_Flag						; 0 = PAL, 1 = NTSC
	bne Restore_Palette0_Setup_NTSC
Restore_Palette0_Setup_PAL
	lda <(VBXE_WINDOW + $0500)
	sta Y_Register
	lda >(VBXE_WINDOW + $0500)			; PAL_Palette = $00500 - $006FF
	sta Y_Register + $01
	jmp Restore_Palette0_SetPalette

Restore_Palette0_Setup_NTSC
	lda <(VBXE_WINDOW + $0200)
	sta Y_Register
	lda >(VBXE_WINDOW + $0200)			; NTSC_Palette = $00200 - $004FF
	sta Y_Register + $01

Restore_Palette0_SetPalette
	lda #$00							; Set Palette 0
	jsr VBXE_SetPalette2

Restore_Palette0_Done
	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL

	rts

; SpartaDOS X 40/80-column soft-console control (lives in the always-resident
; page-3 block so Step_1's ini-time call resolves to loaded code)
	icl 'sdx_con.asm'
.endpg

; Multi-stage loader & program initialization code begins here
	icl 'init_vbxe.asm'

	org LOAD_ADDRESS + $300				; Libraries live above

;-----------------------------------------------------------------------------
; Main loop
;-----------------------------------------------------------------------------
start
; Initialization code can go here
	jsr Text_Init						; Build the 80-column text screen (text80.asm)
	jsr Load_Menu_Banner_Raw			; One-time load of the static banner pixel data
	jsr Build_Menu_Ramp_Table			; One-time build of the palette-demo overlay's ramp square
	jsr Draw_Menu_Demo_Squares			; ...blit it into the banner's 8 demo squares...
	jsr Set_Menu_Demo_Attrs			; ...and set their attribute-map cells to the right palette

	lda #$00
	sta Scan_Drive						; Default scan location = "D:" (current drive)
	sta Scan_Path						; No subdirectory
	sta Font_Sel						; Start on the CGA font (XDL_MainMenu CHBASE = $44)
	lda #$05
	sta Slide_Secs						; Default slideshow delay, seconds

	lda #$00
	sta SDMCTL							; Turn ANTIC DMA off - VBXE owns the display

	lda #%00000011						; XDL,XCOLOR Enabled and transparent color index 0
	vbsta VBXE_VIDEO_CONTROL

	lda #$FF							; Must set priority when using Attribute Map
	vbsta VBXE_P0						; because VBXE defaults P0-P3 to #$00 on power-up

	jsr Text_Activate					; show the text XDL now (Rescan_Images can be slow)

	jsr Rescan_Images					; Scan Scan_Drive/Scan_Path, sort the list
	jsr Enter_Selector					; Show the file selector

main
; All done - now loop forever
	lda #$00
	sta ATRACT							; Disable Attract Mode

	jsr Wait_For_Sync					; Wait for VSYNC - this calls keyboard handler
	jsr Slideshow_Tick					; Advance the slideshow, if one is running
	jmp main

; Set RUN Vector
	run start

;-----------------------------------------------------------------------------
; END OF CODE
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Subroutines BEGIN
;-----------------------------------------------------------------------------
;-----------------------------------------------------------------------------
; Wait For VSync (locks to the refresh rate, PAL=50Hz, NTSC=60Hz)  Thanks tebe
;-----------------------------------------------------------------------------
Wait_For_Sync							; Hold until VCOUNT == 0
	bit VCOUNT
	bmi *-3
	bit VCOUNT
	bpl *-3

	jsr Handle_Keys						; Take care of user input

	rts									; Else return to caller

;-----------------------------------------------------------------------------
; Setup_Cmap1 - Sets byte 4 for all cmap entries via blitter
;-----------------------------------------------------------------------------
Setup_Cmap1
	lda #BLT_SETUP_CMAP_1-BLT_CLEAR
	vbsta VBXE_BL_ADR0					; Setup the blitter for memory fill operation
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
	lda #$00
Setup_Cmap1_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Setup_Cmap1_L1					; Wait for blitter to finish
	lda #$01
	vbsta VBXE_BLITTER_START			; Start the blit
	rts

;-----------------------------------------------------------------------------
; Clear_Screen - Clears a contiguous 128kB block of VBXE RAM
;-----------------------------------------------------------------------------
Clear_Screen
	lda #BLT_CLEAR_SCREEN-BLT_CLEAR
	vbsta VBXE_BL_ADR0					; Setup the blitter for memory fill operation
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
	lda #$00
Clear_Screen_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Clear_Screen_L1					; Wait for blitter to finish
	lda #$01
	vbsta VBXE_BLITTER_START			; Start the blit
	rts

;-----------------------------------------------------------------------------
; Load_Image_Palette - read just the .PAL block (the first one) of File_Index's
; .V1K and set all 4 hardware palette registers.  File_Index must be set before
; calling.  Used by Selector_Handle_P (P-preview, ui.asm), which must not touch
; the framebuffer or CRAM.
;-----------------------------------------------------------------------------
Load_Image_Palette
	lda #$00							; ext 0 = .V1K
	jsr Build_Filename
	jsr Image_Open
	bcs Load_Image_Palette_Done			; OPEN failed - registers left as they were
	jsr Image_Read_Pal
	php
	jsr Image_Close
	plp
	bcs Load_Image_Palette_Done			; short read - don't push a half palette
	jmp Apply_Image_Palette
Load_Image_Palette_Done
	rts

;-----------------------------------------------------------------------------
; Apply_Image_Palette - push the 4 x 768-byte palettes at $21000 (the .V1K's
; .PAL block) into hardware palette registers 0-3.
;-----------------------------------------------------------------------------
Apply_Image_Palette
	lda #V1K_PAL_BANK | MEMAC_GLOBAL_ENABLE	; Bank $21 VBXE Window Enabled
	vbsta VBXE_MA_BSEL
	lda <(VBXE_WINDOW + $0000)
	sta Y_Register
	lda >(VBXE_WINDOW + $0000)
	sta Y_Register + $01
	lda #$00							; Set Palette 0
	jsr VBXE_SetPalette2

	lda <(VBXE_WINDOW + $0300)
	sta Y_Register
	lda >(VBXE_WINDOW + $0300)
	sta Y_Register + $01
	lda #$01							; Set Palette 1
	jsr VBXE_SetPalette2

	lda <(VBXE_WINDOW + $0600)
	sta Y_Register
	lda >(VBXE_WINDOW + $0600)
	sta Y_Register + $01
	lda #$02							; Set Palette 2
	jsr VBXE_SetPalette2

	lda <(VBXE_WINDOW + $0900)
	sta Y_Register
	lda >(VBXE_WINDOW + $0900)
	sta Y_Register + $01
	lda #$03							; Set Palette 3
	jsr VBXE_SetPalette2
	rts

;-----------------------------------------------------------------------------
; Load_Image
; File_Index must be set before calling this!  No range checking is done!
; One OPEN of D:<name>.V1K, three sequential block reads:
;   .PAL block -> $21000, pushed to palette registers 0-3
;   .MAP block -> $14000, blitter-expanded to $17000 by Setup_Cmap1
;   .RAW block -> $01000 framebuffer
; A missing or short file stops at the failing block and closes the IOCB.
;-----------------------------------------------------------------------------
Load_Image
	lda #$00							; ext 0 = .V1K
	jsr Build_Filename
	jsr Image_Open
	bcs Load_Image_Done					; OPEN failed - nothing to close

	jsr Image_Read_Pal
	bcs Load_Image_Close
	jsr Apply_Image_Palette

	lda #V1K_MAP_BANK					; Attribute Colour Map -> $14000
	ldx #V1K_MAP_LEN / $1000
	ldy #<[V1K_MAP_LEN & $0FFF]
	sty Seg_Tail
	ldy #>[V1K_MAP_LEN & $0FFF]
	sty Seg_Tail + $01
	jsr Image_Read_Segment
	bcs Load_Image_Close
	jsr Setup_Cmap1						; Expand the data out to $17000

	lda #V1K_RAW_BANK					; Image pixels -> $01000
	ldx #V1K_RAW_LEN / $1000
	ldy #<[V1K_RAW_LEN & $0FFF]
	sty Seg_Tail
	ldy #>[V1K_RAW_LEN & $0FFF]
	sty Seg_Tail + $01
	jsr Image_Read_Segment

Load_Image_Close
	jsr Image_Close

Load_Image_Done
	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL

	rts

;-----------------------------------------------------------------------------
; Image_Read_Pal - read the .V1K's leading .PAL block into $21000.
;  Out: C=1 on a read error / short file.
;-----------------------------------------------------------------------------
Image_Read_Pal
	lda #V1K_PAL_BANK
	ldx #V1K_PAL_LEN / $1000
	ldy #<[V1K_PAL_LEN & $0FFF]
	sty Seg_Tail
	ldy #>[V1K_PAL_LEN & $0FFF]
	sty Seg_Tail + $01
	jmp Image_Read_Segment

;-----------------------------------------------------------------------------
; Image_Open - OPEN FileNamePtr for read on the first free IOCB (the same
; sequence LoadData uses, but the file stays open across several block reads).
;  Out: C=0 and Load_IOCB = IOCB offset, or C=1 (no IOCB / OPEN failed - the
;       IOCB is closed again so it doesn't leak).
;-----------------------------------------------------------------------------
Image_Open
	jsr Find_First_IOCB
	cpy #$01
	bne Image_Open_Fail					; no free IOCB
	stx Load_IOCB
	lda #CIO_read
	sta ICAX1,x
	lda #$00
	sta ICAX2,x
	lda #CIO_open
	sta ICCOM,x
	lda FileNamePtr
	sta ICBAL,x
	lda FileNamePtr + $01
	sta ICBAH,x
	jsr CIOV
	bmi Image_Open_Close
	clc
	rts
Image_Open_Close
	jsr Image_Close
Image_Open_Fail
	sec
	rts

;-----------------------------------------------------------------------------
; Image_Read_Segment - read one fixed-size block of the open .V1K into VRAM
; through the 4K MEMAC window, 4K at a time, then the partial tail.
;  In:  A = first VBXE bank, X = full 4K chunks, Seg_Tail = tail bytes (0 ok)
;  Out: C=1 on any CIO error (including EOF before the block is complete)
;-----------------------------------------------------------------------------
Image_Read_Segment
	sta Seg_Bank
	stx Seg_Chunks
Image_Read_Segment_L1
	lda Seg_Chunks
	beq Image_Read_Segment_Tail
	lda #<VBXE_WINDOW_SIZE_4k
	ldy #>VBXE_WINDOW_SIZE_4k
	jsr Image_Read_Chunk
	bcs Image_Read_Segment_Done
	dec Seg_Chunks
	jmp Image_Read_Segment_L1

Image_Read_Segment_Tail
	lda Seg_Tail
	ora Seg_Tail + $01
	beq Image_Read_Segment_OK			; no partial chunk
	lda Seg_Tail
	ldy Seg_Tail + $01
	jmp Image_Read_Chunk

Image_Read_Segment_OK
	clc
Image_Read_Segment_Done
	rts

; Map Seg_Bank at VBXE_WINDOW and GET A/Y bytes into it; Seg_Bank++ after.
; C=1 on a CIO error.
Image_Read_Chunk
	ldx Load_IOCB
	sta ICBLL,x
	tya
	sta ICBLH,x							; length stored before vbsta clobbers Y
	lda Seg_Bank
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #CIO_getdata
	sta ICCOM,x
	lda #<VBXE_WINDOW
	sta ICBAL,x
	lda #>VBXE_WINDOW
	sta ICBAH,x
	jsr CIOV
	bmi Image_Read_Chunk_Err
	inc Seg_Bank
	clc
	rts
Image_Read_Chunk_Err
	sec
	rts

;-----------------------------------------------------------------------------
; Image_Close - unmap the MEMAC window and CLOSE Load_IOCB.  Preserves nothing.
;-----------------------------------------------------------------------------
Image_Close
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	ldx Load_IOCB
	lda #CIO_close
	sta ICCOM,x
	jmp CIOV

;-----------------------------------------------------------------------------
; Load_Menu_Banner_Raw - boot-time load of the static menu banner pixel data
; (D:MENU.RAW - the logo) into dedicated, resident VRAM - never touched by Load_Image,
; and never reloaded from disk again after this one call, since the banner
; never changes at runtime.  Blank-fills any banner target whose file is
; missing/fails so cold-boot VRAM garbage is never shown.  The separator has
; no disk file - its 160-byte pattern table is assembly-embedded straight into
; MENU_SEP_VRAM at load time (Load_Menu_Sep, init_vbxe.asm).  The banner's palette (registers 1-3) is no longer a disk
; asset - see Load_Menu_Ramps (init_vbxe.asm), assembly-embedded directly into
; MENU_BANNER_PAL_VRAM.  Called once from start:, before the first
; Enter_Selector.
;-----------------------------------------------------------------------------
Load_Menu_Banner_Raw
; The ANTIC loading screen is still up (start: turns DMA off afterwards), so
; this load reports on it like the init stages: message on row 3, then the
; 8th stage's progress dots.  Reg1 (the init stages' dot pointer) doesn't
; survive Text_Init, so the dots go at the fixed position after the 7 init
; stages.  There is no MENU.MAP: the banner is all palette 0, and its
; attribute map (MENU_BANNER_MAP_VRAM) is already all zeros from the boot-time
; clear_vbxe - Set_Menu_Demo_Attrs sets just the ramp squares' cells.
	lda SAVMSC
	sta Ptr_Lo
	lda SAVMSC+1
	sta Ptr_Hi
	ldy #LOAD_MSG_ROW3
	ldx #$00
Load_Menu_Banner_Msg_L1
	lda Load_Menu_Banner_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Load_Menu_Banner_Msg_L1

	lda #<Menu_Banner_Raw_Name
	sta FileNamePtr
	lda #>Menu_Banner_Raw_Name
	sta FileNamePtr + $01
	lda #MENU_BANNER_BANK
	sta BankIndex
	jsr LoadData
	lda LoadStatus
	bne Load_Menu_Banner_Raw_Sep		; loaded OK
	jsr Menu_Banner_Blank				; OPEN/load failed - blank the banner band

Load_Menu_Banner_Raw_Sep
; Progress dots - re-read SAVMSC, since LoadData doesn't preserve Ptr_Lo/Hi
	lda SAVMSC
	sta Ptr_Lo
	lda SAVMSC+1
	sta Ptr_Hi
	ldy #LOAD_DOTS_START + (7 * NUM_DOTS)
	lda #$54							; Screen RAM code for Ctrl+T
	ldx #NUM_DOTS						; Number of dots to write
Load_Menu_Banner_Dots_L1
	sta (Ptr_Lo),y
	iny
	dex
	bne Load_Menu_Banner_Dots_L1

	rts									; The separator is already in VRAM (Load_Menu_Sep).
										; Apply_Menu_Banner_Palette isn't called here -
										; Enter_Selector always calls it before the first frame

Load_Menu_Banner_Message
	.sb 'Loading menu logo MENU.RAW        '

;-----------------------------------------------------------------------------
; Apply_Menu_Banner_Palette - push MENU_BANNER_PAL_VRAM's resident bytes into
; hardware palette registers 1-3.  No disk access, no LoadData, no IOCB - a
; cheap in-VRAM-to-register copy only.  Register 0 is never touched (reserved
; for text).  Called once at boot (above) and from every Enter_Selector
; (ui.asm), since Load_Image overwrites registers 1-3 for every real image
; viewed in between and there is no way to avoid that hardware-register
; refresh - VBXE has exactly 4 palette registers total (FX manual, "RGB
; PALETTE MODIFICATION") and there is no per-XDL copy of them.
;-----------------------------------------------------------------------------
Apply_Menu_Banner_Palette
	lda #(MENU_BANNER_PAL_VRAM / $1000) | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda <(VBXE_WINDOW + $0300)
	sta Y_Register
	lda >(VBXE_WINDOW + $0300)
	sta Y_Register + $01
	lda #$01							; Set Palette 1
	jsr VBXE_SetPalette2

	lda <(VBXE_WINDOW + $0600)
	sta Y_Register
	lda >(VBXE_WINDOW + $0600)
	sta Y_Register + $01
	lda #$02							; Set Palette 2
	jsr VBXE_SetPalette2

	lda <(VBXE_WINDOW + $0900)
	sta Y_Register
	lda >(VBXE_WINDOW + $0900)
	sta Y_Register + $01
	lda #$03							; Set Palette 3
	jsr VBXE_SetPalette2

	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

;-----------------------------------------------------------------------------
; Build_Menu_Ramp_Table - boot-time build of the palette-demo overlay's 256-
; byte ascending pixel-source table (MENU_RAMP_VRAM = $2E000, bank $2E, the
; last free VRAM bank).  BLT_MENU_DEMO_SQUARE reads it as a flat 16x16 block
; (source step y = 16).  Called once from start:, after Load_Menu_Banner_Raw.
;-----------------------------------------------------------------------------
Build_Menu_Ramp_Table
	lda #MENU_RAMP_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	ldx #$00
Build_Menu_Ramp_Table_L1
	txa
	sta VBXE_WINDOW,x
	inx
	bne Build_Menu_Ramp_Table_L1
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

; 8 destination addresses for BLT_MENU_DEMO_SQUARE, in the order
; Draw_Menu_Demo_Squares steps through them: TL/TR/BL/BR at the left edge,
; then TL/TR/BL/BR at the right edge (pal 0/1/2/3 respectively - same
; assignment at both edges).
Menu_Demo_Dest_Table
	dta <MENU_DEMO_ADDR_L_TOP,>MENU_DEMO_ADDR_L_TOP,MENU_DEMO_ADDR_L_TOP>>16									; TL, left  (pal 0)
	dta <[MENU_DEMO_ADDR_L_TOP+MENU_DEMO_SQUARE],>[MENU_DEMO_ADDR_L_TOP+MENU_DEMO_SQUARE],[MENU_DEMO_ADDR_L_TOP+MENU_DEMO_SQUARE]>>16	; TR, left  (pal 1)
	dta <MENU_DEMO_ADDR_L_BOT,>MENU_DEMO_ADDR_L_BOT,MENU_DEMO_ADDR_L_BOT>>16									; BL, left  (pal 2)
	dta <[MENU_DEMO_ADDR_L_BOT+MENU_DEMO_SQUARE],>[MENU_DEMO_ADDR_L_BOT+MENU_DEMO_SQUARE],[MENU_DEMO_ADDR_L_BOT+MENU_DEMO_SQUARE]>>16	; BR, left  (pal 3)
	dta <MENU_DEMO_ADDR_R_TOP,>MENU_DEMO_ADDR_R_TOP,MENU_DEMO_ADDR_R_TOP>>16									; TL, right (pal 0)
	dta <[MENU_DEMO_ADDR_R_TOP+MENU_DEMO_SQUARE],>[MENU_DEMO_ADDR_R_TOP+MENU_DEMO_SQUARE],[MENU_DEMO_ADDR_R_TOP+MENU_DEMO_SQUARE]>>16	; TR, right (pal 1)
	dta <MENU_DEMO_ADDR_R_BOT,>MENU_DEMO_ADDR_R_BOT,MENU_DEMO_ADDR_R_BOT>>16									; BL, right (pal 2)
	dta <[MENU_DEMO_ADDR_R_BOT+MENU_DEMO_SQUARE],>[MENU_DEMO_ADDR_R_BOT+MENU_DEMO_SQUARE],[MENU_DEMO_ADDR_R_BOT+MENU_DEMO_SQUARE]>>16	; BR, right (pal 3)

;-----------------------------------------------------------------------------
; Draw_Menu_Demo_Squares - patch BLT_MENU_DEMO_SQUARE's destination address
; from Menu_Demo_Dest_Table and kick it 8 times (2 edges x 4 quadrants) -
; same patch/wait/kick idiom as Info_Draw (BLT_NFO_DRAW) and Text_Window_
; Save/Restore (BLT_TEXT_RECT).  Called once from start:, after Build_Menu_
; Ramp_Table and Load_Menu_Banner_Raw.
;-----------------------------------------------------------------------------
Draw_Menu_Demo_Squares
	ldx #$00
Draw_Menu_Demo_Squares_L1
	lda #MEMAC_GLOBAL_ENABLE			; map VBXE bank $00 -> $2000 window (patch the BCB)
	vbsta VBXE_MA_BSEL
	lda Menu_Demo_Dest_Table,x
	sta BLT_MENU_DEMO_SQUARE + Dest_Adr0
	lda Menu_Demo_Dest_Table+1,x
	sta BLT_MENU_DEMO_SQUARE + Dest_Adr1
	lda Menu_Demo_Dest_Table+2,x
	sta BLT_MENU_DEMO_SQUARE + Dest_Adr2
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL

	lda #BLT_MENU_DEMO_SQUARE-BLT_CLEAR
	vbsta VBXE_BL_ADR0
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Draw_Menu_Demo_Squares_Wait1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Draw_Menu_Demo_Squares_Wait1		; wait for any prior blit to finish
	lda #$01
	vbsta VBXE_BLITTER_START
Draw_Menu_Demo_Squares_Wait2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Draw_Menu_Demo_Squares_Wait2		; wait for this kick to finish

	txa
	clc
	adc #$03
	tax
	cpx #$18							; 8 entries * 3 bytes = 24
	bne Draw_Menu_Demo_Squares_L1
	rts

; Attribute-cell byte offsets (within a 160-byte expanded map row) for the 8
; columns the demo overlay covers - cell*4+3 (the real attribute byte; the
; other 3 bytes/cell are always zero - the whole map is zeroed at boot by
; clear_vbxe).  Left-edge block = cells 0-3 (pixels 0-31); right-edge block = cells
; 36-39 (pixels 288-319, since MENU_BANNER_PITCH/8 = 40 cells/row).
Menu_Demo_Attr_Cols
	dta 3,7,11,15,147,151,155,159
; Same column order: TL/TR pal ids (<<4), left edge then right edge. Right
; edge is horizontally mirrored (pal 1,0 instead of 0,1) so the right-hand
; copy reads as a flipped reflection of the left-hand one; the underlying
; pixel data (Menu_Demo_Dest_Table) is untouched, only which palette
; register each cell points at changes.
Menu_Demo_Attr_Top_Vals
	dta $00,$00,$10,$10,$10,$10,$00,$00
; Same column order: BL/BR pal ids (<<4), left edge then right edge (mirrored:
; pal 3,2 instead of 2,3 - see note above).
Menu_Demo_Attr_Bot_Vals
	dta $20,$20,$30,$30,$30,$30,$20,$20

;-----------------------------------------------------------------------------
; Set_Menu_Demo_Attrs - poke palette_id<<4 into the expanded attribute map's
; (MENU_BANNER_MAP_VRAM) cell covering each of the demo overlay's 8 squares,
; for all MENU_DEMO_SQUARE rows each square spans.  Plain CPU loop (no
; blitter - a small, one-time boot fixup; every other cell stays palette 0
; from the boot-time clear).  MENU_BANNER_MAP_VRAM is exactly bank-
; aligned, so a running byte offset from its start splits cleanly into a
; bank number (offset's upper nibbles) and a window address (offset's low
; 12 bits) - recomputed every byte, since the covered rows straddle the
; $35xxx/$36xxx bank boundary partway through (row 25 already crosses it).
; Called once from start:, after Load_Menu_Banner_Raw.
;-----------------------------------------------------------------------------
Set_Menu_Demo_Attrs
	lda #<[MENU_DEMO_ROW_TOP*MENU_ATTR_ROW_BYTES]
	sta Reg1
	lda #>[MENU_DEMO_ROW_TOP*MENU_ATTR_ROW_BYTES]
	sta Reg2
	lda #<Menu_Demo_Attr_Top_Vals
	sta Ptr_Lo
	lda #>Menu_Demo_Attr_Top_Vals
	sta Ptr_Hi
	jsr Set_Menu_Demo_Attr_Band

	lda #<[MENU_DEMO_ROW_BOT*MENU_ATTR_ROW_BYTES]
	sta Reg1
	lda #>[MENU_DEMO_ROW_BOT*MENU_ATTR_ROW_BYTES]
	sta Reg2
	lda #<Menu_Demo_Attr_Bot_Vals
	sta Ptr_Lo
	lda #>Menu_Demo_Attr_Bot_Vals
	sta Ptr_Hi
	jsr Set_Menu_Demo_Attr_Band

	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

; Reg1/Reg2 = running row_offset (16-bit, row*MENU_ATTR_ROW_BYTES from
; MENU_BANNER_MAP_VRAM's start), advanced by MENU_ATTR_ROW_BYTES each row.
; Ptr_Lo/Hi = this band's 8-byte value table (Menu_Demo_Attr_Cols order).
; The column loop counter lives in X, not Y: vbsta/vblda clobber Y on every
; call in __VBXE_AUTO__ mode (vbxe_min.asm), and this loop calls vbsta once
; per column, so Y cannot survive across it.  Clobbers A/X/Y/Reg1-8.
Set_Menu_Demo_Attr_Band
	lda #MENU_DEMO_SQUARE
	sta Reg8							; rows remaining
Set_Menu_Demo_Attr_Band_Row
	ldx #$00
Set_Menu_Demo_Attr_Band_Col
	lda Menu_Demo_Attr_Cols,x
	clc
	adc Reg1
	sta Reg3							; total byte offset, lo
	lda #$00
	adc Reg2
	sta Reg4							; total byte offset, hi

; window address = VBXE_WINDOW + (total_offset & $0FFF)
	lda Reg4
	and #$0F
	ora #>VBXE_WINDOW
	sta Reg6							; dest ptr hi
	lda Reg3
	sta Reg5							; dest ptr lo

; bank = MENU_BANNER_MAP_VRAM/$1000 + (total_offset >> 12)
	lda Reg4
	lsr
	lsr
	lsr
	lsr
	clc
	adc #[MENU_BANNER_MAP_VRAM/$1000]
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL					; clobbers Y - X (our loop counter) survives

	txa
	tay
	lda (Ptr_Lo),y						; this column's attribute value (Y = column index)
	ldy #$00
	sta (Reg5),y						; poke it into the mapped window

	inx
	cpx #$08
	bne Set_Menu_Demo_Attr_Band_Col

	lda Reg1
	clc
	adc #<MENU_ATTR_ROW_BYTES
	sta Reg1
	lda Reg2
	adc #>MENU_ATTR_ROW_BYTES
	sta Reg2

	dec Reg8
	bne Set_Menu_Demo_Attr_Band_Row
	rts

;-----------------------------------------------------------------------------
; Fill_Pal_Preview_Cmap - stage the P-preview's 2x2 grid into CRAM_Buffer
; (TL is left at the buffer's zero default = palette 0) then expand the
; whole buffer into real CRAM via the existing Setup_Cmap1.  Called once
; from Selector_Handle_P (ui.asm).
;
; Repurposes BLT_MENU_SEP_CLEAR (bcbs.asm) rather than adding a 13th BCB -
; it was the separator's boot-time constant fill, but the separator is now a
; 160-byte table loaded straight into VRAM (Load_Menu_Sep, init_vbxe.asm), so
; this is its only user.  The 12 BCBs already in bcbs.asm exactly fill the
; $100-$1FF VBXE VRAM budget (see the memory-map comment at the top of this
; file); a 13th BCB overflowed BLT_NFO_NAME_CLEAR across the $200 boundary
; into the NTSC_Palette load and corrupted it - do not add a new BCB here.
; Its fixed Dest_Step_X (1) and And mask (0, constant source) already match;
; Dest_Step_Y0/1 and Width-1/Height-1 are patched once, up front, since they
; don't vary between the 3 kicks (only Dest_Adr/Xor do).
;-----------------------------------------------------------------------------
Fill_Pal_Preview_Cmap
	lda #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #<CRAM_BUFFER_ROW_BYTES
	sta BLT_MENU_SEP_CLEAR + Dest_Step_Y0
	lda #>CRAM_BUFFER_ROW_BYTES
	sta BLT_MENU_SEP_CLEAR + Dest_Step_Y1
	lda #<(PAL_PREVIEW_CELL_W-1)
	sta BLT_MENU_SEP_CLEAR + Blt_W0
	lda #>(PAL_PREVIEW_CELL_W-1)
	sta BLT_MENU_SEP_CLEAR + Blt_W1
	lda #PAL_PREVIEW_SQUARE-1
	sta BLT_MENU_SEP_CLEAR + Blt_H
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL

	ldx #$00
Fill_Pal_Preview_Cmap_L1
	lda #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda Pal_Preview_Cmap_Table,x
	sta BLT_MENU_SEP_CLEAR + Dest_Adr0
	lda Pal_Preview_Cmap_Table+1,x
	sta BLT_MENU_SEP_CLEAR + Dest_Adr1
	lda Pal_Preview_Cmap_Table+2,x
	sta BLT_MENU_SEP_CLEAR + Dest_Adr2
	lda Pal_Preview_Cmap_Table+3,x
	sta BLT_MENU_SEP_CLEAR + Blt_Xor
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL

	lda #BLT_MENU_SEP_CLEAR-BLT_CLEAR
	vbsta VBXE_BL_ADR0
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Fill_Pal_Preview_Cmap_Wait1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Fill_Pal_Preview_Cmap_Wait1		; wait for any prior blit to finish
	lda #$01
	vbsta VBXE_BLITTER_START
Fill_Pal_Preview_Cmap_Wait2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Fill_Pal_Preview_Cmap_Wait2		; wait for this kick to finish

	txa
	clc
	adc #$04
	tax
	cpx #$0C							; 3 entries * 4 bytes = 12
	bne Fill_Pal_Preview_Cmap_L1

	jsr Setup_Cmap1						; expand CRAM_Buffer -> real CRAM ($017000)
	rts

; {dest_adr0,1,2, xor_value} x3 - TR/BL/BR only.
Pal_Preview_Cmap_Table
	dta <PAL_PREVIEW_CMAP_TR,>PAL_PREVIEW_CMAP_TR,PAL_PREVIEW_CMAP_TR>>16,$10		; TR (pal 1)
	dta <PAL_PREVIEW_CMAP_BL,>PAL_PREVIEW_CMAP_BL,PAL_PREVIEW_CMAP_BL>>16,$20		; BL (pal 2)
	dta <PAL_PREVIEW_CMAP_BR,>PAL_PREVIEW_CMAP_BR,PAL_PREVIEW_CMAP_BR>>16,$30		; BR (pal 3)

;-----------------------------------------------------------------------------
; Draw_Pal_Preview_Squares - patch BLT_MENU_DEMO_SQUARE's destination
; address and Zoom byte, kick it 4 times (one 2x2 grid, no left/right
; mirror) to blit Build_Menu_Ramp_Table's ramp square into the image
; framebuffer at 7x zoom.  Restores Zoom to $00 afterward so the shared BCB
; is left in its original 1x state.  Called once from Selector_Handle_P
; (ui.asm), after Fill_Pal_Preview_Cmap.
;-----------------------------------------------------------------------------
Draw_Pal_Preview_Squares
	lda #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #$66							; ZOOMY=6,ZOOMX=6 -> 7x7 (PAL_PREVIEW_ZOOM)
	sta BLT_MENU_DEMO_SQUARE + Blt_Zoom
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL

	ldx #$00
Draw_Pal_Preview_Squares_L1
	lda #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda Pal_Preview_Dest_Table,x
	sta BLT_MENU_DEMO_SQUARE + Dest_Adr0
	lda Pal_Preview_Dest_Table+1,x
	sta BLT_MENU_DEMO_SQUARE + Dest_Adr1
	lda Pal_Preview_Dest_Table+2,x
	sta BLT_MENU_DEMO_SQUARE + Dest_Adr2
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL

	lda #BLT_MENU_DEMO_SQUARE-BLT_CLEAR
	vbsta VBXE_BL_ADR0
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Draw_Pal_Preview_Squares_Wait1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Draw_Pal_Preview_Squares_Wait1		; wait for any prior blit to finish
	lda #$01
	vbsta VBXE_BLITTER_START
Draw_Pal_Preview_Squares_Wait2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Draw_Pal_Preview_Squares_Wait2		; wait for this kick to finish

	txa
	clc
	adc #$03
	tax
	cpx #$0C							; 4 entries * 3 bytes = 12
	bne Draw_Pal_Preview_Squares_L1

	lda #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #$00
	sta BLT_MENU_DEMO_SQUARE + Blt_Zoom	; restore to unzoomed (1x) default
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

; 4 destination addresses for BLT_MENU_DEMO_SQUARE - one 2x2 grid, no mirror
; (unlike Menu_Demo_Dest_Table's 8 entries/2 edges).
Pal_Preview_Dest_Table
	dta <PAL_PREVIEW_ADDR_TL,>PAL_PREVIEW_ADDR_TL,PAL_PREVIEW_ADDR_TL>>16	; TL (pal 0)
	dta <PAL_PREVIEW_ADDR_TR,>PAL_PREVIEW_ADDR_TR,PAL_PREVIEW_ADDR_TR>>16	; TR (pal 1)
	dta <PAL_PREVIEW_ADDR_BL,>PAL_PREVIEW_ADDR_BL,PAL_PREVIEW_ADDR_BL>>16	; BL (pal 2)
	dta <PAL_PREVIEW_ADDR_BR,>PAL_PREVIEW_ADDR_BR,PAL_PREVIEW_ADDR_BR>>16	; BR (pal 3)

Menu_Banner_Blank
	lda #BLT_MENU_BANNER_CLEAR-BLT_CLEAR
	vbsta VBXE_BL_ADR0					; Setup the blitter for memory fill operation
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Menu_Banner_Blank_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Menu_Banner_Blank_L1			; Wait for any prior blit to finish
	lda #$01
	vbsta VBXE_BLITTER_START			; Start the fill
Menu_Banner_Blank_L2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Menu_Banner_Blank_L2			; Wait for the fill to complete
	rts

; Fixed asset filenames - the menu banner is static UI chrome, not part of the
; browsable image library, so these are NOT built via Build_Filename (which
; reads the current selection out of IMAGE_BANK).  The separator has no disk
; file - its 160-byte table is assembly-embedded (Load_Menu_Sep, init_vbxe.asm).  The
; palette has no asset file either - see Load_Menu_Ramps (init_vbxe.asm).
; Placeholder names/drive - confirm the convention with Stephen.
Menu_Banner_Raw_Name	dta c'D:MENU.RAW',0

;-----------------------------------------------------------------------------
; Handle_Keys
;-----------------------------------------------------------------------------
Handle_Keys
; Dispatch on the current UI mode - the selector, slideshow, drive picker and
; info viewer each have their own key set (ui.asm); mode 1 (image view) uses
; the set below.
	lda CH
	cmp #KEY_F							; F toggles the text font on every screen
	bne Handle_Keys_Mode
	jsr UI_Toggle_Font					; (ui.asm) - also redraws an open quit box's frame
	jmp Read_Key_Done
Handle_Keys_Mode
	lda UI_Mode
	bne Handle_Keys_NotSelector
	jmp Selector_Keys					; 0 = selector
Handle_Keys_NotSelector
	cmp #$02
	bne Handle_Keys_NotSlide
	jmp Slideshow_Keys					; 2 = slideshow
Handle_Keys_NotSlide
	cmp #$03
	bne Handle_Keys_NotFolder
	jmp Drive_Keys						; 3 = drive picker (D-key overlay)
Handle_Keys_NotFolder
	cmp #$04
	bne Handle_Keys_NotInfo
	jmp Info_Keys						; 4 = info viewer (.nfo)
Handle_Keys_NotInfo
	cmp #$05
	bne Handle_Keys_NotQuit
	jmp Quit_Confirm_Keys				; 5 = quit-confirm popup (Selector only)
Handle_Keys_NotQuit
	cmp #$06
	bne Handle_Keys_ImageView
	jmp Pal_Preview_Keys				; 6 = P-preview screen (ui.asm)
Handle_Keys_ImageView

; Q does not quit from here - only from the Selector, via a Y/N confirmation.
	lda CH
	cmp #$21							; Space - next image
	beq Handle_Space
	cmp #$34							; Backspace - previous image
	beq Handle_Backspace
	cmp #$1C							; Esc - back to the file selector
	beq Handle_Escape
	cmp #$32							; 0
	beq Handle_0
	cmp #$1F							; 1
	beq Handle_1
	cmp #$1E							; 2
	beq Handle_2
	cmp #$1A							; 3
	beq Handle_3
	cmp #$18							; 4
	beq Handle_4
Handle_Keys_Done						; No more keys to test
	jmp Read_Key_Done

Handle_Space
	jsr Clear_Screen					; Clear the VBXE RAM
	jsr Increment_Image					; Display the next image
	jmp Read_Key_Done

Handle_Backspace
	jsr Clear_Screen					; Clear the VBXE RAM
	jsr Decrement_Image					; Display the previous image
	jmp Read_Key_Done

Handle_Escape
	jsr Selector_Sync_Cursor				; highlight follows Space/BkSp navigation
	jsr Enter_Selector					; Leave the image, return to the file selector
	jmp Read_Key_Done

Handle_0
	ldx #$00
	jsr Set_Palette						; Disable Colour Map and set Palette to X register
	jmp Read_Key_Done

Handle_1
	ldx #$01
	jsr Set_Palette						; Disable Colour Map and set Palette to X register
	jmp Read_Key_Done

Handle_2
	ldx #$02
	jsr Set_Palette						; Disable Colour Map and set Palette to X register
	jmp Read_Key_Done

Handle_3
	ldx #$03
	jsr Set_Palette						; Disable Colour Map and set Palette to X register
	jmp Read_Key_Done

Handle_4
	jsr Enable_Colour_Map				; Enable Colour Map
	jmp Read_Key_Done

Read_Key_Done
	lda #$FF
	sta CH								; Clear last key pressed
	rts									; Else return to caller
Exit
; Restore the OS state Step_1 / Check_RAMTOP changed, BEFORE Cleanup_Exit runs
; SDX_Console_Restore (its XIO 32 wants the real RAMTOP back).  Lives here, not
; in the resident Cleanup_Exit, which is page-fenced below $3300 and full - the
; init-time abort paths that jmp straight to Cleanup_Exit simply skip this.
	lda CRSINH_OLD
	sta CRSINH							; Restore Cursor
	lda COLOR1_OLD						; Restore the editor colours Step_1 changed
	sta COLOR1
	lda COLOR2_OLD
	sta COLOR2
	lda COLOR4_OLD
	sta COLOR4
	lda RAMTOP_OLD						; Give the SDX soft console its top-of-RAM back
	sta RAMTOP
	sta RAMSIZ
	jmp Cleanup_Exit					; Clean up and exit (accounts for any long branch issues)

;-----------------------------------------------------------------------------
; Increment_Image - advance File_Index within the *.V1K file band
; [FileStart, ImageCount), wrapping past the last file to the first.
; No-op when the list holds no files.  (The selector list may now also carry
; ".." and directory rows below FileStart - Space/BkSp must skip those.)
;-----------------------------------------------------------------------------
Increment_Image
	lda FileStart
	cmp ImageCount
	bcs Increment_Image_Done			; no *.V1K files in the list
	ldx File_Index
	inx
	cpx ImageCount
	bcc Increment_Image_Store
	ldx FileStart						; wrap past the last file to the first
Increment_Image_Store
	stx File_Index
	jsr Load_Image
Increment_Image_Done
	rts

;-----------------------------------------------------------------------------
; Decrement_Image - step File_Index back within [FileStart, ImageCount),
; wrapping from the first file to the last.  No-op when the list holds no files.
;-----------------------------------------------------------------------------
Decrement_Image
	lda FileStart
	cmp ImageCount
	bcs Decrement_Image_Done
	ldx File_Index
	cpx FileStart
	bne Decrement_Image_Step
	ldx ImageCount						; wrap: first file -> (last file + 1)
Decrement_Image_Step
	dex
	stx File_Index
	jsr Load_Image
Decrement_Image_Done
	rts

;-----------------------------------------------------------------------------
; Set_Palette
;  X register contains Palette #
;  XDL_Image_Normal + $08 = the byte we need to change
;  XDL OV PALETTE bits 5,4 need changed (00 to 11), bit 0 always needs on
;-----------------------------------------------------------------------------
Set_Palette
	jsr Disable_Colour_Map

	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

	txa									; A contains Palette #
	asl
	asl
	asl
	asl									; Put low-nybble in high-nybble
	ora #$01							; Set bit 0
	sta VBXE_WINDOW + $1D

	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL

	rts

;-----------------------------------------------------------------------------
; Disable_Colour_Map (Point XDL to XDL_Image_Normal)
;-----------------------------------------------------------------------------
Disable_Colour_Map
	lda #$00							; Setup VBXE for displaying picture data
	vbsta VBXE_XDL_ADR2
	vbsta VBXE_XDL_ADR1
	lda #$15
	vbsta VBXE_XDL_ADR0

	rts

;-----------------------------------------------------------------------------
; Enable_Colour_Map (Point XDL to XDL_Image_Attribute)
;-----------------------------------------------------------------------------
Enable_Colour_Map
	lda #$00							; Setup VBXE for displaying picture data
	vbsta VBXE_XDL_ADR0
	vbsta VBXE_XDL_ADR2
	vbsta VBXE_XDL_ADR1

	rts

;-----------------------------------------------------------------------------
; Subroutines END
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Build_Filename
;  In:  A          = 0 -> .V1K, 1 -> .NFO
;       File_Index = image ordinal
;  Out: FileNamePtr -> Path_Buf holding
;         "D[n]:" + Scan_Path + base(<=8) + "." + ext + $00
;       IMAGE_BANK unmapped (MEMAC_GLOBAL_DISABLE) on return
;  The base name is the space-padded 8-byte record Rescan_Images stored in
;  IMAGE_BANK; copying stops at the first space.  Emit_Path_Prefix (ui.asm)
;  writes the "D[n]:" + Scan_Path part and returns X = the next Path_Buf index.
;-----------------------------------------------------------------------------
Build_Filename
	sta Reg2							; Reg2 = extension selector

; Name_Ptr = ImageNames + File_Index * 8   (16-bit; File_Index up to 254)
	lda File_Index
	sta Reg3
	lda #$00
	sta Reg4
	asl Reg3
	rol Reg4
	asl Reg3
	rol Reg4
	asl Reg3
	rol Reg4							; Reg3/Reg4 = File_Index * 8
	lda Reg3
	clc
	adc #<ImageNames
	sta Name_Ptr
	lda Reg4
	adc #>ImageNames
	sta Name_Ptr + $01

	jsr Emit_Path_Prefix				; Path_Buf = "D[n]:" + Scan_Path, X = cursor

	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL					; Map the name list into the $2000 window

	ldy #$00							; Y = read index into the 8-byte record
Build_Filename_Base
	lda (Name_Ptr),y
	cmp #' '
	beq Build_Filename_Ext				; Space -> end of base name
	sta Path_Buf,x
	inx
	iny
	cpy #$08
	bcc Build_Filename_Base

Build_Filename_Ext
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL					; Give the CPU back the $2000 window

	lda #'.'
	sta Path_Buf,x
	inx

	lda Reg2							; ext selector * 3
	sta Reg3
	asl Reg3
	clc
	adc Reg3							; A = selector * 3
	tay
	lda Ext_Table,y
	sta Path_Buf,x
	inx
	lda Ext_Table + $01,y
	sta Path_Buf,x
	inx
	lda Ext_Table + $02,y
	sta Path_Buf,x
	inx
	lda #$00
	sta Path_Buf,x						; Terminator for CIO OPEN

	lda #<Path_Buf
	sta FileNamePtr
	lda #>Path_Buf
	sta FileNamePtr + $01
	rts

Ext_Table
	dta c'V1KNFO'						; selector 0=V1K 1=NFO

;-----------------------------------------------------------------------------
; Sort_Range - in-place alphabetical selection sort of the records
; [start .. start+count) in IMAGE_BANK (8-byte space-padded, lexicographic).
;   In:  A = start index, X = count.  count < 2 -> no-op.
; Rescan_Images (ui.asm) calls it once per group (dirs, then files) so the
; ".." / dir / file grouping is preserved.  O(n^2) byte compares; trivial.
; Clobbers A/X/Y, Reg2..Reg6, Name_Ptr, Sort_Ptr, Path_Buf[0..7].
;-----------------------------------------------------------------------------
Sort_Range
	cpx #$02
	bcc Sort_Range_Done					; 0 or 1 records -> nothing to do
	sta Reg2							; Reg2 = i = start
	stx Reg3							; Reg3 = count (temp)
	clc
	adc Reg3
	sta Reg5							; Reg5 = end = start + count
	sec
	sbc #$01
	sta Reg6							; Reg6 = end - 1 (outer limit)

	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL

Sort_Range_Outer
	lda Reg2
	cmp Reg6
	bcs Sort_Range_Unmap				; i >= end-1 -> done

	sta Reg4							; m = i
	jsr Sort_SetNamePtr					; Name_Ptr = rec(m)

	lda Reg2
	clc
	adc #$01
	sta Reg3							; j = i + 1
Sort_Range_Inner
	lda Reg3
	cmp Reg5
	bcs Sort_Range_Inner_Done			; j >= end

	lda Reg3
	jsr Sort_SetSortPtr					; Sort_Ptr = rec(j)
	jsr Cmp_Records						; rec(m) : rec(j)
	bcc Sort_Range_Inner_Next			; rec(m) < rec(j) -> keep m
	beq Sort_Range_Inner_Next			; equal          -> keep m
	lda Reg3							; rec(m) > rec(j) -> new min is j
	sta Reg4
	lda Sort_Ptr
	sta Name_Ptr
	lda Sort_Ptr + $01
	sta Name_Ptr + $01
Sort_Range_Inner_Next
	inc Reg3
	jmp Sort_Range_Inner
Sort_Range_Inner_Done
	lda Reg4
	cmp Reg2
	beq Sort_Range_Outer_Next			; min already in place
	lda Reg2
	jsr Sort_SetSortPtr					; Sort_Ptr = rec(i)
	lda Reg4
	jsr Sort_SetNamePtr					; Name_Ptr = rec(m)
	jsr Swap_Records
Sort_Range_Outer_Next
	inc Reg2
	jmp Sort_Range_Outer

Sort_Range_Unmap
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
Sort_Range_Done
	rts

;-----------------------------------------------------------------------------
; Cmp_Records - lexicographic compare of the 8 bytes at (Name_Ptr) vs
; (Sort_Ptr). Returns C=0 if (Name_Ptr) < (Sort_Ptr); C=1 (and Z=1 when fully
; equal) otherwise.
;-----------------------------------------------------------------------------
Cmp_Records
	ldy #$00
Cmp_Records_L1
	lda (Name_Ptr),y
	cmp (Sort_Ptr),y
	bne Cmp_Records_Done					; C/Z set from the mismatching byte
	iny
	cpy #$08
	bcc Cmp_Records_L1					; all 8 equal -> falls out with C=1,Z=1
Cmp_Records_Done
	rts

;-----------------------------------------------------------------------------
; Swap_Records - exchange the 8-byte records at (Name_Ptr) and (Sort_Ptr),
; using Path_Buf as scratch.
;-----------------------------------------------------------------------------
Swap_Records
	ldy #$00
Swap_Records_L1
	lda (Name_Ptr),y
	sta Path_Buf,y
	lda (Sort_Ptr),y
	sta (Name_Ptr),y
	lda Path_Buf,y
	sta (Sort_Ptr),y
	iny
	cpy #$08
	bcc Swap_Records_L1
	rts

;-----------------------------------------------------------------------------
; Sort_SetNamePtr / Sort_SetSortPtr - A = record index -> set the zp pointer
; to ImageNames + index*8. Sort_IndexToOffset does the 16-bit math in Reg7/Reg8.
;-----------------------------------------------------------------------------
Sort_SetNamePtr
	jsr Sort_IndexToOffset
	lda Reg7
	sta Name_Ptr
	lda Reg8
	sta Name_Ptr + $01
	rts

Sort_SetSortPtr
	jsr Sort_IndexToOffset
	lda Reg7
	sta Sort_Ptr
	lda Reg8
	sta Sort_Ptr + $01
	rts

Sort_IndexToOffset
	sta Reg7
	lda #$00
	sta Reg8
	asl Reg7
	rol Reg8
	asl Reg7
	rol Reg8
	asl Reg7
	rol Reg8							; Reg7/Reg8 = index * 8
	lda Reg7
	clc
	adc #<ImageNames
	sta Reg7
	lda Reg8
	adc #>ImageNames
	sta Reg8
	rts

;-----------------------------------------------------------------------------
; Viewer UI (main segment)
;-----------------------------------------------------------------------------
	icl 'text80.asm'					; VBXE 80-column text screen + font + palette
	icl 'ui.asm'						; File selector, slideshow, directory scan

;-----------------------------------------------------------------------------
;
;-----------------------------------------------------------------------------
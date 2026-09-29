; Clear 496kB (leave bottom 16kB for the SVBXE.SYS driver)
; 496x16 zoom 8x8 clear blit (this takes 2 frames)
BLT_CLEAR
	dta $00,$00,$00						; Source address
	dta $00,$00							; Source step y
	dta $00								; Source step x
	dta $FF,$BF,$07						; Destination address
	dta a(-$0F80)						; Destination step y (backwards 3968 bytes) - NOTE: this equals 496 * zoom factor of 8
	dta -$01							; Destination step x (backwards	1 byte)
	dta $EF,$01							; Width-1  (495)	496 * 8 bytes wide
	dta $0F								; Height-1 (15)		 16 * 8 bytes high
	dta $00								; And mask (And mask equal to 0 so clear)
	dta $00								; Xor mask (will be filled with xor mask)
	dta $00								; Collision and mask
	dta $77								; Zoom (BLT_ZOOMY = 7, BLT_ZOOMX = 7 so 8Y*8X)
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Copy 9600 attrib bytes from $14000, placing each at every 4th dest byte from $17003
; 40 cells/row * 240 rows = 9600 bytes; dest stride 4 writes to $17003,$17007,$1700B...
; The 3 zero bytes before each data byte are left intact from BLT_SETUP_CMAP_1
BLT_SETUP_CMAP_1
	dta $00,$40,$01						; Source address ($14000)
	dta $28,$00							; Source step y = 40 (advance to next row: 40 cells * 1 byte)
	dta $01								; Source step x (1)
	dta $03,$70,$01						; Destination address ($17003)
	dta $A0,$00							; Destination step y = 160 (advance to next row: 40 cells * 4 bytes)
	dta $04								; Destination step x (4)
	dta $27,$00							; Width-1 = 39   (40 cells/row)
	dta $EF								; Height-1 = 239 (240 rows; 40*240 = 9600)
	dta $FF								; And mask ($FF - pass-through, copies zero values too)
	dta $00								; Xor mask (no inversion)
	dta $00								; Collision mask
	dta $00								; Zoom
	dta $00								; Pattern feature

; Same expansion as BLT_SETUP_CMAP_1, but for the menu banner: 40 cells/row *
; MENU_BANNER_ROWS(36) rows = 1440 source bytes, dest stride 4 starting at
; MENU_BANNER_MAP_VRAM+3 - a dedicated, resident copy (NOT the shared CRAM
; $017000), so the banner's attribute map never needs to be reloaded.  Kicked
; once, at boot, by Setup_Menu_Cmap.
BLT_SETUP_MENU_CMAP
	dta $00,$40,$01						; Source address ($14000 = CRAM_Buffer, reused as scratch)
	dta $28,$00							; Source step y = 40
	dta $01								; Source step x (1)
	dta <[MENU_BANNER_MAP_VRAM+3], >[MENU_BANNER_MAP_VRAM+3], [MENU_BANNER_MAP_VRAM+3]>>16	; Destination address
	dta $A0,$00							; Destination step y = 160 (40 cells * 4 bytes)
	dta $04								; Destination step x (4)
	dta $27,$00							; Width-1 = 39   (40 cells/row)
	dta MENU_BANNER_ROWS-1				; Height-1 = 35  (36 rows; 40*36 = 1440)
	dta $FF								; And mask ($FF - pass-through, copies zero values too)
	dta $00								; Xor mask (no inversion)
	dta $00								; Collision mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Clears the screen RAM and CMAP data ($01000 - $21FFF or 128kB)
BLT_CLEAR_SCREEN
	dta $00,$00,$00						; Source address
	dta $00,$00							; Source step y
	dta $00								; Source step x
	dta $00,$10,$00						; Destination address
	dta $00,$04							; Destination step y (1024 bytes) - NOTE: this equals 128 * zoom factor of 8
	dta $01								; Destination step x (1 byte) - NOTE: this equals 1 * zoom factor of 8
	dta $7F,$00							; Width-1  (127)	128 * 8 bytes wide
	dta $0F								; Height-1 (15)		 16 * 8 bytes high
	dta $00								; And mask (And mask equal to 0 so clear)
	dta $00								; Xor mask (will be filled with xor mask)
	dta $00								; Collision and mask
	dta $77								; Zoom (BLT_ZOOMY = 7, BLT_ZOOMX = 7 so 8Y*8X)
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Zero-fill the 80 x TEXT_ROWS VBXE text screen (TEXT_SCREEN_VRAM, TEXT_SCREEN_
; BYTES bytes - ONE contiguous buffer backing both the menu XDL's main-content
; and footer text bands).  Constant-source fast fill: And mask 0 makes the
; source a constant equal to the Xor mask and the blitter skips the source
; fetch - about 2x faster than a copy (FX manual "The Blitter and constant
; source data").  Xor $00 -> blank glyph + transparent attribute in every
; cell.  MODE 0, NEXT clear.  Kicked by Text_Clear.
BLT_CLEAR_TEXT
	dta $00,$00,$00						; Source address (unused - constant source)
	dta $00,$00							; Source step y (unused)
	dta $00								; Source step x (unused)
	dta $00,$30,$02						; Destination address ($023000 = TEXT_SCREEN_VRAM)
	dta a(TEXT_PITCH)					; Destination step y (160 - next text row)
	dta $01								; Destination step x (1)
	dta a(TEXT_PITCH-1)					; Width-1  (159 -> 160 bytes per row)
	dta TEXT_ROWS-1						; Height-1 (29 -> 30 rows)
	dta $00								; And mask (0 -> constant source)
	dta $00								; Xor mask (fill value: $00)
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Recolour a rectangular region of the text screen - floods the attribute (odd)
; bytes only (Destination step x = 2).  Constant-source fast fill (And 0).
; Text_FillColour patches Destination address, Width-1, Height-1 and Xor mask
; before each kick.
BLT_FILL_COLOUR
	dta $00,$00,$00						; Source address (unused - constant source)
	dta $00,$00							; Source step y (unused)
	dta $00								; Source step x (unused)
	dta $01,$30,$02						; Destination address ($023001; PATCHED - attr byte of cell)
	dta a(TEXT_PITCH)					; Destination step y (160 - next text row)
	dta $02								; Destination step x (2 - attribute bytes only)
	dta a(TEXT_COLS-1)					; Width-1  (79 -> 80 cells; PATCHED)
	dta TEXT_ROWS-1						; Height-1 (29; PATCHED)
	dta $00								; And mask (0 -> constant source)
	dta $00								; Xor mask (attribute value; PATCHED)
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Draw a window of the NFO display buffer (NFO_BUF_VRAM: fixed 160-byte
; {glyph,attr} line records - the same interleaved layout as the text screen)
; onto the text screen's main-content band only (TEXT_MAIN_ROWS rows - the
; footer band below it holds separate static text the NFO blit must not
; touch).  A plain rectangular copy (And $FF, MODE 0, step x = 1): the buffer
; already carries the attribute bytes, so no fill link is needed.  Info_Draw
; patches Source address (lo/mid/hi) and Height-1 before each kick; the
; destination is always the top-left of the text screen.
BLT_NFO_DRAW
	dta $00,$50,$02						; Source address ($025000 = NFO_BUF_VRAM; PATCHED)
	dta a(TEXT_PITCH)					; Source step y (160 - next line record)
	dta $01								; Source step x (1)
	dta $00,$30,$02						; Destination address ($023000 = TEXT_SCREEN_VRAM)
	dta a(TEXT_PITCH)					; Destination step y (160 - next text row)
	dta $01								; Destination step x (1)
	dta a(TEXT_PITCH-1)					; Width-1  (159 -> 160 bytes = 80 cells)
	dta TEXT_MAIN_ROWS-1					; Height-1 (19 -> 20 rows; PATCHED by Info_Draw)
	dta $FF								; And mask ($FF -> straight copy)
	dta $00								; Xor mask
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Save-under rectangle copy for the text-window primitive (Text_Window_Save /
; Text_Window_Restore).  A plain {glyph,attr} rect copy at screen pitch: step x
; = 1, step y = TEXT_PITCH, MODE 0, And $FF.  Both address triplets plus Width-1
; and Height-1 are patched per call; the two directions just swap Src <-> Dest.
BLT_TEXT_RECT
	dta $00,$00,$02						; Source address (PATCHED)
	dta a(TEXT_PITCH)					; Source step y (160 - next row)
	dta $01								; Source step x (1)
	dta $00,$00,$02						; Destination address (PATCHED)
	dta a(TEXT_PITCH)					; Destination step y (160 - next row)
	dta $01								; Destination step x (1)
	dta a($0000)						; Width-1  in BYTES (PATCHED = cells*2 - 1)
	dta $00								; Height-1 (PATCHED = rows - 1)
	dta $FF								; And mask ($FF -> straight copy)
	dta $00								; Xor mask
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Constant-source fast fills for the menu banner/separator VRAM.  The banner
; fill is a blank-fill fallback when its .RAW asset fails to load at boot, so
; cold-boot garbage never shows.  Fixed geometry, no patching needed - kicked
; once each from Load_Menu_Banner_Raw.
BLT_MENU_BANNER_CLEAR
	dta $00,$00,$00						; Source address (unused - constant source)
	dta $00,$00							; Source step y (unused)
	dta $00								; Source step x (unused)
	dta <MENU_BANNER_VRAM,>MENU_BANNER_VRAM,MENU_BANNER_VRAM>>16	; Destination address
	dta a(MENU_BANNER_PITCH)			; Destination step y (320 - next row)
	dta $01								; Destination step x (1)
	dta a(MENU_BANNER_PITCH-1)			; Width-1  (319 -> 320 bytes/row)
	dta MENU_BANNER_ROWS-1				; Height-1 (35 -> 36 rows)
	dta $00								; And mask (0 -> constant source)
	dta $00								; Xor mask (fill value: $00)
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; The separator is never loaded from disk - it is always this fixed-colour
; constant-source fill, kicked once from Load_Menu_Banner_Raw.  Dead after
; boot, so Fill_Pal_Preview_Cmap (view1024.asm) also repurposes it for the
; P-preview's CRAM_Buffer attribute fills (patching Dest_Adr, Dest_Step_Y0/1,
; Blt_W0/1, Blt_H, Blt_Xor) rather than spending a 13th BCB - the 12 BCBs in
; this file already fill the $100-$1FF VBXE VRAM budget (see the memory-map
; comment at the top of view1024.asm); a 13th BCB overflows BLT_NFO_NAME_
; CLEAR (the last one) across the $200 boundary into the NTSC_Palette load,
; corrupting it - this happened once, do not add a new BCB here again
; without also moving that budget.
BLT_MENU_SEP_CLEAR
	dta $00,$00,$00						; Source address (unused - constant source)
	dta $00,$00							; Source step y (unused)
	dta $00								; Source step x (unused)
	dta <MENU_SEP_VRAM,>MENU_SEP_VRAM,MENU_SEP_VRAM>>16			; Destination address
	dta a(MENU_SEP_PITCH)				; Destination step y (unused - 1 row)
	dta $01								; Destination step x (1)
	dta a(MENU_SEP_PITCH-1)				; Width-1  (159 -> 160 bytes/row)
	dta $00								; Height-1 (1 row)
	dta $00								; And mask (0 -> constant source)
	dta MENU_SEP_FILL_COLOUR			; Xor mask (fill value: white, Palette 0)
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Menu banner palette-demo overlay - blit Build_Menu_Ramp_Table's 256-byte
; ascending source ($2E000, bank $2E - fixed, never patched) as a flat 16x16
; block into one of the demo's 8 squares.  Draw_Menu_Demo_Squares (view1024.
; asm) patches Dest_Adr0-2 from Menu_Demo_Dest_Table before each of the 8
; kicks; every other field is fixed.
BLT_MENU_DEMO_SQUARE
	dta <MENU_RAMP_VRAM,>MENU_RAMP_VRAM,MENU_RAMP_VRAM>>16	; Source address ($2E000, fixed)
	dta $10,$00							; Source step y = 16
	dta $01								; Source step x (1)
	dta $00,$00,$00						; Destination address (PATCHED per kick)
	dta a(MENU_BANNER_PITCH)			; Destination step y (320)
	dta $01								; Destination step x (1)
	dta $0F,$00							; Width-1 = 15 (16 bytes wide)
	dta $0F								; Height-1 = 15 (16 rows)
	dta $FF								; And mask (straight copy)
	dta $00								; Xor mask
	dta $00								; Collision mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Wipe the selector description cache ($037000-$03EFFF = NFO_NAME_VRAM, banks
; $37-$3E) to $00, marking every image slot "not loaded".  Constant-source fast
; fill (And 0 -> source is the $00 Xor mask, no fetch).  256 bytes/row * 128
; rows = 32768 = 8 banks.  Kicked by Nfo_Name_ClearCache from Rescan_Images.
BLT_NFO_NAME_CLEAR
	dta $00,$00,$00						; Source address (unused - constant source)
	dta $00,$00							; Source step y (unused)
	dta $00								; Source step x (unused)
	dta <NFO_NAME_VRAM,>NFO_NAME_VRAM,NFO_NAME_VRAM>>16	; Destination address ($037000)
	dta a($0100)						; Destination step y (256 - next row)
	dta $01								; Destination step x (1)
	dta $FF,$00							; Width-1  (255 -> 256 bytes per row)
	dta $7F								; Height-1 (127 -> 128 rows; 128*256 = 32768 = 8 banks)
	dta $00								; And mask (0 -> constant source)
	dta $00								; Xor mask (fill value: $00)
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

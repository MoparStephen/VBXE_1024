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
	dta $00								; Control: MODE=0 (copy), NEXT=0 (last BCB); Clear 496kB (leave bottom 16kB for the SVBXE.SYS driver)

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

; Zero-fill the 80x30 VBXE text screen ($23000 - $242BF, 4800 bytes).  Constant-
; source fast fill: And mask 0 makes the source a constant equal to the Xor mask
; and the blitter skips the source fetch - about 2x faster than a copy (FX manual
; "The Blitter and constant source data").  Xor $00 -> blank glyph + transparent
; attribute in every cell.  MODE 0, NEXT clear.  Kicked by Text_Clear.
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

; Draw a window of the off-screen mono page (MONO_PAGE_VRAM, 1 glyph byte per
; column, MONO_PAGE_STRIDE bytes/row) onto the text screen.  This first link is
; a real copy (And $FF, MODE 0) writing glyph bytes into the even screen bytes
; (Destination step x = 2); NEXT is set so it chains into BLT_FILL_COLOUR_MONO,
; which floods the attribute bytes with one palette index.  Text_BlitMonoPage
; patches Source address + Height-1 (both links), Destination address (both) and
; the Xor colour (link 2).
BLT_DRAW_TEXT_MONO
	dta $00,$70,$02						; Source address ($027000 = MONO_PAGE_VRAM; PATCHED)
	dta a(MONO_PAGE_STRIDE)				; Source step y (128 - next page row)
	dta $01								; Source step x (1 - packed glyph bytes)
	dta $00,$30,$02						; Destination address ($023000 = TEXT_SCREEN_VRAM; PATCHED)
	dta a(TEXT_PITCH)					; Destination step y (160 - next text row)
	dta $02								; Destination step x (2 - glyph bytes only)
	dta a(TEXT_COLS-1)					; Width-1  (79 -> 80 columns)
	dta TEXT_ROWS-1						; Height-1 (29; PATCHED by Text_BlitMonoPage)
	dta $FF								; And mask ($FF -> straight copy)
	dta $00								; Xor mask
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta %00001000						; Control (Mode 0, NEXT bit SET -> chains)

; Chained after BLT_DRAW_TEXT_MONO: constant-source fast fill of the attribute
; (odd) bytes with one palette index.  Text_BlitMonoPage patches Destination
; address, Height-1 and the Xor colour before each kick.
BLT_FILL_COLOUR_MONO
	dta $00,$00,$00						; Source address (unused - constant source)
	dta $00,$00							; Source step y (unused)
	dta $00								; Source step x (unused)
	dta $01,$30,$02						; Destination address ($023001; PATCHED - attr byte)
	dta a(TEXT_PITCH)					; Destination step y (160 - next text row)
	dta $02								; Destination step x (2 - attribute bytes only)
	dta a(TEXT_COLS-1)					; Width-1  (79 -> 80 cells)
	dta TEXT_ROWS-1						; Height-1 (29; PATCHED by Text_BlitMonoPage)
	dta $00								; And mask (0 -> constant source)
	dta $0F								; Xor mask (palette index / colour; PATCHED)
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

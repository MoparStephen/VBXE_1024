;=============================================================================
; text80.asm  -  VBXE 80-column text screen for the viewer UI
;-----------------------------------------------------------------------------
; VBXE FX *hardware text mode* (XDLC_TMON + XDLC_CHBASE + XDLC_ATT), ported from
; VBXE_APOD (ASM Samples/Mockup1 - Load_Font / the XDL text block; Mockup2's
; Load_Text_Print_Error_L1 string writer and Set_Status_Colour).
;
; The 2048-byte IBM CGA font (CGA.F08: 256 x 8x8 1bpp, code page 437 order -
; glyph index = raw ASCII byte, NO ATASCII remap) is streamed from disk into
; VRAM at TEXT_FONT_VRAM; the XDL's CHBASE points at it.  "Drawing text" = poking
; a {glyph, colour} byte pair per cell into the XDL's screen RAM
; (TEXT_SCREEN_VRAM) through the $2000 MEMAC window.  No glyph rasteriser, no
; bit-depth expansion.
;
; The colour byte: bits 0-6 select the palette entry (0-127) for the character;
; bit 7 = 0 -> transparent background, 1 -> opaque/coloured background.
;
; TEXT_FONT_VRAM / TEXT_SCREEN_VRAM / TEXT_PITCH / TEXT_CHBASE live in
; view1024.asm's .def block and are shared with XDL_MainMenu (xdl.asm) so the
; two halves cannot drift.
;
; __VBXE_AUTO__ IS DEFINED IN THIS REPO.  Every VBXE_* register hit goes through
; vbsta / vblda; writes to VBXE_WINDOW ($2000..$2FFF) are plain stores (real
; memory - the mapped MEMAC window).  vbsta clobbers Y in auto mode: no live Y
; is held across one below.
;
; PUBLIC API (called by ui.asm):
;   Text_Init        stream CGA.F08 into VRAM once; blank the screen RAM.
;   Text_Activate    point VBXE_XDL_ADR0/1/2 at XDL_MainMenu.
;   Text_Deactivate  point them back at XDL_Image_Attribute (offset 0).
;   Text_Clear       blitter zero-fill of the 80 x TEXT_ROWS cells (blank +
;                    transparent) - ONE contiguous buffer backing both the
;                    XDL's main-content and footer text bands, see xdl.asm.
;   Text_FillColour  blitter recolour of a cell rectangle: Txt_Row/Txt_Col =
;                    top-left, Reg1 = width-1 (cells), Reg2 = height-1 (rows),
;                    A = attribute byte.  Floods the attribute bytes only.
;   Text_SetPen      A = fg palette entry (0-127), X = bg (0 transparent /
;                    non-zero opaque)  -> Make_Attr -> Txt_Attr.
;   Text_PutStrAt    draw the $00-terminated ASCII string at Txt_Ptr, from cell
;                    (Txt_Col, Txt_Row).
;
; INPUT VARIABLES (set by ui.asm before the call):
;   Txt_Row .byte  0..(TEXT_ROWS-1)    Txt_Col .byte  0..79    Txt_Ptr .word  -> string
;=============================================================================

; --- placeholder tuning knobs (Stephen finalises with Make_Attr / the XDL) ---
.def	TEXT_DEF_FG		= $0F			; default foreground (palette 0 index)
.def	TEXT_DEF_BG		= $00			; default background

.zpvar	Txt_Ptr			.word			; -> the string Text_PutStrAt is drawing
.var	Txt_Row			.byte = $6B0
.var	Txt_Col			.byte = $6B1
.var	Txt_Fg			.byte = $6B2
.var	Txt_Bg			.byte = $6B3
.var	Txt_Attr		.byte = $6B4	; current pen, as one cell attribute byte
;	$6B5 free  (was Txt_ClearAttr - the blitter Text_Clear zero-fills, no attr byte)
.var	Txt_Bank		.byte = $6B6	; VBXE bank currently mapped by the cell writer
;	$6B7 to $6FF free

;-----------------------------------------------------------------------------
; Text_Init - default pen, load the font, blank the screen.  Called once.
;-----------------------------------------------------------------------------
Text_Init
	lda #TEXT_DEF_FG
	ldx #TEXT_DEF_BG
	jsr Text_SetPen						; sets Txt_Attr

	jsr Text_Load_Fonts					; embedded CGA.F08 + ATARI.F08 -> VRAM bank $22
	jmp Text_Clear						; blank the screen RAM, then rts

;-----------------------------------------------------------------------------
; Text_Load_Fonts - copy both embedded 2048-byte fonts into VRAM bank
; TEXT_FONT_BANK ($22) through the $2000 window: CGA.F08 -> $022000 (CHBASE
; $44), ATARI.F08 -> $022800 (CHBASE $45).  Fonts are embedded rather than
; streamed from disk so the viewer never depends on a font file being on
; whatever disk it happens to boot from.  F (Handle_Keys) flips XDL_MainMenu's
; two CHBASE bytes (main + footer text blocks) between the two.
;-----------------------------------------------------------------------------
Text_Load_Fonts
	lda #TEXT_FONT_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL					; map VRAM bank $22 into $2000-$2FFF

	lda #<Text_Font_Data
	sta Ptr_Lo
	lda #>Text_Font_Data
	sta Ptr_Hi
	lda #<VBXE_WINDOW					; -> VBXE $022000  (CGA)
	sta Reg1
	lda #>VBXE_WINDOW
	sta Reg2
	jsr Text_Copy_2K

	lda #<Atari_Font_Data
	sta Ptr_Lo
	lda #>Atari_Font_Data
	sta Ptr_Hi
	lda #<[VBXE_WINDOW + $800]			; -> VBXE $022800  (Atari)
	sta Reg1
	lda #>[VBXE_WINDOW + $800]
	sta Reg2
	jsr Text_Copy_2K

	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

; Copy 2048 bytes (Ptr_Lo/Hi) -> (Reg1/Reg2), 8 pages.
Text_Copy_2K
	ldx #$08
	ldy #$00
Text_Copy_2K_L1
	lda (Ptr_Lo),y
	sta (Reg1),y
	iny
	bne Text_Copy_2K_L1
	inc Ptr_Hi
	inc Reg2
	dex
	bne Text_Copy_2K_L1
	rts

;-----------------------------------------------------------------------------
; Toggle_Font - flip the text screen between the CGA ($44) and Atari ($45)
; font by rewriting the two XDLC_CHBASE bytes (main + footer text blocks) in
; XDL_MainMenu.  The VBXE re-reads the XDL each frame, so the change shows on
; the next frame with no redraw.  Called from Handle_Keys on the F key, from
; any screen.
;-----------------------------------------------------------------------------
Toggle_Font
	lda Font_Sel
	eor #$01
	sta Font_Sel
	clc
	adc #TEXT_CHBASE					; 0 -> $44 (CGA) / 1 -> $45 (Atari)
	tax									; hold it - vbsta clobbers A (and Y)
	lda #MEMAC_GLOBAL_ENABLE				; map VBXE bank $00 into the $2000 window
	vbsta VBXE_MA_BSEL
	stx XDL_MainMenu_CHBase				; main-block XDLC_CHBASE byte
	stx XDL_MainMenu_CHBase2				; footer-block XDLC_CHBASE byte
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

;-----------------------------------------------------------------------------
; Text_Activate / Text_Deactivate - swap the displayed XDL.
;-----------------------------------------------------------------------------
Text_Activate
	lda #<[XDL_MainMenu - VBXE_WINDOW]	; XDL_MainMenu is org'd at VBXE_WINDOW -> VRAM $0000
	vbsta VBXE_XDL_ADR0
	lda #>[XDL_MainMenu - VBXE_WINDOW]
	vbsta VBXE_XDL_ADR1
	lda #$00
	vbsta VBXE_XDL_ADR2
	rts

Text_Deactivate							; back to XDL_Image_Attribute (offset 0)
	lda #$00
	vbsta VBXE_XDL_ADR0
	vbsta VBXE_XDL_ADR1
	vbsta VBXE_XDL_ADR2
	rts

;-----------------------------------------------------------------------------
; Text_SetPen - A = foreground palette entry (0-127),
;               X = background: 0 = transparent, non-zero = opaque.
;-----------------------------------------------------------------------------
Text_SetPen
	sta Txt_Fg
	stx Txt_Bg
	jsr Make_Attr
	sta Txt_Attr
	rts

;-----------------------------------------------------------------------------
; Make_Attr - Txt_Fg / Txt_Bg -> A = the VBXE text-mode colour byte:
;   bits 0-6 = foreground palette entry (0-127)
;   bit 7    = 1 when the background is opaque (Txt_Bg != 0), 0 = transparent
;-----------------------------------------------------------------------------
Make_Attr
	lda Txt_Fg
	and #$7F
	ldx Txt_Bg
	beq Make_Attr_Done
	ora #$80
Make_Attr_Done
	rts

;-----------------------------------------------------------------------------
; Text_Clear - blitter zero-fill of TEXT_SCREEN_VRAM .. +TEXT_SCREEN_BYTES.
; Kicks BLT_CLEAR_TEXT (constant-source fast fill, MODE 0) and waits for it to
; finish - callers poke glyphs into the same VRAM immediately after.  The blit
; crosses the $24000 bank boundary on its own (24-bit destination address).
;-----------------------------------------------------------------------------
Text_Clear
	lda #BLT_CLEAR_TEXT-BLT_CLEAR
	vbsta VBXE_BL_ADR0					; Point the blitter at BLT_CLEAR_TEXT
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Text_Clear_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Text_Clear_L1					; Wait for any prior blit to finish
	lda #$01
	vbsta VBXE_BLITTER_START				; Start the fill
Text_Clear_L2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Text_Clear_L2					; Wait for the fill to complete
	rts

;-----------------------------------------------------------------------------
; Text_FillColour - recolour a rectangle of cells by flooding their attribute
; (odd) bytes.  Inputs: Txt_Row / Txt_Col = top-left cell, Reg1 = width-1
; (cells), Reg2 = height-1 (rows), A = attribute byte.  Patches BLT_FILL_COLOUR
; (dest address, Width-1, Height-1, Xor mask) then kicks it and waits.
;-----------------------------------------------------------------------------
Text_FillColour
	sta Reg3							; Reg3 = attribute (Xor mask / fill value)
; Reg5:Reg4 = Txt_Row * TEXT_PITCH + Txt_Col*2 + 1  (attribute byte offset)
	lda #$00
	sta Reg4
	sta Reg5
	ldx Txt_Row
	beq Text_FillColour_Col
Text_FillColour_RowL
	lda Reg4
	clc
	adc #TEXT_PITCH						; + 160 per row
	sta Reg4
	bcc Text_FillColour_RowNC
	inc Reg5
Text_FillColour_RowNC
	dex
	bne Text_FillColour_RowL
Text_FillColour_Col
	lda Txt_Col
	asl									; Txt_Col * 2
	clc
	adc Reg4
	sta Reg4
	bcc Text_FillColour_ColNC
	inc Reg5
Text_FillColour_ColNC
	inc Reg4							; + 1  -> the attribute (odd) byte
	bne Text_FillColour_Patch
	inc Reg5
Text_FillColour_Patch
	lda #MEMAC_GLOBAL_ENABLE				; map VBXE bank $00 -> $2000 window
	vbsta VBXE_MA_BSEL
	lda Reg4
	sta BLT_FILL_COLOUR + Dest_Adr0		; dest lo  = offset lo
	lda Reg5
	clc
	adc #$30							; + $30  (low 16 bits of TEXT_SCREEN_VRAM = $3000)
	sta BLT_FILL_COLOUR + Dest_Adr1		; dest mid ; dest hi stays $02 (BCB default)
	lda Reg1
	sta BLT_FILL_COLOUR + Blt_W0			; Width-1  (cells - 1)
	lda Reg2
	sta BLT_FILL_COLOUR + Blt_H			; Height-1 (rows - 1)
	lda Reg3
	sta BLT_FILL_COLOUR + Blt_Xor		; attribute value
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	lda #BLT_FILL_COLOUR-BLT_CLEAR
	vbsta VBXE_BL_ADR0					; Point the blitter at BLT_FILL_COLOUR
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Text_FillColour_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Text_FillColour_L1				; Wait for any prior blit to finish
	lda #$01
	vbsta VBXE_BLITTER_START				; Start the recolour
Text_FillColour_L2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Text_FillColour_L2				; Wait for it to complete
	rts

;-----------------------------------------------------------------------------
; Text_Window_Save / Text_Window_Restore - blit a rectangle of {glyph,attr}
; cells between the text screen and WIN_SAVE_VRAM (a save-under buffer held at
; screen pitch).  Inputs: Txt_Row / Txt_Col = top-left cell, Reg1 = width-1
; (cells), Reg2 = height-1 (rows).  Patches BLT_TEXT_RECT and waits.  The rect
; must fit WIN_SAVE_VRAM: 4K / TEXT_PITCH = 25 rows max.
; Clobbers A/X/Y, Reg4, Reg5.  (Reg1 / Reg2 / Txt_Row / Txt_Col survive - the
; caller can Save then Frame on the same geometry.)
;-----------------------------------------------------------------------------
Text_Window_Save
	jsr Text_Window_Setup				; Reg5:Reg4 = screen offset; W-1/H-1 patched; bank mapped
	lda Reg4
	sta BLT_TEXT_RECT + Src_Adr0
	lda Reg5
	clc
	adc #$30							; low 16 bits of TEXT_SCREEN_VRAM = $3000
	sta BLT_TEXT_RECT + Src_Adr1
	lda #$02
	sta BLT_TEXT_RECT + Src_Adr2
	lda #<WIN_SAVE_VRAM
	sta BLT_TEXT_RECT + Dest_Adr0
	lda #>WIN_SAVE_VRAM
	sta BLT_TEXT_RECT + Dest_Adr1
	lda #[WIN_SAVE_VRAM >> 16]
	sta BLT_TEXT_RECT + Dest_Adr2
	jmp Text_Window_Kick

Text_Window_Restore
	jsr Text_Window_Setup
	lda #<WIN_SAVE_VRAM
	sta BLT_TEXT_RECT + Src_Adr0
	lda #>WIN_SAVE_VRAM
	sta BLT_TEXT_RECT + Src_Adr1
	lda #[WIN_SAVE_VRAM >> 16]
	sta BLT_TEXT_RECT + Src_Adr2
	lda Reg4
	sta BLT_TEXT_RECT + Dest_Adr0
	lda Reg5
	clc
	adc #$30
	sta BLT_TEXT_RECT + Dest_Adr1
	lda #$02
	sta BLT_TEXT_RECT + Dest_Adr2
	jmp Text_Window_Kick

; Reg5:Reg4 = Txt_Row*TEXT_PITCH + Txt_Col*2 ; patch Width-1 (bytes) + Height-1 ;
; map VBXE bank $00 into the $2000 window (Text_Window_Kick unmaps).
Text_Window_Setup
	lda #$00
	sta Reg4
	sta Reg5
	ldx Txt_Row
	beq Text_Window_Setup_Col
Text_Window_Setup_RowL
	lda Reg4
	clc
	adc #TEXT_PITCH
	sta Reg4
	bcc Text_Window_Setup_RowNC
	inc Reg5
Text_Window_Setup_RowNC
	dex
	bne Text_Window_Setup_RowL
Text_Window_Setup_Col
	lda Txt_Col
	asl
	clc
	adc Reg4
	sta Reg4
	bcc Text_Window_Setup_ColNC
	inc Reg5
Text_Window_Setup_ColNC
	lda #MEMAC_GLOBAL_ENABLE				; map VBXE bank $00 -> $2000 window
	vbsta VBXE_MA_BSEL
	lda Reg1							; Width-1 (bytes) = (cells-1)*2 + 1 = Reg1*2 + 1
	asl
	clc
	adc #$01
	sta BLT_TEXT_RECT + Blt_W0
	lda #$00
	sta BLT_TEXT_RECT + Blt_W1
	lda Reg2
	sta BLT_TEXT_RECT + Blt_H
	rts

Text_Window_Kick
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	lda #BLT_TEXT_RECT-BLT_CLEAR
	vbsta VBXE_BL_ADR0
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Text_Window_Kick_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Text_Window_Kick_L1				; wait for any prior blit
	lda #$01
	vbsta VBXE_BLITTER_START
Text_Window_Kick_L2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Text_Window_Kick_L2				; wait for the copy to finish
	rts

;-----------------------------------------------------------------------------
; Text_Window_Frame - draw a simple ASCII box ('+' '-' '|') with a blank
; interior over Txt_Row / Txt_Col / Reg1 (width-1) / Reg2 (height-1), using the
; current pen.  Uses Txt_Line as scratch.  Clobbers A/X/Y, Reg1..Reg8.
;-----------------------------------------------------------------------------
Text_Window_Frame
	lda Reg1
	sta Reg7							; Reg7 = width-1 (survives Text_PutStrAt)
	lda Txt_Col
	sta Reg8							; Reg8 = left column
	lda Txt_Row
	clc
	adc Reg2
	sta Reg6							; Reg6 = bottom-edge screen row
	lda Txt_Row
	sta Reg5							; Reg5 = current screen row
	jsr Text_Window_Frame_EdgeRow		; top edge
Text_Window_Frame_Mid
	inc Reg5
	lda Reg5
	cmp Reg6
	bcs Text_Window_Frame_Bottom
	jsr Text_Window_Frame_MidRow
	jmp Text_Window_Frame_Mid
Text_Window_Frame_Bottom
	jmp Text_Window_Frame_EdgeRow		; bottom edge (tail - returns to caller)

Text_Window_Frame_EdgeRow
	lda #'+'
	sta Txt_Line+0
	ldx #$01
Text_Window_Frame_EdgeL
	cpx Reg7
	bcs Text_Window_Frame_EdgeEnd
	lda #'-'
	sta Txt_Line,x
	inx
	bne Text_Window_Frame_EdgeL
Text_Window_Frame_EdgeEnd
	lda #'+'
	sta Txt_Line,x
	inx
	jmp Text_Window_Frame_PutRow

Text_Window_Frame_MidRow
	lda #'|'
	sta Txt_Line+0
	ldx #$01
Text_Window_Frame_MidL
	cpx Reg7
	bcs Text_Window_Frame_MidEnd
	lda #' '
	sta Txt_Line,x
	inx
	bne Text_Window_Frame_MidL
Text_Window_Frame_MidEnd
	lda #'|'
	sta Txt_Line,x
	inx
Text_Window_Frame_PutRow
	lda #$00
	sta Txt_Line,x
	lda Reg5
	sta Txt_Row
	lda Reg8
	sta Txt_Col
	lda #<Txt_Line
	sta Txt_Ptr
	lda #>Txt_Line
	sta Txt_Ptr + $01
	jmp Text_PutStrAt					; tail (rts returns to Text_Window_Frame's caller)

;-----------------------------------------------------------------------------
; Text_PutStrAt - write {ASCII, Txt_Attr} pairs for the $00-terminated string
; at Txt_Ptr, starting at cell (Txt_Col, Txt_Row).  Tracks bank + window
; offset explicitly (a row near the bottom straddles the $24000 boundary).
;-----------------------------------------------------------------------------
Text_PutStrAt
; --- Reg2:Reg1 = Txt_Row * TEXT_PITCH + Txt_Col * 2  (cell byte offset) -------
	lda #$00
	sta Reg1
	sta Reg2
	ldx Txt_Row
	beq Text_PutStrAt_Col
Text_PutStrAt_RowL
	lda Reg1
	clc
	adc #TEXT_PITCH
	sta Reg1
	bcc Text_PutStrAt_RowNC
	inc Reg2
Text_PutStrAt_RowNC
	dex
	bne Text_PutStrAt_RowL
Text_PutStrAt_Col
	lda Txt_Col
	asl									; Txt_Col * 2 (max 158)
	clc
	adc Reg1
	sta Reg1
	bcc Text_PutStrAt_ColNC
	inc Reg2
Text_PutStrAt_ColNC
; --- fold in TEXT_SCREEN_VRAM: offset (0..$12BF) -> bank + window pointer -----
	lda Reg2
	and #$10							; offset bit 12 = "second bank"
	beq Text_PutStrAt_Bank0
	lda #TEXT_SCREEN_BANK+1
	bne Text_PutStrAt_SetBank
Text_PutStrAt_Bank0
	lda #TEXT_SCREEN_BANK
Text_PutStrAt_SetBank
	sta Txt_Bank
	lda Reg1
	sta Ptr_Lo
	lda Reg2
	and #$0F
	clc
	adc #>VBXE_WINDOW					; + $20  -> $20xx..$2Fxx
	sta Ptr_Hi
	lda Txt_Bank
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
; --- write the cells -------------------------------------------------------
	lda #$00
	sta Reg3							; Reg3 = source string index
	lda Txt_Col
	sta Reg4							; Reg4 = current column (clip at TEXT_COLS)
Text_PutStrAt_Char
	lda Reg4
	cmp #TEXT_COLS
	bcs Text_PutStrAt_Done				; hit the right edge - stop (never wrap)
	ldy Reg3
	lda (Txt_Ptr),y
	beq Text_PutStrAt_Done
	ldy #$00
	sta (Ptr_Lo),y						; glyph byte
	iny
	lda Txt_Attr
	sta (Ptr_Lo),y						; attribute byte
	inc Reg3
	inc Reg4
	lda Ptr_Lo							; window pointer += 2
	clc
	adc #$02
	sta Ptr_Lo
	bcc Text_PutStrAt_NoPage
	inc Ptr_Hi
Text_PutStrAt_NoPage
	lda Ptr_Hi
	cmp #$30							; crossed out of the window -> next bank
	bcc Text_PutStrAt_Char
	sec
	sbc #$10
	sta Ptr_Hi							; wrap back to $20xx
	inc Txt_Bank
	lda Txt_Bank
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	jmp Text_PutStrAt_Char
Text_PutStrAt_Done
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

;-----------------------------------------------------------------------------
; The IBM CGA font, embedded in the .xex.  256 glyphs x 8x8 1bpp = 2048 bytes,
; code page 437 order (glyph index = raw ASCII byte).  Text_Load_Font copies it
; into VRAM bank TEXT_FONT_BANK at boot.
;-----------------------------------------------------------------------------
Text_Font_Data
	ins 'Assets/CGA.F08'
Text_Font_Data_End
	.if Text_Font_Data_End - Text_Font_Data != 2048
		.error "CGA.F08 must be exactly 2048 bytes"
	.endif

;-----------------------------------------------------------------------------
; The Atari OS character set, embedded in the .xex.  Re-ordered from the ROM's
; ATASCII/internal glyph order into ASCII order (glyph index = raw ASCII byte,
; matching CGA.F08 and Text_PutStrAt), with glyphs $80-$FF the bitwise inverse
; of $00-$7F.  256 glyphs x 8x8 1bpp = 2048 bytes.  ATARI-raw.F08 keeps the
; original 1024-byte ROM dump.  Loaded to VRAM $022800 by Text_Load_Fonts.
;-----------------------------------------------------------------------------
Atari_Font_Data
	ins 'Assets/ATARI.F08'
Atari_Font_Data_End
	.if Atari_Font_Data_End - Atari_Font_Data != 2048
		.error "ATARI.F08 must be exactly 2048 bytes"
	.endif

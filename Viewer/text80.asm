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
;   Text_Init        copy both fonts into VRAM once; blank the screen RAM.
;   Text_Activate    point VBXE_XDL_ADR0/1/2 at XDL_MainMenu.
;   Text_Deactivate  point them back at XDL_Image_Attribute (offset 0).
;   Text_Present     blit the back buffer onto the displayed screen, in vblank.
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
;
; DOUBLE BUFFERED.  Every draw call below writes the BACK buffer
; (TEXT_BACK_VRAM), never the displayed one, and sets Txt_Dirty.  Nothing
; appears until Text_Present copies the whole back buffer across with one blit
; during vblank - Read_Key_Done does that after every key that drew anything,
; and the transitions (Enter_Selector, UI_Show_Busy before slow disk I/O) call
; it directly.  So a repaint, a dialog, a scroll is never seen half-built.
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
.var	Txt_FrameStyle	.byte = $6B5	; Text_Window_Frame border: FRAME_DOUBLE / FRAME_SINGLE
.var	Txt_Bank		.byte = $6B6	; VBXE bank currently mapped by the cell writer
.var	Txt_Dirty		.byte = $6B7	; non-zero = back buffer changed since the last Text_Present
;	$6B8 to $6FF free

;-----------------------------------------------------------------------------
; Text_Init - default pen, load the font, blank the screen.  Called once.
;-----------------------------------------------------------------------------
Text_Init
	lda #TEXT_DEF_FG
	ldx #TEXT_DEF_BG
	jsr Text_SetPen						; sets Txt_Attr

	jsr Text_Load_Fonts					; embedded CGA.F08 + ATARI.F08 -> VRAM bank $22
	jsr Text_Clear						; blank the back buffer...
	jmp Text_Present					; ...and the displayed screen, then rts

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

; Make the Atari font answer to the CP437 codes the UI draws with: copy its own
; line / arrow glyphs into those slots (VRAM copy only - ATARI.F08 itself is
; untouched).  Both fonts then render the same bytes, so F is a pure CHBASE
; flip and nothing on screen ever needs redrawing for it.  The overwritten
; slots are only inverse-video copies ($80+) and ATASCII Ctrl glyphs no UI
; string or .NFO (plain ASCII) uses.
	ldx #$00
Text_Load_Fonts_Remap
	lda Atari_Remap_Table,x				; source glyph -> Ptr = $2800 + src*8
	jsr Text_Glyph_Addr
	sta Ptr_Lo
	sty Ptr_Hi
	lda Atari_Remap_Table+1,x			; dest glyph   -> Reg1/2 = $2800 + dst*8
	jsr Text_Glyph_Addr
	sta Reg1
	sty Reg2
	ldy #$07
Text_Load_Fonts_Glyph
	lda (Ptr_Lo),y
	sta (Reg1),y
	dey
	bpl Text_Load_Fonts_Glyph
	inx
	inx
	cpx #[Atari_Remap_Table_End-Atari_Remap_Table]
	bne Text_Load_Fonts_Remap

	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

; A = glyph code -> A/Y = lo/hi of that glyph's 8 bytes in the Atari font, as
; mapped at VBXE_WINDOW + $800.  X preserved.
Text_Glyph_Addr
	ldy #>[[VBXE_WINDOW + $800] / 8]	; = $05 - becomes $28 after the x8 below
	sty Reg3
	asl
	rol Reg3
	asl
	rol Reg3
	asl
	rol Reg3							; Reg3:A = $2800 + code*8
	ldy Reg3
	rts

; {source, destination} glyph pairs, applied in order.  Box lines first: $1A
; (ATASCII Ctrl-Z corner) is read here before the arrows overwrite it.
; CP437 double and single box sets both map onto the Atari single-line set.
Atari_Remap_Table
	dta $11,$C9, $12,$CD, $05,$BB, $7C,$BA, $1A,$C8, $03,$BC	; double: TL - TR | BL BR
	dta $11,$DA, $12,$C4, $05,$BF, $7C,$B3, $1A,$C0, $03,$D9	; single: TL - TR | BL BR
	dta $1C,$18, $1D,$19, $1E,$1B, $1F,$1A						; arrows: up down left right
Atari_Remap_Table_End

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
; the next frame with no redraw - Text_Load_Fonts gave the Atari font the same
; box / arrow codes as CGA, so an open dialog or legend is right in either.
; Called from Handle_Keys on the F key, from any screen.
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
; Text_Present - copy the whole back buffer (TEXT_BACK_VRAM) onto the displayed
; text screen (TEXT_SCREEN_VRAM) with one BLT_TEXT_RECT blit, kicked in vblank
; (Wait_VBlank) so the change lands between frames.  Clears Txt_Dirty.
; Clobbers A/Y.
;-----------------------------------------------------------------------------
Text_Present
	lda #MEMAC_GLOBAL_ENABLE				; map VBXE bank $00 -> $2000 window (patch the BCB)
	vbsta VBXE_MA_BSEL
	lda #<TEXT_BACK_VRAM
	sta BLT_TEXT_RECT + Src_Adr0
	lda #>TEXT_BACK_VRAM
	sta BLT_TEXT_RECT + Src_Adr1
	lda #[TEXT_BACK_VRAM >> 16]
	sta BLT_TEXT_RECT + Src_Adr2
	lda #<TEXT_SCREEN_VRAM
	sta BLT_TEXT_RECT + Dest_Adr0
	lda #>TEXT_SCREEN_VRAM
	sta BLT_TEXT_RECT + Dest_Adr1
	lda #[TEXT_SCREEN_VRAM >> 16]
	sta BLT_TEXT_RECT + Dest_Adr2
	lda #<[TEXT_PITCH-1]
	sta BLT_TEXT_RECT + Blt_W0			; Width-1  = 159 bytes (80 cells)
	lda #>[TEXT_PITCH-1]
	sta BLT_TEXT_RECT + Blt_W1
	lda #TEXT_ROWS-1
	sta BLT_TEXT_RECT + Blt_H			; Height-1 = every row, both bands
	lda #$00
	sta Txt_Dirty
	jsr Wait_VBlank						; swap between frames
	jmp Text_Window_Kick				; unmap, kick, wait (tail)

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
; Text_Clear - blitter zero-fill of the back buffer (TEXT_BACK_VRAM ..
; +TEXT_SCREEN_BYTES).
; Kicks BLT_CLEAR_TEXT (constant-source fast fill, MODE 0) and waits for it to
; finish - callers poke glyphs into the same VRAM immediately after.
;-----------------------------------------------------------------------------
Text_Clear
	lda #$01
	sta Txt_Dirty
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
	lda #$01
	sta Txt_Dirty
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
	adc #>TEXT_BACK_VRAM				; + the back buffer's mid byte (offset < $1000, no carry)
	sta BLT_FILL_COLOUR + Dest_Adr1		; dest mid
	lda #[TEXT_BACK_VRAM >> 16]
	sta BLT_FILL_COLOUR + Dest_Adr2		; dest hi
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
; cells between the (back buffer) text screen and WIN_SAVE_VRAM (a save-under buffer held at
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
	adc #>TEXT_BACK_VRAM				; back buffer mid byte (offset < $1000, no carry)
	sta BLT_TEXT_RECT + Src_Adr1
	lda #[TEXT_BACK_VRAM >> 16]
	sta BLT_TEXT_RECT + Src_Adr2
	lda #<WIN_SAVE_VRAM
	sta BLT_TEXT_RECT + Dest_Adr0
	lda #>WIN_SAVE_VRAM
	sta BLT_TEXT_RECT + Dest_Adr1
	lda #[WIN_SAVE_VRAM >> 16]
	sta BLT_TEXT_RECT + Dest_Adr2
	jmp Text_Window_Kick

Text_Window_Restore
	lda #$01
	sta Txt_Dirty
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
	adc #>TEXT_BACK_VRAM
	sta BLT_TEXT_RECT + Dest_Adr1
	lda #[TEXT_BACK_VRAM >> 16]
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
; Text_Window_Frame - draw a box with a blank interior over Txt_Row / Txt_Col /
; Reg1 (width-1) / Reg2 (height-1), using the current pen.  Txt_FrameStyle
; picks the border: the CP437 box-drawing glyphs FRAME_DOUBLE / FRAME_SINGLE.
; The Atari font carries its own single-line glyphs at those same codes (see
; Text_Load_Fonts), so the frame is right in either font with no redraw.
; Uses Txt_Line as scratch.  Clobbers A/X/Y, Reg1..Reg8.
;-----------------------------------------------------------------------------
.def	FRAME_DOUBLE	= 0				; Text_Window_Frame_Chars offsets (9 bytes per style)
.def	FRAME_SINGLE	= 9

; Per style, three {left, fill, right} triples: top edge, interior row, bottom edge.
Text_Window_Frame_Chars
	dta $C9,$CD,$BB, $BA,' ',$BA, $C8,$CD,$BC	; FRAME_DOUBLE  (CP437 double lines)
	dta $DA,$C4,$BF, $B3,' ',$B3, $C0,$C4,$D9	; FRAME_SINGLE  (CP437 single lines)

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
	ldx Txt_FrameStyle
	jsr Text_Window_Frame_Row			; top edge
Text_Window_Frame_Mid
	inc Reg5
	lda Reg5
	cmp Reg6
	bcs Text_Window_Frame_Bottom
	lda Txt_FrameStyle
	clc
	adc #$03
	tax
	jsr Text_Window_Frame_Row			; interior row
	jmp Text_Window_Frame_Mid
Text_Window_Frame_Bottom
	lda Txt_FrameStyle
	clc
	adc #$06
	tax									; bottom edge (tail - returns to caller)

; X = offset of a {left, fill, right} triple in Text_Window_Frame_Chars.
; Builds the row in Txt_Line and draws it at row Reg5, column Reg8.
Text_Window_Frame_Row
	lda Text_Window_Frame_Chars,x
	sta Txt_Line+0
	lda Text_Window_Frame_Chars+1,x
	sta Reg4							; Reg4 = fill char (Reg3/4 free until Text_PutStrAt)
	lda Text_Window_Frame_Chars+2,x
	sta Reg3							; Reg3 = right char
	ldx #$01
Text_Window_Frame_Row_L1
	cpx Reg7
	bcs Text_Window_Frame_Row_End
	lda Reg4
	sta Txt_Line,x
	inx
	bne Text_Window_Frame_Row_L1
Text_Window_Frame_Row_End
	lda Reg3
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
; at Txt_Ptr, starting at cell (Txt_Col, Txt_Row), in the back buffer.  Tracks
; bank + window offset explicitly (kept general - the 3680-byte buffer sits in
; one bank today, but a cell walk past $xxFFF still steps to the next).
; Inline colour: TXT_PEN, attr switches the pen mid-string (takes no column),
; e.g. dta TXT_PEN,UI_PEN_LABEL,c'Location'.  The caller's pen (Txt_Fg/Txt_Bg)
; is restored on exit, so an escape never leaks into the next draw.
;-----------------------------------------------------------------------------
.def	TXT_PEN			= $01			; pen-change escape (CP437 smiley - never in names/descriptions)

Text_PutStrAt
	lda #$01
	sta Txt_Dirty
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
; --- fold in TEXT_BACK_VRAM: offset (0..$E5F) -> bank + window pointer --------
	lda Reg2
	and #$10							; offset bit 12 = "second bank"
	beq Text_PutStrAt_Bank0
	lda #TEXT_BACK_BANK+1
	bne Text_PutStrAt_SetBank
Text_PutStrAt_Bank0
	lda #TEXT_BACK_BANK
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
	cmp #TXT_PEN
	bne Text_PutStrAt_Glyph
	iny									; TXT_PEN, attr - next byte is the new pen
	lda (Txt_Ptr),y
	sta Txt_Attr
	iny
	sty Reg3							; skip both bytes, column unchanged
	jmp Text_PutStrAt_Char
Text_PutStrAt_Glyph
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
	jsr Make_Attr						; restore the caller's pen (a TXT_PEN escape
	sta Txt_Attr						; may have changed it) - clobbers X
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

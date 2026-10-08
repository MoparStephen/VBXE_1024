;=============================================================================
; ui.asm  -  viewer UI: file selector, slideshow, runtime directory scan
;-----------------------------------------------------------------------------
; This is the main segment (icl'd from view1024.asm at $3300+).  Everything
; here is entered only at runtime - from start: and from the key handlers -
; so NONE of it is reachable from an ini step (unlike the old Scan_Images).
;
; __VBXE_AUTO__ IS DEFINED IN THIS REPO.  Every VBXE_* register access here
; goes through vbsta / vblda, never a bare lda / sta VBXE_* (a bare access
; silently collapses to a zero-page hit - the $53 / VBXE_BLITTER_BUSY hang).
; vbsta/vblda clobber Y in auto mode: no live Y is held across one below.
;
; Screen model (text80.asm): 80 columns x TEXT_ROWS(23) rows, Palette 0 - the
; menu/info XDL (xdl.asm) displays this ONE buffer as two on-screen bands (a
; graphics banner sits above it, a 1-line separator between the bands, see
; xdl.asm for the full 240-scanline layout).  Selector row map:
;   row 0            Location: <path>  ...  image counter (cols 68-77,
;                    "nnn of NNN" / "NNN images" - Selector_DrawCount);
;                    "Scanning directory..." in the path's place while
;                    Rescan_Images runs
;   row 1            blank
;   rows 2-16 (15)   scrolling grid (UI_FIRSTROW/UI_VISROWS below)
;   rows 17-19       spare/margin (blank)
;   row 20 (TEXT_MAIN_ROWS+0)   "Nfo: <description>"
;   row 21 (TEXT_MAIN_ROWS+1)   "Cfg: NN sec (< Less > More)  ...  Press HELP ..."
;   row 22 (TEXT_MAIN_ROWS+2)   "Nav: <arrows> Select Enter Choose ..." (key legend)
;   - each starts with a 3-letter tag + ':' in UI_PEN_LOC, at col 0
; The info viewer uses rows 0..TEXT_MAIN_ROWS-1 for scrollable content and
; row TEXT_MAIN_ROWS for a single fixed hint line - see NFO_VISROWS below.
;
; UI_Mode:  0 = selector   1 = image view   2 = slideshow
;           3 = drive picker (D-key save-under overlay)   4 = info viewer (.nfo)
;           5 = quit-confirm (Q-key save-under overlay, selector only)
;           6 = P-preview (P-key 4-palette ramp-square screen, Esc only)
;=============================================================================

.def	UI_COLS			= 8				; grid columns (items/row) - a power of 2
										; keeps row=index>>3 / col=index&7 cheap
.def	UI_VISROWS		= 15			; grid rows visible at once
.def	UI_FIRSTROW		= 2				; first screen row of the grid
.def	UI_GRIDCOL0		= 0				; first screen column of the grid (Sel_ColX base)
.def	UI_COUNT_COL	= 68			; row 0 image counter, 10 chars (cols 68-77,
										; mirroring Location:'s 2-col left margin)
; UI_FIRSTROW / UI_GRIDCOL0 are the only placement knobs - see the row map
; above for the rest of the selector's chrome (status/delay/legend rows).
.def	UI_SLIDE_MIN	= 1
.def	UI_SLIDE_MAX	= 30
; VBXE text-mode colour byte: bits 0-6 = foreground palette-0 entry (0-127),
; bit 7 = 1 -> opaque background (hardware-forced to palette[fg+128]), 0 ->
; transparent.  UI_Build_TextPalette de-interleaves the Atari master for set 0
; so entry e = master colour 2e: hue = e>>3 (all 16 hues), luma = (e&7)*2.
; The cursor row is marked by FOREGROUND colour only - no opaque bar - because
; after the de-interleave palette[e+128] is the adjacent-luma neighbour of
; palette[e] and gives no contrast.  Tune the three indices once on screen.
.def	UI_PEN_FG		= $07			; normal text   : hue 0 grey,  luma 14
.def	UI_PEN_HI		= $0F			; drive picker highlight : hue 1 gold, luma 14
; Selector grid - UI_Name_Pen picks one of these four per cell:
.def	UI_PEN_FILE		= $3A			; *.V1K file rows          : hue 7 blue,  luma 4
.def	UI_PEN_DIR		= $53			; directory / ".." rows    : hue $A green, luma 6
.def	UI_PEN_FILEHI	= $44			; highlighted file         : hue 8 light blue, luma 8
.def	UI_PEN_DIRHI	= $56			; highlighted dir / ".."   : hue $A green, luma 12
.def	UI_PEN_EMPTY	= $1B			; "* No images *" note     : hue 3 red,   luma 6
; Chrome colours - mirror PEN_* in Convertor/nfo_encode.py (the .nfo info
; screen), so the selector and the info screen share one scheme.  Labels and
; the legend/hint strings carry these inline (TXT_PEN escapes, text80.asm).
.def	UI_PEN_LABEL	= $7C			; label left of ':'  : hue $F gold,  luma 8
.def	UI_PEN_SEP		= $44			; the ':'            : hue 8 blue,   luma 8
.def	UI_PEN_VALUE	= $3A			; values             : hue 7 blue,   luma 4
.def	UI_PEN_LOC		= $7C			; row 0 "Location: " + path (all one colour)
.def	UI_PEN_NFO		= $3B			; status row 20 description (after "Nfo: ") : hue 7, luma 6
.def	UI_PEN_COUNT	= $3B			; row 0 "nnn of NNN" / "NNN images" : hue 7, luma 6
.def	UI_PEN_FRAMEC	= $3A			; popup window frames: hue 7 blue,  luma 4
.def	UI_PEN_QUITQ	= $3B			; quit question      : hue 7 blue,   luma 6
.def	UI_PEN_YES		= $52			; quit "Y" button    : hue $A dark green, luma 4
.def	UI_PEN_NO		= $19			; quit "N" button    : hue 3 dark red,   luma 2
.def	UI_PEN_KEY		= $43			; key names          : hue 8 light blue, luma 6 (= info screen notes)
.def	UI_PEN_DESC		= $3A			; key descriptions   : hue 7 dark blue,  luma 4 (= info screen values)
.def	UI_PEN_HELP		= $59			; help page text     : hue $B teal-green, luma 2
.def	UI_PEN_HELPHEAD	= $5D			; help section name  : hue $B teal-green, luma 10
.def	UI_PEN_HELPKEY	= $5A			; help key column    : hue $B teal-green, luma 4 (one step over UI_PEN_HELP)
.def	UI_PEN_HELPNAV	= $5B			; help Section 2 keys: hue $B teal-green, luma 6 (one step over UI_PEN_HELPKEY)
.def	HELP_PAGES		= 3				; Help_Text_1..3 (Help_Page_Lo/Hi)
.def	HELP_VISROWS	= TEXT_MAIN_ROWS-1	; help section rows visible at once (rows 1-19)

.def	NFO_TOPROW		= 0				; info viewer: first screen row of the scroll region
.def	NFO_VISROWS		= TEXT_MAIN_ROWS	; info viewer: visible text rows (main band only)
; The logo band is real now (the menu XDL's graphics group, see xdl.asm) - it
; lives in its own VRAM, not stolen text rows, so NFO_TOPROW stays 0.
; NFO_VISROWS must equal TEXT_MAIN_ROWS (not the full TEXT_ROWS buffer): the
; blit overwrites every row it touches, and rows TEXT_MAIN_ROWS..TEXT_ROWS-1
; hold the separate static footer hint line - the NFO blit must not touch it.
.def	NFO_MAX_LINES	= 127			; cap on displayed .NFO records; NFO_BUF_VRAM (5 banks)
									; holds 128 * 160, the 128th slot being the $00 sentinel

; --- CH key codes (POKEY, no modifier).  Matches the bare-CH style in
;     Handle_Keys (Q $2F, Space $21, BkSp $34, Esc $1C, digits ...).
;     The 4 arrows are also accepted with CTRL held ($8E/$8F/$86/$87): each
;     handler ANDs CH with KEY_CTRL_OFF before the arrow compares, then
;     reloads the raw CH for everything else.
.def	KEY_CTRL_OFF	= $7F			; CH AND mask - clears the CTRL bit ($80)
.def	KEY_UP			= $0E			; "-" key (up-arrow;    Ctrl = $8E)
.def	KEY_DOWN		= $0F			; "=" key (down-arrow;  Ctrl = $8F)
.def	KEY_LEFT		= $06			; "+" key (left-arrow;  Ctrl = $86)
.def	KEY_RIGHT		= $07			; "*" key (right-arrow; Ctrl = $87)
.def	KEY_RETURN		= $0C
.def	KEY_ESC			= $1C
.def	KEY_SPACE		= $21
.def	KEY_Q			= $2F
.def	KEY_S			= $3E
.def	KEY_D			= $3A
.def	KEY_F			= $38			; toggle text font (CGA <-> Atari)
.def	KEY_P			= $0A
.def	KEY_I			= $0D
.def	KEY_COMMA		= $20			; "," - shorter slideshow delay (selector)
.def	KEY_DOT			= $22			; "." - longer slideshow delay  (selector)
										;     (shown as "<" / ">" in the Cfg: row - the
										;     same keys on a PC keyboard)
.def	KEY_Y			= $2B			; quit-confirm: yes (verified via Altirra CH readback)
.def	KEY_N			= $23			; quit-confirm: no  (verified via Altirra CH readback)

;-----------------------------------------------------------------------------
; TXT_AT row, col, strlabel  -  draw a string via the text API
;-----------------------------------------------------------------------------
.macro TXT_AT
	lda #[:1]
	sta Txt_Row
	lda #[:2]
	sta Txt_Col
	lda #<[:3]
	sta Txt_Ptr
	lda #>[:3]
	sta Txt_Ptr + $01
	jsr Text_PutStrAt
.endm

;-----------------------------------------------------------------------------
; DTA_SCR code  -  emit one Atari internal screen code (e.g. V_0..V_3, which
; the loader screen uses) as the ASCII byte the text mode's CP437 font wants.
;-----------------------------------------------------------------------------
.macro DTA_SCR
	.if [:1] < $40
	dta [:1]+$20						; $00-$3F: space, punctuation, digits, A-Z
	.elseif [:1] < $60
	dta [:1]-$40						; $40-$5F: control-glyph block
	.else
	dta [:1]							; $60-$7F: a-z - already ASCII
	.endif
.endm

;=============================================================================
; Directory scan  (moved here from init_vbxe.asm's Scan_Images - the scan
; location is now chosen at runtime, so it can't be decided in the loader)
;=============================================================================

;-----------------------------------------------------------------------------
; Rescan_Images - scan Scan_Drive/Scan_Path for *.V1K, rebuild + sort the list.
; Tolerates zero matches (an ordinary state the selector shows).
;-----------------------------------------------------------------------------
Rescan_Images
; Show "Scanning directory..." where the path goes - the scan + IMAGES.LST
; name cache can take a while in a big folder.  Every caller repaints the
; whole selector (Selector_Draw) afterwards.
	lda #<UI_Str_Scanning
	ldy #>UI_Str_Scanning
	jsr UI_Show_Busy

	jsr Build_Image_List				; fills IMAGE_BANK; sets ImageCount/Dir_Count/FileStart

; sort the two real groups independently: dirs [FileStart-Dir_Count .. FileStart)
; then files [FileStart .. ImageCount).  ".." (if present) stays pinned at 0.
	lda FileStart
	sec
	sbc Dir_Count
	ldx Dir_Count
	jsr Sort_Range						; directories A-Z
	lda ImageCount
	sec
	sbc FileStart
	tax									; X = file count
	lda FileStart
	jsr Sort_Range						; *.V1K files A-Z

	jsr Nfo_Name_ClearCache				; drop the status-line name slots - list changed
	jsr Nfo_Name_LoadManifest			; refill them from this folder's IMAGES.LST (if any)

	lda #$00
	sta Sel_Index
	sta Sel_Top
	sta File_Index
	rts

;-----------------------------------------------------------------------------
; Build_Spec_Prefix - Scan_Spec = "D[n]:" + Scan_Path.  Returns X = cursor.
;-----------------------------------------------------------------------------
Build_Spec_Prefix
	ldx #$00
	lda #'D'
	sta Scan_Spec,x
	inx
	lda Scan_Drive
	beq Build_Spec_Prefix_Colon			; $00 -> bare "D:"
	sta Scan_Spec,x
	inx
Build_Spec_Prefix_Colon
	lda #':'
	sta Scan_Spec,x
	inx
	ldy #$00
Build_Spec_Prefix_L1
	lda Scan_Path,y
	beq Build_Spec_Prefix_Done
	sta Scan_Spec,x
	inx
	iny
	cpy #$28
	bcc Build_Spec_Prefix_L1
Build_Spec_Prefix_Done
	rts

Build_Spec								; ... + "*.V1K" + EOL
	jsr Build_Spec_Prefix
	ldy #$00
Build_Spec_L1
	lda Build_Spec_ImgWild,y
	sta Scan_Spec,x
	inx
	iny
	cpy #$06
	bcc Build_Spec_L1
	rts

Build_Browse_Spec						; ... + "*.*" + EOL
	jsr Build_Spec_Prefix
	ldy #$00
Build_Browse_Spec_L1
	lda Build_Spec_AnyWild,y
	sta Scan_Spec,x
	inx
	iny
	cpy #$04
	bcc Build_Browse_Spec_L1
	rts

Build_Manifest_Spec						; ... + "IMAGES.LST" + EOL  (status-line names)
	jsr Build_Spec_Prefix
	ldy #$00
Build_Manifest_Spec_L1
	lda Build_Spec_ManifestName,y
	sta Scan_Spec,x
	inx
	iny
	cpy #$0B
	bcc Build_Manifest_Spec_L1
	rts

Build_Spec_ImgWild		dta c'*.V1K',$9B
Build_Spec_AnyWild		dta c'*.*',$9B
Build_Spec_ManifestName	dta c'IMAGES.LST',$9B

;-----------------------------------------------------------------------------
; Build_Image_List - rebuild the selector list in IMAGE_BANK through the $2000
; window, grouped:  ".."  (only below the drive root)  |  sub-directories  |
; *.V1K files.  Rescan_Images sorts the two real groups A-Z afterwards.
; Sets ImageCount, Dir_Count and FileStart (index of the first *.V1K row).
;   - directory pass: OPEN "D[n]:PATH*.*" long DIR format (AUX2 = $80) and keep
;     only lines carrying SDX's "<DIR>" size-column tag (Line_Has_Dir_Tag).
;   - file pass:      OPEN "D[n]:PATH*.V1K" short format (AUX2 = $00) as before.
; One 8-byte write cursor (Name_Ptr) and one ImageNames_End guard span both.
;-----------------------------------------------------------------------------
Build_Image_List
	lda #$00
	sta ImageCount
	sta ImageCount+1
	sta Dir_Count

	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	mwa #ImageNames Name_Ptr

; --- ".." at slot 0 whenever we are below the drive root
	lda Scan_Path
	beq Build_Image_List_Dirs
	ldy #$00
	lda #'.'
	sta (Name_Ptr),y
	iny
	sta (Name_Ptr),y
	iny
	lda #' '
Build_Image_List_DotPad
	sta (Name_Ptr),y
	iny
	cpy #$08
	bcc Build_Image_List_DotPad
	inc ImageCount
	jsr Build_Image_List_Adv

; --- directory pass : "D[n]:PATH*.*", long DIR format
Build_Image_List_Dirs
	jsr Build_Browse_Spec
	jsr Find_First_IOCB
	cpy #$01
	bne Build_Image_List_Files			; no free IOCB - skip to files
	stx Dir_IOCB
	lda #CIO_dir
	sta ICAX1,x
	lda #$80							; long DIR format -> subdirs carry "<DIR>"
	sta ICAX2,x
	lda #<Scan_Spec
	sta ICBAL,x
	lda #>Scan_Spec
	sta ICBAH,x
	lda #CIO_open
	sta ICCOM,x
	jsr CIOV
	bmi Build_Image_List_Files			; dir OPEN failed - still try files

Build_Image_List_DirL1
	jsr Build_Image_List_ReadLine
	bcs Build_Image_List_DirClose		; EOF / error
	jsr Build_Image_List_Full
	bcs Build_Image_List_DirL1			; list full - drain, store nothing
	jsr Parse_Dir_Line
	beq Build_Image_List_DirL1			; not a name line
	ldy #$00
	lda (Name_Ptr),y
	cmp #'.'
	beq Build_Image_List_DirL1			; "." / ".." listing line
	jsr Line_Has_Dir_Tag
	beq Build_Image_List_DirL1			; no "<DIR>" tag -> a file, skip
	inc ImageCount
	inc Dir_Count
	jsr Build_Image_List_Adv
	jmp Build_Image_List_DirL1

Build_Image_List_DirClose
	ldx Dir_IOCB
	lda #CIO_close
	sta ICCOM,x
	jsr CIOV

; --- file pass : "D[n]:PATH*.V1K", short format
Build_Image_List_Files
	lda ImageCount						; FileStart = rows so far (".." + dirs)
	sta FileStart

	jsr Build_Spec
	jsr Find_First_IOCB
	cpy #$01
	bne Build_Image_List_Unmap
	stx Dir_IOCB
	lda #CIO_dir
	sta ICAX1,x
	lda #$00							; short DIRS format
	sta ICAX2,x
	lda #<Scan_Spec
	sta ICBAL,x
	lda #>Scan_Spec
	sta ICBAH,x
	lda #CIO_open
	sta ICCOM,x
	jsr CIOV
	bmi Build_Image_List_Unmap			; OPEN failed - nothing to scan

Build_Image_List_FileL1
	jsr Build_Image_List_ReadLine
	bcs Build_Image_List_FileClose
	jsr Build_Image_List_Full
	bcs Build_Image_List_FileL1
	jsr Parse_Dir_Line
	beq Build_Image_List_FileL1
	inc ImageCount
	bne Build_Image_List_FileAdv
	inc ImageCount+1
Build_Image_List_FileAdv
	jsr Build_Image_List_Adv
	jmp Build_Image_List_FileL1

Build_Image_List_FileClose
	ldx Dir_IOCB
	lda #CIO_close
	sta ICCOM,x
	jsr CIOV

Build_Image_List_Unmap
	lda #MEMAC_GLOBAL_DISABLE			; give the CPU back $2000-$2FFF
	vbsta VBXE_MA_BSEL
	rts

; --- Build_Image_List helpers -----------------------------------------------
; GET RECORD one dir line into Dir_Line_Buf.  C=1 on EOF/error, C=0 on a line.
Build_Image_List_ReadLine
	ldx Dir_IOCB
	lda #CIO_gettext
	sta ICCOM,x
	lda #<Dir_Line_Buf
	sta ICBAL,x
	lda #>Dir_Line_Buf
	sta ICBAH,x
	lda #<Dir_Line_Len
	sta ICBLL,x
	lda #>Dir_Line_Len
	sta ICBLH,x
	jsr CIOV
	bmi Build_Image_List_ReadLine_EOF
	clc
	rts
Build_Image_List_ReadLine_EOF
	sec
	rts

; C=1 once the 8-byte write cursor has reached ImageNames_End (list full).
Build_Image_List_Full
	lda Name_Ptr+1
	cmp #>ImageNames_End
	bcc Build_Image_List_Full_Room
	bne Build_Image_List_Full_Yes
	lda Name_Ptr
	cmp #<ImageNames_End
	bcs Build_Image_List_Full_Yes
Build_Image_List_Full_Room
	clc
	rts
Build_Image_List_Full_Yes
	sec
	rts

; Advance the 8-byte write cursor.
Build_Image_List_Adv
	lda Name_Ptr
	clc
	adc #$08
	sta Name_Ptr
	bcc Build_Image_List_Adv_Done
	inc Name_Ptr+1
Build_Image_List_Adv_Done
	rts

;-----------------------------------------------------------------------------
; Parse_Dir_Line - pull the base filename out of one Dir_Line_Buf entry and
; write it space-padded to exactly 8 bytes at Name_Ptr.  Skips leading spaces
; and the '*' protect flag; stops the name at space/'.'/EOL.  Rejects an
; all-digit "name" (the trailing "nnn FREE SECTORS" line).
;  Returns A = $01 if a name was written, $00 if not.
;-----------------------------------------------------------------------------
Parse_Dir_Line
	ldx #$00							; X = source index into Dir_Line_Buf
Parse_Skip_L1							; Skip leading spaces / protect flag
	lda Dir_Line_Buf,x
	cmp #$9B
	beq Parse_Dir_Line_Reject			; Hit EOL before any name
	cmp #' '
	beq Parse_Skip_Next
	cmp #'*'
	bne Parse_Skip_Done
Parse_Skip_Next
	inx
	cpx #Dir_Line_Len
	bcc Parse_Skip_L1
	bcs Parse_Dir_Line_Reject			; Ran off the end
Parse_Skip_Done
	ldy #$00							; Y = dest index into the entry slot (0-7)
	lda #$00
	sta Reg1							; Reg1 = "saw a non-digit name char" flag

Parse_Copy_L1
	lda Dir_Line_Buf,x
	cmp #$9B
	beq Parse_Copy_Done
	cmp #' '
	beq Parse_Copy_Done
	cmp #'.'
	beq Parse_Copy_Done
	cmp #'0'
	bcc Parse_Copy_Is_Name_Char
	cmp #'9'+1
	bcs Parse_Copy_Is_Name_Char
	jmp Parse_Copy_Store				; '0'-'9' - a digit, don't set Reg1
Parse_Copy_Is_Name_Char
	inc Reg1
Parse_Copy_Store
	cpy #$08							; Slot bytes 0-7 hold up to 8 name chars
	bcs Parse_Copy_Next					; Name already full - keep scanning
	lda Dir_Line_Buf,x
	sta (Name_Ptr),y
	iny
Parse_Copy_Next
	inx
	cpx #Dir_Line_Len
	bcc Parse_Copy_L1

Parse_Copy_Done
	lda Reg1
	beq Parse_Dir_Line_Reject			; All digits - e.g. "nnn FREE SECTORS"

Parse_Pad_L1							; Right-pad the slot to a fixed 8 bytes
	cpy #$08
	bcs Parse_Dir_Line_Accept
	lda #' '
	sta (Name_Ptr),y
	iny
	bne Parse_Pad_L1

Parse_Dir_Line_Accept
	lda #$01							; Non-zero - a name was stored
	rts
Parse_Dir_Line_Reject
	lda #$00
	rts

;-----------------------------------------------------------------------------
; Emit_Path_Prefix - Path_Buf = "D[n]:" + Scan_Path.  Returns X = next index.
; Called by Build_Filename (view1024.asm) before it appends base + "." + ext.
;-----------------------------------------------------------------------------
Emit_Path_Prefix
	ldx #$00
	lda #'D'
	sta Path_Buf,x
	inx
	lda Scan_Drive
	beq Emit_Path_Prefix_Colon
	sta Path_Buf,x
	inx
Emit_Path_Prefix_Colon
	lda #':'
	sta Path_Buf,x
	inx
	ldy #$00
Emit_Path_Prefix_L1
	lda Scan_Path,y
	beq Emit_Path_Prefix_Done
	sta Path_Buf,x
	inx
	iny
	cpy #$28
	bcc Emit_Path_Prefix_L1
Emit_Path_Prefix_Done
	rts

;=============================================================================
; Selector screen
;=============================================================================

;-----------------------------------------------------------------------------
; Enter_Selector - build the selector in the back buffer (unseen), put the
; menu palettes back ONLY if an image replaced them (Pal_Image - after Info,
; Drive, Quit or a directory P-preview the registers are already right), then
; show the finished screen: one Text_Present + an XDL switch.  When palettes
; have to be rewritten the overlay is blanked for those ~2 frames, so neither
; the image nor the logo is ever seen in the wrong colours.  The logo's VRAM
; is never touched.  Reached from start: (jsr), Handle_Escape (jsr),
; Slide_Key_Stop (jsr), Pal_Preview_Keys (jsr) and Info_Key_Leave (jsr) -
; always returns.
;-----------------------------------------------------------------------------
Enter_Selector
	lda #$00
	sta UI_Mode
	jsr Selector_Draw					; back buffer only - nothing visible yet
	lda Pal_Image
	beq Enter_Selector_Show				; menu palettes still in the registers
	jsr Display_Off						; blank while the registers are rewritten
	jsr Apply_Menu_Palettes				; text set 0 + banner sets 1-3, clears Pal_Image
	jsr Text_Present
	jsr Text_Activate
	jmp Display_On						; (tail)
Enter_Selector_Show
	jsr Text_Present					; the finished screen, in one blit
	jmp Text_Activate					; (tail) a pure XDL swap

;-----------------------------------------------------------------------------
; UI_Build_TextPalette - the standard Atari 256-colour master (NTSC $00200 /
; PAL $00500, per Video_Flag) has its entries 0-127 in hues 0-7 only (no
; green), and the VBXE text mode can only reach entries 0-127 as a foreground.
; De-interleave it so:
;     entry e        (0..127) = master colour 2e    (all 16 hues, even lumas)
;     entry 128+e             = master colour 2e+1  (odd lumas - inverse bg)
; Build a page-aligned 768-byte image at VBXE $00800 (free: NTSC master
; $00200-$004FF, PAL master $00500-$007FF, VRAM from $01000).  Runs ONCE, from
; start: - the buffer stays resident (Clear_Screen starts at $01000) and
; Apply_Menu_Palettes (view1024.asm) uploads it as set 0 whenever needed.
; Restore_Palette0 itself is left untouched so the DOS-exit path still restores
; the true master.  Clobbers A/X/Y, Ptr_Lo/Hi, Name_Ptr.
;-----------------------------------------------------------------------------
UI_APPLY_TP_BUF		= VBXE_WINDOW + $800		; page-aligned de-interleave buffer

UI_Build_TextPalette
	lda #$00 | MEMAC_GLOBAL_ENABLE				; map VBXE bank $00 into the window
	vbsta VBXE_MA_BSEL

; --- pass 1: even master colours -> buf[0..127]
	jsr UI_Apply_TP_SrcBase
	lda #<UI_APPLY_TP_BUF
	sta Name_Ptr
	lda #>UI_APPLY_TP_BUF
	sta Name_Ptr+1
	jsr UI_Apply_TP_Pass

; --- pass 2: odd master colours -> buf[128..255]
	jsr UI_Apply_TP_SrcBase
	lda Ptr_Lo
	clc
	adc #$03									; step onto the first odd triplet
	sta Ptr_Lo
	bcc UI_Apply_TP_P2Dst
	inc Ptr_Hi
UI_Apply_TP_P2Dst
	lda #<[UI_APPLY_TP_BUF + $180]				; buf + 128*3
	sta Name_Ptr
	lda #>[UI_APPLY_TP_BUF + $180]
	sta Name_Ptr+1
	jsr UI_Apply_TP_Pass

	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

; Ptr_Lo/Hi = active master base ($2500 PAL / $2200 NTSC), mirrors Restore_Palette0
UI_Apply_TP_SrcBase
	lda Video_Flag						; 0 = PAL, non-zero = NTSC
	bne UI_Apply_TP_SrcNTSC
	lda #<(VBXE_WINDOW + $500)
	sta Ptr_Lo
	lda #>(VBXE_WINDOW + $500)
	sta Ptr_Hi
	rts
UI_Apply_TP_SrcNTSC
	lda #<(VBXE_WINDOW + $200)
	sta Ptr_Lo
	lda #>(VBXE_WINDOW + $200)
	sta Ptr_Hi
	rts

; Copy 128 RGB triplets (Ptr_Lo) -> (Name_Ptr); src += 6, dst += 3 each entry.
UI_Apply_TP_Pass
	ldx #$80							; 128 entries
UI_Apply_TP_Pass_L1
	ldy #$00
UI_Apply_TP_Pass_Cp
	lda (Ptr_Lo),y
	sta (Name_Ptr),y
	iny
	cpy #$03
	bcc UI_Apply_TP_Pass_Cp

	lda Ptr_Lo
	clc
	adc #$06
	sta Ptr_Lo
	bcc UI_Apply_TP_Pass_Dst
	inc Ptr_Hi
UI_Apply_TP_Pass_Dst
	lda Name_Ptr
	clc
	adc #$03
	sta Name_Ptr
	bcc UI_Apply_TP_Pass_Next
	inc Name_Ptr+1
UI_Apply_TP_Pass_Next
	dex
	bne UI_Apply_TP_Pass_L1
	rts

;-----------------------------------------------------------------------------
; Selector_Draw - full repaint of the back buffer (shown by the caller's
; Text_Present, or by Read_Key_Done).  Only entered from Enter_Selector (boot /
; ESC) and after a rescan; the nav / delay keys repaint just what changed.
;-----------------------------------------------------------------------------
Selector_Draw
	jsr Text_Clear
	jsr Selector_DrawLocRow				; row 0 (its counter: Selector_DrawStatus)
											; row 1 stays blank - see the row map above

	jsr Selector_DrawList

	jsr UI_Pen_Normal
	TXT_AT 21, 0, UI_Str_Delay			; "Cfg:"
	TXT_AT 21, 7, UI_Str_DelayHint		; " sec (< Less > More) ... HELP ..."
	jsr Selector_DrawLegend				; row 22 "Nav: ..."
	jsr Selector_DrawDelay				; the delay value at cols 5-6
	jmp Selector_DrawStatus				; row 20: the highlighted image's description

;-----------------------------------------------------------------------------
; Selector_DrawLegend - row 22 "Nav: ...".  The arrows are the CP437 codes
; $18 $19 $1B $1A, which the Atari font carries too (Text_Load_Fonts), so the
; legend is right in either font with no redraw.
;-----------------------------------------------------------------------------
Selector_DrawLegend
	jsr UI_Pen_Normal
	TXT_AT 22, 0, UI_Str_Legend
	rts

;-----------------------------------------------------------------------------
; Selector_DrawLocRow - row 0: "Location: " + the current path, the rest of
; the row (old path / busy message / counter) blanked.  Selector_DrawCount
; puts the right-hand counter back - Selector_Restore_LocRow does both.
;-----------------------------------------------------------------------------
Selector_DrawLocRow
	jsr UI_Pen_LocRow					; "Location: " and the path, one colour
	TXT_AT 0, 2, UI_Str_Loc
	TXT_AT 0, 12, UI_Str_StatusBlank+12	; 68 spaces: clear cols 12-79
	jsr UI_Build_LocLine
	TXT_AT 0, 12, Txt_Line
	rts

; Row 0 back to normal after a UI_Show_Busy whose load failed - the selector
; stays up.  Shown by Read_Key_Done.
Selector_Restore_LocRow
	jsr Selector_DrawLocRow
	jmp Selector_DrawCount				; (tail)

;-----------------------------------------------------------------------------
; UI_Show_Busy - A/Y = lo/hi of a NUL-terminated message.  Shows it in row 0
; in the path's place ("Location: " stays, the rest of the row is blanked) and
; PRESENTS it at once: the caller is about to do slow disk I/O, during which
; no key loop runs.  The rest of the screen stays as it was.
;-----------------------------------------------------------------------------
UI_Show_Busy
	pha									; message lo
	tya
	pha									; message hi
	jsr UI_Pen_LocRow
	TXT_AT 0, 2, UI_Str_Loc				; label too - not drawn yet at boot
	TXT_AT 0, 12, UI_Str_StatusBlank+12	; 68 spaces: clear the old path + counter
	pla
	sta Txt_Ptr + $01
	pla
	sta Txt_Ptr
	jsr Text_PutStrAt					; the message (Txt_Row/Col still 0/12)
	jmp Text_Present					; (tail) on screen now, before the I/O

;-----------------------------------------------------------------------------
Selector_DrawList
	lda ImageCount
	ora ImageCount+1
	bne Selector_DrawList_Have
	jsr UI_Pen_Normal
	TXT_AT UI_FIRSTROW, UI_GRIDCOL0, UI_Str_Empty
	rts
Selector_DrawList_Have
	lda #$00
	sta Reg5							; Reg5 = cell index within the window, 0..VISROWS*COLS-1
Selector_DrawList_L1
	lda Reg5
	cmp #[UI_VISROWS*UI_COLS]
	bcs Selector_DrawList_Tail
	clc
	adc Sel_Top
	sta Reg6							; Reg6 = list index for this cell
	cmp ImageCount
	bcs Selector_DrawList_Tail			; past the end of the list

	lda Reg6
	ldx #IMAGE_BANK
	jsr UI_ReadRec						; Name_Row_Buf = raw names[Reg6]
	lda Reg6
	jsr UI_RowType						; A = row type (0 file / 1 dir / 2 "..")
	jsr UI_Format_Row					; Name_Row_Buf -> fixed 10-char field

	lda Reg5
	lsr
	lsr
	lsr								; A = grid row = cell index / UI_COLS
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	lda Reg5
	and #[UI_COLS-1]					; A = grid column = cell index MOD UI_COLS
	tax
	lda Sel_ColX,x
	sta Txt_Col

	lda Reg6
	jsr UI_Name_Pen						; A = the cell's pen
	jsr UI_DrawNameRow
	inc Reg5
	jmp Selector_DrawList_L1

Selector_DrawList_Tail
; list has rows but none are *.V1K files -> note it one row below the last entry
	lda FileStart
	cmp ImageCount
	bcc Selector_DrawList_Done			; some files present
	lda ImageCount
	beq Selector_DrawList_Done			; wholly empty -> UI_Str_Empty already drawn
	lda ImageCount
	sec
	sbc #$01							; A = index of the last occupied cell
	sec
	sbc Sel_Top							; A = that index, relative to the window top
	lsr
	lsr
	lsr								; A = relative grid row of the last item
	clc
	adc #$01							; A = relative row of the note (one row below)
	cmp #UI_VISROWS
	bcs Selector_DrawList_Done			; note's row is off-screen
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	jsr UI_Pen_Normal
	lda Sel_ColX						; column 0 of the grid
	sta Txt_Col
	lda #<UI_Str_Empty
	sta Txt_Ptr
	lda #>UI_Str_Empty
	sta Txt_Ptr + $01
	jsr Text_PutStrAt
Selector_DrawList_Done
	rts

;-----------------------------------------------------------------------------
; Selector_HiRow - A = list index.  Recolours just that cell's name field
; (attribute bytes only, via the blitter - no glyph redraw), highlighted if the
; index == Sel_Index, else normal.  No-op if the cell isn't on screen.  Used by
; the nav keys: a cursor move only changes which cell carries the highlight.
;-----------------------------------------------------------------------------
Selector_HiRow
	sta Reg6							; Reg6 = list index
	cmp ImageCount
	bcs Selector_HiRow_Skip				; past the end of the list
	lsr
	lsr
	lsr
	sta Reg3							; Reg3 = item_row (index / UI_COLS)
	lda Sel_Top
	lsr
	lsr
	lsr								; A = top_row (Sel_Top / UI_COLS)
	sta Reg1							; Reg1 = top_row
	lda Reg3
	sec
	sbc Reg1							; A = item_row - top_row
	bcc Selector_HiRow_Skip				; item_row < top_row - above the window
	cmp #UI_VISROWS
	bcs Selector_HiRow_Skip				; below the window
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	lda Reg6
	and #[UI_COLS-1]					; A = grid column = index MOD UI_COLS
	tax
	lda Sel_ColX,x
	sta Txt_Col
	lda #9
	sta Reg1							; width-1 = 10 cells ("<NAME....>")
	lda #$00
	sta Reg2							; height-1 = 1 row
	lda Reg6
	jsr UI_Name_Pen						; file / dir pen, highlighted or not
	jmp Text_FillColour					; tail (foreground only - no bar)
Selector_HiRow_Skip
	rts

;-----------------------------------------------------------------------------
; UI_Name_Pen - A = list index -> A = that grid cell's pen: file or dir/".."
; (UI_RowType), highlighted when the index == Sel_Index.  Clobbers X only -
; Selector_HiRow's Reg1/Reg2/Txt_Row/Txt_Col survive.
;-----------------------------------------------------------------------------
UI_Name_Pen
	pha
	jsr UI_RowType						; A = 0 file / 1 dir / 2 ".."
	beq UI_Name_Pen_Type
	lda #$01							; dir and ".." share a pen
UI_Name_Pen_Type
	tax									; X = 0 file / 1 dir
	pla
	cmp Sel_Index
	bne UI_Name_Pen_Normal
	inx
	inx									; X += 2 -> the highlighted pair
UI_Name_Pen_Normal
	lda UI_Name_Pen_Tab,x
	rts

UI_Name_Pen_Tab
	dta UI_PEN_FILE,UI_PEN_DIR			; normal
	dta UI_PEN_FILEHI,UI_PEN_DIRHI		; highlighted (Sel_Index)

;-----------------------------------------------------------------------------
; Selector_DrawDelay - repaint just the slideshow-delay value (row 21, cols
; 5-6): a 2-char field, right-aligned (" 5" / "30"), so 10 -> 9 doesn't leave
; a stale digit.  UI_SLIDE_MAX (30) always fits in 2 digits.
;-----------------------------------------------------------------------------
Selector_DrawDelay
	jsr UI_Pen_Values
	lda Slide_Secs
	jsr Put_U8_Dec_Line					; Txt_Line = "N" / "NN", NUL
	lda Txt_Line+1
	bne Selector_DrawDelay_Put			; already 2 digits
	lda Txt_Line						; 1 digit: shift it right, space in front
	sta Txt_Line+1
	lda #' '
	sta Txt_Line
	lda #$00
	sta Txt_Line+2
Selector_DrawDelay_Put
	TXT_AT 21, 5, Txt_Line
	rts

;=============================================================================
; Selector status line (row 20) - the highlighted image's description (typed
; in the converter, default = source filename without extension; up to
; NFO_NAME_CAP = 75 chars).  Reading a file per row stuttered a fresh
; directory, so instead the converter writes all the descriptions once into
; "IMAGES.LST" (8-byte key + description per record) beside the images.  Nfo_Name_LoadManifest slurps that in one pass on every
; Rescan_Images into NFO_NAME_VRAM (NFO_NAME_SLOT bytes/ordinal); the draw path
; is then a pure VRAM read.  No IMAGES.LST -> every slot stays $00 -> the line
; is simply blank.
;=============================================================================

;-----------------------------------------------------------------------------
; Nfo_Name_ClearCache - blitter-wipe NFO_NAME_VRAM to $00 (every slot "no
; name").  Kicks BLT_NFO_NAME_CLEAR and waits (Nfo_Name_LoadManifest fills
; after).
;-----------------------------------------------------------------------------
Nfo_Name_ClearCache
	lda #BLT_NFO_NAME_CLEAR-BLT_CLEAR
	vbsta VBXE_BL_ADR0
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Nfo_Name_ClearCache_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Nfo_Name_ClearCache_L1
	lda #$01
	vbsta VBXE_BLITTER_START
Nfo_Name_ClearCache_L2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Nfo_Name_ClearCache_L2
	rts

;-----------------------------------------------------------------------------
; Selector_DrawCount - row 0's right-hand image counter for the current
; Sel_Index: "nnn of NNN" on a *.V1K row, else "NNN images" (" image " for
; one) - always 10 chars at UI_COUNT_COL, numbers space-padded to 3.  NNN =
; ImageCount - FileStart (the *.V1K group only).  Builds it in Txt_Line.
; Clobbers A/X/Y, Reg1, Reg2, Reg7, Txt_Ptr.
;-----------------------------------------------------------------------------
Selector_DrawCount
	lda ImageCount
	sec
	sbc FileStart
	sta Reg7							; Reg7 = image count (<= MAX_IMAGES)
	beq Selector_DrawCount_Total
	lda Sel_Index
	jsr UI_RowType
	bne Selector_DrawCount_Total		; dir / ".." -> just the total
	lda Sel_Index
	sec
	sbc FileStart						; ordinal into the *.V1K group ...
	clc
	adc #$01							; ... counted from 1
	ldx #$00
	jsr Put_U8_Pad3
	lda #<UI_Str_Of
	ldy #>UI_Str_Of
	jsr Selector_DrawCount_Cat
	lda Reg7
	jsr Put_U8_Pad3
	lda #$00
	sta Txt_Line,x
	jmp Selector_DrawCount_Put
Selector_DrawCount_Total
	ldx #$00
	lda Reg7
	jsr Put_U8_Pad3
	lda #<UI_Str_Images
	ldy #>UI_Str_Images
	ldx Reg7
	dex
	bne Selector_DrawCount_Plural
	lda #<UI_Str_Image1
	ldy #>UI_Str_Image1
Selector_DrawCount_Plural
	ldx #$03							; after the 3-char number
	jsr Selector_DrawCount_Cat
Selector_DrawCount_Put
	lda #UI_PEN_COUNT
	ldx #$00
	jsr Text_SetPen
	lda #$00
	sta Txt_Row
	lda #UI_COUNT_COL
	sta Txt_Col
	lda #<Txt_Line
	sta Txt_Ptr
	lda #>Txt_Line
	sta Txt_Ptr + $01
	jmp Text_PutStrAt

; Append the NUL-terminated string at A/Y (lo/hi) to Txt_Line at X, NUL
; included; returns X on that NUL.
Selector_DrawCount_Cat
	sta Txt_Ptr
	sty Txt_Ptr + $01
	ldy #$00
Selector_DrawCount_Cat_L1
	lda (Txt_Ptr),y
	sta Txt_Line,x
	beq Selector_DrawCount_Cat_Done
	inx
	iny
	bne Selector_DrawCount_Cat_L1
Selector_DrawCount_Cat_Done
	rts

;-----------------------------------------------------------------------------
; Selector_DrawStatus - repaint row 20 for the current Sel_Index, and row 0's
; image counter (Selector_DrawCount).  "Nfo: " is always shown at col 0; cols
; 5-79 hold the name for a *.V1K row whose slot was filled from IMAGES.LST,
; or are cleared (75 spaces) for a directory / ".." row or an empty list.
; Pure VRAM read - no file I/O.
;-----------------------------------------------------------------------------
Selector_DrawStatus
	jsr Selector_DrawCount
	lda #UI_PEN_NFO						; "Nfo: " colours itself; the description
	ldx #$00							; (cols 5-79) is UI_PEN_NFO
	jsr Text_SetPen
	TXT_AT 20, 0, UI_Str_Nfo			; "Nfo: " - always present
	lda #$05
	sta Txt_Col							; Txt_Row is still 20
	lda ImageCount
	ora ImageCount+1
	beq Selector_DrawStatus_Blank
	lda Sel_Index
	jsr UI_RowType
	bne Selector_DrawStatus_Blank		; dir / ".." -> no source name
	lda Sel_Index
	sec
	sbc FileStart						; ordinal into the *.V1K group
	sta Nfo_Name_Ord
	jsr Nfo_Name_MapSlot				; Ptr_Lo/Hi -> slot, bank $37..$3E mapped
	jsr Nfo_Name_Emit					; Nfo_Name_Line = name padded to NFO_NAME_CAP + NUL
	lda #<Nfo_Name_Line
	sta Txt_Ptr
	lda #>Nfo_Name_Line
	sta Txt_Ptr + $01
	jmp Text_PutStrAt					; the padded name from col 5 to 79 (tail)
Selector_DrawStatus_Blank
	lda #<[UI_Str_StatusBlank+5]
	sta Txt_Ptr
	lda #>[UI_Str_StatusBlank+5]
	sta Txt_Ptr + $01
	jmp Text_PutStrAt					; clear cols 5-79 (75 spaces) (tail)

;-----------------------------------------------------------------------------
; Nfo_Name_MapSlot - Nfo_Name_Ord -> Ptr_Lo/Hi = the slot's $2000-window
; address, its VBXE bank ($37..$3E) mapped in.  slot byte offset = Ord * 128:
; bank = $37 + (Ord >> 5), window page = $20 + ((Ord >> 1) & 15),
; window low = (Ord & 1) << 7.  (128 divides 4K, so a slot never straddles.)
;-----------------------------------------------------------------------------
Nfo_Name_MapSlot
	lda Nfo_Name_Ord
	lsr									; C = Ord & 1
	lda #$00
	ror									; A = (Ord & 1) << 7
	sta Ptr_Lo
	lda Nfo_Name_Ord
	lsr
	and #$0F							; (Ord >> 1) & 15
	clc
	adc #>VBXE_WINDOW					; -> $20..$2F
	sta Ptr_Hi
	lda Nfo_Name_Ord
	lsr
	lsr
	lsr
	lsr
	lsr									; Ord >> 5  (0..7)
	clc
	adc #NFO_NAME_BANK
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	rts

;-----------------------------------------------------------------------------
; Nfo_Name_Emit - the slot Nfo_Name_MapSlot just mapped (at Ptr_Lo/Hi) in.
; Leaves Nfo_Name_Line[0..NFO_NAME_CAP-1] = the name (or all spaces if the
; slot byte 0 is < $21, i.e. "no name") + Nfo_Name_Line[NFO_NAME_CAP] = $00.
; Window unmapped on return.
;-----------------------------------------------------------------------------
Nfo_Name_Emit
	ldy #$00
	lda (Ptr_Lo),y
	cmp #$21
	bcc Nfo_Name_Emit_Pad				; $00 -> all spaces
Nfo_Name_Emit_Copy
	lda (Ptr_Lo),y
	beq Nfo_Name_Emit_Pad
	sta Nfo_Name_Line,y
	iny
	cpy #NFO_NAME_CAP
	bcc Nfo_Name_Emit_Copy
	bcs Nfo_Name_Emit_Term
Nfo_Name_Emit_Pad
	lda #$20
Nfo_Name_Emit_PadL
	cpy #NFO_NAME_CAP
	bcs Nfo_Name_Emit_Term
	sta Nfo_Name_Line,y
	iny
	bne Nfo_Name_Emit_PadL				; always (Y < NFO_NAME_CAP)
Nfo_Name_Emit_Term
	lda #$00
	sta Nfo_Name_Line + NFO_NAME_CAP
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

;-----------------------------------------------------------------------------
; Nfo_Name_LoadManifest - open "D[n]:PATH IMAGES.LST", and for every record
; (8-byte key + description + $9B) store it into the matching *.V1K
; row's slot.  Called from Rescan_Images right after Nfo_Name_ClearCache.
; A missing / unreadable file just leaves every slot $00 (blank status line).
;-----------------------------------------------------------------------------
Nfo_Name_LoadManifest
	jsr Build_Manifest_Spec				; Scan_Spec = "D[n]:PATH" + "IMAGES.LST" + $9B
	jsr Find_First_IOCB
	cpy #$01
	bne Nfo_Name_LoadManifest_Done		; no free IOCB
	stx Dir_IOCB
	lda #CIO_read						; AUX1 = 4 : plain file, read
	sta ICAX1,x
	lda #$00
	sta ICAX2,x
	lda #<Scan_Spec
	sta ICBAL,x
	lda #>Scan_Spec
	sta ICBAH,x
	lda #CIO_open
	sta ICCOM,x
	jsr CIOV
	bmi Nfo_Name_LoadManifest_Done		; no IMAGES.LST here

Nfo_Name_LoadManifest_Line
	ldx Dir_IOCB
	lda #CIO_gettext
	sta ICCOM,x
	lda #<Nfo_Name_Line
	sta ICBAL,x
	lda #>Nfo_Name_Line
	sta ICBAH,x
	lda #8+NFO_NAME_CAP+1				; buffer length (8 key + 75 desc + $9B = 84)
	sta ICBLL,x
	lda #$00
	sta ICBLH,x
	jsr CIOV
	bpl Nfo_Name_LoadManifest_Got
	cpy #$89							; 137 = record over 84 bytes: CIO kept the first 84
	bne Nfo_Name_LoadManifest_Close		; EOF / real error -> stop
Nfo_Name_LoadManifest_Got				; (a long record is cut to NFO_NAME_CAP below, not dropped)

	jsr Nfo_Name_Match					; key = Nfo_Name_Line[0..7]  -> A = ordinal
	bcs Nfo_Name_LoadManifest_Line		; no matching *.V1K row - drop the line
	sta Nfo_Name_Ord
	jsr Nfo_Name_MapSlot				; Ptr_Lo/Hi -> slot, bank $37..$3E mapped
	ldy #$00
Nfo_Name_LoadManifest_Copy
	lda Nfo_Name_Line + 8,y
	cmp #$9B
	beq Nfo_Name_LoadManifest_CopyEnd	; end of record
	cmp #$20
	bcc Nfo_Name_LoadManifest_CopyEnd	; NUL / control -> stop
	sta (Ptr_Lo),y
	iny
	cpy #NFO_NAME_CAP
	bcc Nfo_Name_LoadManifest_Copy
Nfo_Name_LoadManifest_CopyEnd
	lda #$00
	sta (Ptr_Lo),y						; NUL-terminate (Y may be 0 -> "no name")
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	jmp Nfo_Name_LoadManifest_Line

Nfo_Name_LoadManifest_Close
	ldx Dir_IOCB
	lda #CIO_close
	sta ICCOM,x
	jsr CIOV
Nfo_Name_LoadManifest_Done
	rts

;-----------------------------------------------------------------------------
; Nfo_Name_Match - the 8-byte key at Nfo_Name_Line in.  Linear-scans the *.V1K
; group of the name list (rows FileStart .. ImageCount-1) in IMAGE_BANK for a
; byte-exact match.  Returns A = ordinal (row - FileStart), C=0 on a hit;
; C=1 and A undefined if none.  Maps + unmaps IMAGE_BANK itself.
;-----------------------------------------------------------------------------
Nfo_Name_Match
	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #$00
	sta Reg1							; Reg1 = ordinal under test
Nfo_Name_Match_Row
	lda FileStart
	clc
	adc Reg1
	cmp ImageCount						; FileStart + ord >= ImageCount -> exhausted
	bcs Nfo_Name_Match_None
; Ptr_Lo/Hi = ImageNames + (FileStart + ord) * 8
	sta Reg2							; Reg2 = row index
	lda #$00
	sta Ptr_Hi
	lda Reg2
	asl
	rol Ptr_Hi
	asl
	rol Ptr_Hi
	asl
	rol Ptr_Hi							; A:Ptr_Hi = row * 8
	clc
	adc #<ImageNames
	sta Ptr_Lo
	lda Ptr_Hi
	adc #>ImageNames
	sta Ptr_Hi
	ldy #$00
Nfo_Name_Match_Cmp
	lda (Ptr_Lo),y
	cmp Nfo_Name_Line,y
	bne Nfo_Name_Match_Next
	iny
	cpy #$08
	bcc Nfo_Name_Match_Cmp
	lda #MEMAC_GLOBAL_DISABLE			; all 8 equal -> hit
	vbsta VBXE_MA_BSEL
	lda Reg1
	clc
	rts
Nfo_Name_Match_Next
	inc Reg1
	bne Nfo_Name_Match_Row				; ord wraps past 255 -> give up
Nfo_Name_Match_None
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	sec
	rts

;-----------------------------------------------------------------------------
; UI_DrawNameRow - A = pen (from UI_Name_Pen).  Draws Name_Row_Buf (already
; formatted by UI_Format_Row) at Txt_Row/Txt_Col - the caller
; (Selector_DrawList) sets both before calling.
;-----------------------------------------------------------------------------
UI_DrawNameRow
	ldx #$00							; transparent background
	jsr Text_SetPen
	lda #<Name_Row_Buf
	sta Txt_Ptr
	lda #>Name_Row_Buf
	sta Txt_Ptr + $01
	jmp Text_PutStrAt					; tail call

;-----------------------------------------------------------------------------
; UI_RowType - A = list index -> A = 0 file / 1 directory / 2 "..".
; Z is set iff the row is a file.  The list is grouped ".." | dirs | files,
; so the type is FileStart / Dir_Count / Scan_Path arithmetic, not a stored byte.
;-----------------------------------------------------------------------------
UI_RowType
	cmp FileStart
	bcs UI_RowType_File					; index >= FileStart -> *.V1K file
	tax									; index < FileStart
	bne UI_RowType_Dir					; index != 0 -> a directory
	lda Scan_Path
	beq UI_RowType_Dir					; at root: slot 0 is a directory
	lda #$02							; below root: slot 0 is ".."
	rts
UI_RowType_Dir
	lda #$01
	rts
UI_RowType_File
	lda #$00
	rts

;-----------------------------------------------------------------------------
; UI_Format_Row - A = row type (from UI_RowType).  Rewrites Name_Row_Buf (which
; holds the raw 8-byte record from UI_ReadRec) as a fixed 10-char space-padded
; field + NUL:  file -> "NAME    " ; dir -> "<NAME....>" ; ".." -> ".."  .
; A fixed width means scrolling onto a shorter entry leaves no stale glyphs.
; Uses Txt_Line as scratch for the directory case.
;-----------------------------------------------------------------------------
UI_Format_Row
	cmp #$02
	beq UI_Format_Up
	cmp #$01
	beq UI_Format_Dir
; file: the record is already space-padded to 8 - just widen to 10 + NUL
	ldy #$08
	lda #' '
	sta Name_Row_Buf,y
	iny
	sta Name_Row_Buf,y
	iny
	lda #$00
	sta Name_Row_Buf,y
	rts
UI_Format_Up
	lda #'.'
	sta Name_Row_Buf+0
	sta Name_Row_Buf+1
	ldy #$02
UI_Format_Up_Pad
	lda #' '
	sta Name_Row_Buf,y
	iny
	cpy #$0A
	bcc UI_Format_Up_Pad
	lda #$00
	sta Name_Row_Buf,y
	rts
UI_Format_Dir
	ldy #$00							; stash the raw name in Txt_Line
UI_Format_Dir_Cp
	lda Name_Row_Buf,y
	sta Txt_Line,y
	iny
	cpy #$08
	bcc UI_Format_Dir_Cp
	lda #'<'
	sta Name_Row_Buf+0
	ldx #$01							; X = write index into Name_Row_Buf
	ldy #$00							; Y = read index into Txt_Line
UI_Format_Dir_Name
	lda Txt_Line,y
	cmp #' '
	beq UI_Format_Dir_Close
	sta Name_Row_Buf,x
	inx
	iny
	cpy #$08
	bcc UI_Format_Dir_Name
UI_Format_Dir_Close
	lda #'>'
	sta Name_Row_Buf,x
	inx
UI_Format_Dir_Pad
	cpx #$0A
	bcs UI_Format_Dir_End
	lda #' '
	sta Name_Row_Buf,x
	inx
	bne UI_Format_Dir_Pad
UI_Format_Dir_End
	lda #$00
	sta Name_Row_Buf,x
	rts

;-----------------------------------------------------------------------------
UI_Pen_Normal
	lda #UI_PEN_FG
	ldx #$00							; transparent background
	jmp Text_SetPen
UI_Pen_HelpBody
	lda #UI_PEN_HELP
	ldx #$00
	jmp Text_SetPen
UI_Pen_Invert							; the drive picker's highlighted row (foreground only)
	lda #UI_PEN_HI
	ldx #$00							; transparent bg - no bar after the palette repack
	jmp Text_SetPen
UI_Pen_Frame							; popup window frames
	lda #UI_PEN_FRAMEC
	ldx #$00
	jmp Text_SetPen
UI_Pen_LocRow	; row 0 "Location: " + path
	lda #UI_PEN_LOC
	ldx #$00
	jmp Text_SetPen
UI_Pen_Values							; values after a label (path, delay, count, Nfo name)
	lda #UI_PEN_VALUE
	ldx #$00
	jmp Text_SetPen

;-----------------------------------------------------------------------------
; UI_ReadRec - A = record index, X = VBXE bank.  Copies the 8-byte record from
; that bank's $2000-window into Name_Row_Buf and NUL-terminates it.
; Clobbers A/X/Y, Reg2, Reg7, Reg8, Name_Ptr.
;-----------------------------------------------------------------------------
UI_ReadRec
	stx Reg2							; Reg2 = bank (Sort_SetNamePtr eats Reg7/8)
	jsr Sort_SetNamePtr					; Name_Ptr = ImageNames + A*8
	lda Reg2
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	ldy #$00
UI_ReadRec_L1
	lda (Name_Ptr),y
	sta Name_Row_Buf,y
	iny
	cpy #$08
	bcc UI_ReadRec_L1
	lda #$00
	sta Name_Row_Buf,y
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

;-----------------------------------------------------------------------------
; UI_Build_LocLine - Txt_Line = "D[n]:" + Scan_Path , NUL-terminated.
;-----------------------------------------------------------------------------
UI_Build_LocLine
	ldx #$00
	lda #'D'
	sta Txt_Line,x
	inx
	lda Scan_Drive
	beq UI_Build_LocLine_Colon
	sta Txt_Line,x
	inx
UI_Build_LocLine_Colon
	lda #':'
	sta Txt_Line,x
	inx
	ldy #$00
UI_Build_LocLine_Path
	lda Scan_Path,y
	beq UI_Build_LocLine_End
	sta Txt_Line,x
	inx
	iny
	cpy #$28
	bcc UI_Build_LocLine_Path
UI_Build_LocLine_End
	lda #$00
	sta Txt_Line,x
	rts

;-----------------------------------------------------------------------------
; Put_U8_Pad3 - A = 0..255 -> 3 chars at Txt_Line,X, right-aligned with
; leading spaces ("  7", " 42", "255"); X advanced by 3, no NUL.
; Clobbers A/Y, Reg1, Reg2.
;-----------------------------------------------------------------------------
Put_U8_Pad3
	sta Reg1							; Reg1 = remaining value
	lda #$00
	sta Reg2							; Reg2 = "emitted a digit" flag
	ldy #$00
Put_U8_Pad3_H
	lda Reg1
	cmp #100
	bcc Put_U8_Pad3_HDone
	sbc #100
	sta Reg1
	iny
	bne Put_U8_Pad3_H
Put_U8_Pad3_HDone
	tya
	jsr Put_U8_Pad3_Digit
	ldy #$00
Put_U8_Pad3_T
	lda Reg1
	cmp #10
	bcc Put_U8_Pad3_TDone
	sbc #10
	sta Reg1
	iny
	bne Put_U8_Pad3_T
Put_U8_Pad3_TDone
	tya
	jsr Put_U8_Pad3_Digit
	lda Reg1
	ora #'0'							; ones digit - always shown
	bne Put_U8_Pad3_Store
; A = digit 0-9: a space while it's still a leading zero, else the digit
Put_U8_Pad3_Digit
	bne Put_U8_Pad3_Emit
	ldy Reg2
	bne Put_U8_Pad3_Emit				; a zero after a digit -> '0'
	lda #' '
	bne Put_U8_Pad3_Store
Put_U8_Pad3_Emit
	ora #'0'
	inc Reg2
Put_U8_Pad3_Store
	sta Txt_Line,x
	inx
	rts

;-----------------------------------------------------------------------------
; Put_U8_Dec_Line - A = 0..255 -> Txt_Line = decimal text, NUL-terminated,
; no leading zeros.  Clobbers A/X/Y, Reg1, Reg2.
;-----------------------------------------------------------------------------
Put_U8_Dec_Line
	sta Reg2							; Reg2 = remaining value
	ldx #$00							; X = write index into Txt_Line
	lda #$00
	sta Reg1							; Reg1 = "emitted a digit" flag
	ldy #$00
Put_U8_H
	lda Reg2
	cmp #100
	bcc Put_U8_HDone
	sbc #100
	sta Reg2
	iny
	bne Put_U8_H
Put_U8_HDone
	cpy #$00
	beq Put_U8_T
	tya
	ora #'0'
	sta Txt_Line,x
	inx
	inc Reg1
Put_U8_T
	ldy #$00
Put_U8_TL
	lda Reg2
	cmp #10
	bcc Put_U8_TDone
	sbc #10
	sta Reg2
	iny
	bne Put_U8_TL
Put_U8_TDone
	cpy #$00
	bne Put_U8_TEmit
	lda Reg1
	beq Put_U8_O							; suppress a leading zero
Put_U8_TEmit
	tya
	ora #'0'
	sta Txt_Line,x
	inx
Put_U8_O
	lda Reg2
	ora #'0'
	sta Txt_Line,x
	inx
	lda #$00
	sta Txt_Line,x
	rts

;=============================================================================
; Selector keys  (UI_Mode = 0)
;=============================================================================
Selector_Keys
	lda CH
	and #KEY_CTRL_OFF					; arrows: with or without CTRL
	cmp #KEY_DOWN
	bne SelK_1
	jmp Sel_Key_Down
SelK_1
	cmp #KEY_UP
	bne SelK_1a
	jmp Sel_Key_Up
SelK_1a
	cmp #KEY_LEFT
	bne SelK_1b
	jmp Sel_Key_Left
SelK_1b
	cmp #KEY_RIGHT
	bne SelK_2
	jmp Sel_Key_Right
SelK_2
	lda CH								; raw CH for the non-arrow keys
	cmp #KEY_RETURN
	bne SelK_3
	jmp Sel_Key_Enter
SelK_3
	cmp #KEY_S
	bne SelK_4
	jmp Sel_Key_Show
SelK_4
	cmp #KEY_DOT
	bne SelK_5
	jmp Sel_Key_DelayUp
SelK_5
	cmp #KEY_COMMA
	bne SelK_6
	jmp Sel_Key_DelayDown
SelK_6
	cmp #KEY_D
	bne SelK_8
	jmp Sel_Key_Drive
SelK_8
	cmp #KEY_P
	bne SelK_9
	jmp Sel_Key_P
SelK_9
	cmp #KEY_I
	bne SelK_10
	jmp Sel_Key_I
SelK_10
	cmp #KEY_Q
	bne SelK_None
	jmp Sel_Key_Quit
SelK_None
	jmp Read_Key_Done					; unknown key - ignore

Sel_Redraw
	jsr Selector_Draw
	jmp Read_Key_Done

; Sel_Key_Down/Up/Left/Right - each validates and clamps the move, then hands
; the new index to Sel_Nav_Apply.  Because the list is one flat, row-major
; array, Left/Right wrapping across a row boundary needs no extra logic -
; it's just Sel_Index +/- 1.
Sel_Key_Down
	lda ImageCount
	ora ImageCount+1
	beq Sel_Key_Nav_Done				; empty list
	lda Sel_Index
	clc
	adc #UI_COLS
	cmp ImageCount
	bcs Sel_Key_Nav_Done				; no cell directly below - clamp
	jmp Sel_Nav_Apply

Sel_Key_Up
	lda Sel_Index
	cmp #UI_COLS
	bcc Sel_Key_Nav_Done				; already in the top grid row
	sec
	sbc #UI_COLS
	jmp Sel_Nav_Apply

Sel_Key_Left
	lda Sel_Index
	beq Sel_Key_Nav_Done				; already at the first item
	sec
	sbc #$01
	jmp Sel_Nav_Apply

Sel_Key_Right
	lda ImageCount
	ora ImageCount+1
	beq Sel_Key_Nav_Done				; empty list
	ldx Sel_Index
	inx
	cpx ImageCount
	bcs Sel_Key_Nav_Done				; already at the last item
	txa
	jmp Sel_Nav_Apply

;-----------------------------------------------------------------------------
; Sel_Nav_Apply - A = new Sel_Index (already range-checked by the caller).
; Common tail for the four nav keys: scrolls (full repaint) if the move
; crosses the visible window, else just re-colours the old and new cells;
; always repaints the status line, then returns to the key loop.
;-----------------------------------------------------------------------------
Sel_Nav_Apply
	pha									; stash the new index
	lda Sel_Index
	sta Reg8							; Reg8 = old index (survives the calls below)
	pla
	sta Sel_Index
	jsr Sel_Top_For_Index				; A = the Sel_Top that keeps Sel_Index visible
	cmp Sel_Top
	beq Sel_Nav_Apply_Rows				; unchanged -> no scroll, cheap 2-cell update
	sta Sel_Top							; scrolled -> repaint the whole grid in place
	jsr Selector_DrawList
	jmp Sel_Key_Nav_Done
Sel_Nav_Apply_Rows
	lda Reg8
	jsr Selector_HiRow					; un-highlight the cell we left
	lda Sel_Index
	jsr Selector_HiRow					; highlight the cell we moved to
Sel_Key_Nav_Done
	jsr Selector_DrawStatus				; row 20: description of the new row
	jmp Read_Key_Done

;-----------------------------------------------------------------------------
; Sel_Top_For_Index - A = target list index -> A = the Sel_Top that keeps
; that index inside the visible UI_VISROWS x UI_COLS window, scrolling by
; whole grid rows from the CURRENT Sel_Top.  Read-only - caller compares
; against Sel_Top and stores it.  Clobbers X, Reg1.
;-----------------------------------------------------------------------------
Sel_Top_For_Index
	lsr
	lsr
	lsr
	sta Reg1							; Reg1 = target item_row
	lda Sel_Top
	lsr
	lsr
	lsr								; A = current top_row
	cmp Reg1
	bcc Sel_Top_FI_MaybeDown			; top_row < item_row
	beq Sel_Top_FI_Unchanged			; top_row == item_row - already the top row
	lda Reg1							; top_row > item_row - scroll up: new top_row = item_row
	jmp Sel_Top_FI_Scale
Sel_Top_FI_MaybeDown
	clc
	adc #[UI_VISROWS-1]					; A = bottom row of the current window
	cmp Reg1
	bcs Sel_Top_FI_Unchanged			; bottom_row >= item_row - still visible
	lda Reg1							; scroll down: new top_row = item_row - (VISROWS-1)
	sec
	sbc #[UI_VISROWS-1]
Sel_Top_FI_Scale
	asl
	asl
	asl								; row -> Sel_Top (* UI_COLS)
	rts
Sel_Top_FI_Unchanged
	lda Sel_Top
	rts

Sel_RD					; near trampoline for the conditional branches below
	jmp Sel_Redraw

Sel_Key_Enter
	lda ImageCount
	ora ImageCount+1
	beq Sel_RD
	lda Sel_Index
	jsr UI_RowType
	beq Sel_Key_Enter_View				; file  -> view it
	cmp #$02
	beq Sel_Key_Enter_Up				; ".."  -> up one level
; directory -> descend and re-scan
	lda Sel_Index
	ldx #IMAGE_BANK
	jsr UI_ReadRec						; Name_Row_Buf = raw dir name (not "<...>")
	jsr Folder_Path_Push				; Scan_Path += "name>"
	jsr Rescan_Images
	jsr Selector_Draw
	jmp Read_Key_Done
Sel_Key_Enter_Up
	jsr Path_Pop_Segment
	jsr Rescan_Images
	jsr Selector_Draw
	jmp Read_Key_Done
Sel_Key_Enter_View
	jsr View_Selected
	lda #$01
	sta UI_Mode
	jmp Read_Key_Done

Sel_Key_Show
	lda ImageCount
	ora ImageCount+1
	beq Sel_RD
	lda Sel_Index
	jsr UI_RowType
	bne Sel_Key_Show_Ignore				; dir / ".." -> can't slideshow a folder
	jsr View_Selected
	jsr Slideshow_Reload_Counter
	lda #$02
	sta UI_Mode
Sel_Key_Show_Ignore
	jmp Read_Key_Done

Sel_Key_DelayUp
	lda Slide_Secs
	cmp #UI_SLIDE_MAX
	bcs Sel_Key_Delay_Done
	inc Slide_Secs
	jsr Selector_DrawDelay				; repaint only the number
Sel_Key_Delay_Done
	jmp Read_Key_Done
Sel_Key_DelayDown
	lda Slide_Secs
	cmp #[UI_SLIDE_MIN+1]
	bcc Sel_Key_Delay_Done
	dec Slide_Secs
	jsr Selector_DrawDelay
	jmp Read_Key_Done

;-----------------------------------------------------------------------------
; Sel_Key_Drive - open the "D" save-under overlay: stash the covered rectangle,
; frame it, list "D:" + "D1:".."D8:", and hand control to Drive_Keys (UI_Mode 3).
;-----------------------------------------------------------------------------
Sel_Key_Drive
	jsr Drive_Win_Geom
	jsr Text_Window_Save				; keep the list underneath intact

	lda Scan_Drive						; seed the cursor from the current drive
	beq Sel_Key_Drive_Seed0
	sec
	sbc #'0'
	jmp Sel_Key_Drive_SeedSet
Sel_Key_Drive_Seed0
	lda #$00
Sel_Key_Drive_SeedSet
	sta Drive_Pick_Index

	jsr Drive_Draw
	lda #$03
	sta UI_Mode
	jmp Read_Key_Done

; Drive_Draw - paint the drive window (frame, title, drive rows) over the saved
; rectangle, in the back buffer - Read_Key_Done shows it in one blit.
Drive_Draw
	jsr UI_Pen_Frame
	jsr Drive_Win_Geom
	lda #FRAME_DOUBLE
	sta Txt_FrameStyle
	jsr Text_Window_Frame

	jsr UI_Pen_Normal
	lda #DRIVE_WIN_ROW+1					; title on the first interior row
	sta Txt_Row
	lda #DRIVE_WIN_COL+2
	sta Txt_Col
	lda #<UI_Str_DriveTitle
	sta Txt_Ptr
	lda #>UI_Str_DriveTitle
	sta Txt_Ptr + $01
	jsr Text_PutStrAt
	jmp Drive_DrawRows					; tail

; Txt_Row / Txt_Col / Reg1 (width-1) / Reg2 (height-1) for the drive window
Drive_Win_Geom
	lda #DRIVE_WIN_ROW
	sta Txt_Row
	lda #DRIVE_WIN_COL
	sta Txt_Col
	lda #DRIVE_WIN_W-1
	sta Reg1
	lda #DRIVE_WIN_H-1
	sta Reg2
	rts

; Draw the 9 drive rows ("D:", "D1:".."D8:"); Drive_Pick_Index is drawn inverted.
Drive_DrawRows
	lda #$00
	sta Reg5							; Reg5 = drive index 0..8
Drive_DrawRows_L1
	lda Reg5
	cmp #$09
	bcs Drive_DrawRows_Done
	ldx #$00
	lda #'D'
	sta Txt_Line,x
	inx
	lda Reg5
	beq Drive_DrawRows_Colon
	clc
	adc #'0'
	sta Txt_Line,x
	inx
Drive_DrawRows_Colon
	lda #':'
	sta Txt_Line,x
	inx
Drive_DrawRows_Pad
	cpx #$06
	bcs Drive_DrawRows_Term
	lda #' '
	sta Txt_Line,x
	inx
	bne Drive_DrawRows_Pad
Drive_DrawRows_Term
	lda #$00
	sta Txt_Line,x
	lda Reg5
	cmp Drive_Pick_Index
	bne Drive_DrawRows_Normal
	jsr UI_Pen_Invert
	jmp Drive_DrawRows_Put
Drive_DrawRows_Normal
	jsr UI_Pen_Normal
Drive_DrawRows_Put
	lda Reg5
	clc
	adc #DRIVE_WIN_ROW+3
	sta Txt_Row
	lda #DRIVE_WIN_COL+2
	sta Txt_Col
	lda #<Txt_Line
	sta Txt_Ptr
	lda #>Txt_Line
	sta Txt_Ptr + $01
	jsr Text_PutStrAt
	inc Reg5
	jmp Drive_DrawRows_L1
Drive_DrawRows_Done
	rts

;=============================================================================
; Drive picker keys  (UI_Mode = 3)
;=============================================================================
Drive_Keys
	lda CH
	and #KEY_CTRL_OFF					; arrows: with or without CTRL
	cmp #KEY_DOWN
	bne DrvK_1
	lda Drive_Pick_Index
	cmp #$08
	bcs Drive_Keys_Ret
	inc Drive_Pick_Index
	jsr Drive_DrawRows
	jmp Read_Key_Done
DrvK_1
	cmp #KEY_UP
	bne DrvK_2
	lda Drive_Pick_Index
	beq Drive_Keys_Ret
	dec Drive_Pick_Index
	jsr Drive_DrawRows
	jmp Read_Key_Done
DrvK_2
	lda CH								; raw CH for the non-arrow keys
	cmp #KEY_RETURN
	bne DrvK_3
	lda Drive_Pick_Index
	beq Drive_Keys_Bare
	clc
	adc #'0'
	sta Scan_Drive
	jmp Drive_Keys_Commit
Drive_Keys_Bare
	lda #$00
	sta Scan_Drive
Drive_Keys_Commit
	lda #$00
	sta Scan_Path						; always scan the drive root
	jsr Drive_Win_Geom
	jsr Text_Window_Restore
	jsr Rescan_Images
	jsr Selector_Draw
	lda #$00
	sta UI_Mode
	jmp Read_Key_Done
DrvK_3
	cmp #KEY_ESC
	bne Drive_Keys_Ret
	jsr Drive_Win_Geom
	jsr Text_Window_Restore
	lda #$00
	sta UI_Mode
	jmp Read_Key_Done
Drive_Keys_Ret							; Q does not quit here - Selector only
	jmp Read_Key_Done

Sel_Key_P
	jsr Selector_Handle_P
	jmp Read_Key_Done
Sel_Key_I
	jsr Selector_Handle_I
	jmp Read_Key_Done
;-----------------------------------------------------------------------------
; Sel_Key_Quit - open the "Q" quit-confirm overlay: stash the covered
; rectangle, frame it, show the prompt, and hand control to Quit_Confirm_Keys
; (UI_Mode 5).  Q is only ever recognized here - every other screen ignores
; it - so quitting always passes through this confirmation.
;-----------------------------------------------------------------------------
Sel_Key_Quit
; Laid out like the APOD viewer's quit box: a double-line window with the
; question, and two single-line "buttons" - Y (green) and N (red):
;   +======================+
;   | Are You Sure To Quit |
;   |     +---+  +---+     |
;   |     | Y |  | N |     |
;   |     +---+  +---+     |
;   +======================+
	jsr Quit_Win_Geom
	jsr Text_Window_Save				; keep the grid underneath intact
	jsr Quit_Draw
	lda #$05
	sta UI_Mode
	jmp Read_Key_Done

; Quit_Draw - paint the quit box (frames + text) over the saved rectangle, in
; the back buffer - Read_Key_Done shows it in one blit.
Quit_Draw
	jsr UI_Pen_Frame
	jsr Quit_Win_Geom
	lda #FRAME_DOUBLE
	sta Txt_FrameStyle
	jsr Text_Window_Frame

	lda #QUIT_BTN_Y_COL					; Y button frame
	jsr Quit_Btn_Frame
	lda #QUIT_BTN_N_COL					; N button frame
	jsr Quit_Btn_Frame

	lda #QUIT_WIN_ROW+1					; the question, on the first interior row
	sta Txt_Row
	lda #QUIT_WIN_COL+2
	sta Txt_Col
	lda #<UI_Str_QuitConfirm
	sta Txt_Ptr
	lda #>UI_Str_QuitConfirm
	sta Txt_Ptr + $01
	jsr Text_PutStrAt

	lda #QUIT_WIN_ROW+3					; the Y / N letters, centred in their buttons
	sta Txt_Row
	lda #QUIT_BTN_Y_COL+2
	sta Txt_Col
	lda #<UI_Str_QuitYes
	sta Txt_Ptr
	lda #>UI_Str_QuitYes
	sta Txt_Ptr + $01
	jsr Text_PutStrAt
	lda #QUIT_BTN_N_COL+2
	sta Txt_Col
	lda #<UI_Str_QuitNo
	sta Txt_Ptr
	lda #>UI_Str_QuitNo
	sta Txt_Ptr + $01
	jmp Text_PutStrAt					; tail

; A = left column of a QUIT_BTN_W x 3 single-line button box (rows 2-4 of the
; quit window), drawn in the current pen.
Quit_Btn_Frame
	sta Txt_Col
	lda #QUIT_WIN_ROW+2
	sta Txt_Row
	lda #QUIT_BTN_W-1
	sta Reg1
	lda #$02
	sta Reg2
	lda #FRAME_SINGLE
	sta Txt_FrameStyle
	jmp Text_Window_Frame				; tail

; Txt_Row / Txt_Col / Reg1 (width-1) / Reg2 (height-1) for the quit-confirm window
Quit_Win_Geom
	lda #QUIT_WIN_ROW
	sta Txt_Row
	lda #QUIT_WIN_COL
	sta Txt_Col
	lda #QUIT_WIN_W-1
	sta Reg1
	lda #QUIT_WIN_H-1
	sta Reg2
	rts

;=============================================================================
; Quit-confirm popup keys  (UI_Mode = 5) - Selector only
;=============================================================================
Quit_Confirm_Keys
	lda CH
	cmp #KEY_Y
	bne Quit_Confirm_NotY
	jmp Exit							; confirmed - actually quit
Quit_Confirm_NotY
	cmp #KEY_N
	beq Quit_Confirm_Cancel
	cmp #KEY_ESC
	beq Quit_Confirm_Cancel
	jmp Read_Key_Done					; anything else - ignore
Quit_Confirm_Cancel
	jsr Quit_Win_Geom
	jsr Text_Window_Restore
	lda #$00
	sta UI_Mode
	jmp Read_Key_Done

;-----------------------------------------------------------------------------
; View_Selected - show Sel_Index as a full image (attribute-map path).
;-----------------------------------------------------------------------------
View_Selected
	lda Sel_Index
	sta File_Index
	jsr Clear_Screen					; framebuffer + CRAM to 0 while the menu is still up
	jsr Wait_VBlank
	jsr Text_Deactivate					; = XDL_Image_Attribute: all-transparent black, so the
	jmp Load_Image						; palette apply is unseen; the pixels stream in (tail)

;-----------------------------------------------------------------------------
; Selector_Sync_Cursor - pull the selector highlight back onto File_Index.
; Space / Backspace (image view) and the slideshow move File_Index while an
; image is on screen; call this before returning to the selector so its
; highlight follows the picture you were actually looking at, scrolling the
; grid if the entry is off-screen.  Shares Sel_Top_For_Index with the nav keys.
;-----------------------------------------------------------------------------
Selector_Sync_Cursor
	lda ImageCount
	ora ImageCount+1
	beq Selector_Sync_Zero				; empty list - keep 0 / 0
	lda File_Index
	cmp ImageCount
	bcc Selector_Sync_Set
	lda ImageCount						; out of range (shouldn't happen) - clamp
	sec
	sbc #$01
Selector_Sync_Set
	sta Sel_Index
	jsr Sel_Top_For_Index				; A = the Sel_Top that keeps Sel_Index visible
	sta Sel_Top
	rts
Selector_Sync_Zero
	lda #$00
	sta Sel_Index
	sta Sel_Top
	rts

;-----------------------------------------------------------------------------
; Selector_Handle_P - "P" key: show a 2x2 grid of ramp squares, one per
; palette register, zoomed 7x and centered on the image screen (UI_Mode 6,
; Esc-only - see Pal_Preview_Keys).
;   * on a *.V1K row: "Reading palette..." in row 0, read the .PAL block to
;     $21000 with the selector still up; a missing / short file leaves the
;     selector up (row 0 restored).  Only once it has loaded is the preview
;     built (unseen) and swapped in, with the registers rewritten under a
;     blanked overlay.
;   * on "..", a directory or an empty list: no disk access at all - the
;     registers already hold the menu's own palettes 0-3, so just show them.
;-----------------------------------------------------------------------------
Selector_Handle_P
	lda ImageCount
	ora ImageCount+1
	beq Selector_Handle_P_Menu			; empty list -> the menu palettes
	lda Sel_Index
	jsr UI_RowType
	bne Selector_Handle_P_Menu			; dir / ".." -> the menu palettes

	lda Sel_Index
	sta File_Index
	lda #<UI_Str_ReadPal
	ldy #>UI_Str_ReadPal
	jsr UI_Show_Busy					; "Reading palette..." - on screen now
	jsr Read_Image_Palette				; .PAL block -> $21000, registers untouched
	bcc Selector_Handle_P_Loaded
	jmp Selector_Restore_LocRow			; failed - selector stays up (tail)

Selector_Handle_P_Loaded
	jsr Pal_Preview_Build				; framebuffer + CRAM, all unseen
	jsr Display_Off						; blank while the registers change
	jsr Apply_Image_Palette				; sets Pal_Image -> Enter_Selector restores
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	jsr Text_Deactivate					; = XDL_Image_Attribute
	jsr Display_On
	jmp Selector_Handle_P_Mode

Selector_Handle_P_Menu
	jsr Pal_Preview_Build
	jsr Wait_VBlank
	jsr Text_Deactivate					; a pure XDL swap - no palette change
Selector_Handle_P_Mode
	jsr Selector_Restore_LocRow			; row 0 tidy for the way back (back buffer)
	lda #$06
	sta UI_Mode
	rts

; Pal_Preview_Build - the 2x2 squares + their attribute cells into the
; (hidden) framebuffer / CRAM, by blitter.
Pal_Preview_Build
	jsr Clear_Screen
	jsr Fill_Pal_Preview_Cmap
	jmp Draw_Pal_Preview_Squares		; (tail)

;=============================================================================
; P-preview screen keys (UI_Mode = 6) - Esc only; every other key ignored
; (Space/Backspace/0-4 have no meaning here, unlike the real image-view key
; set - see Selector_Handle_P).
;=============================================================================
Pal_Preview_Keys
	lda CH
	cmp #KEY_ESC
	bne Pal_Preview_Keys_None
	jsr Selector_Sync_Cursor
	jsr Enter_Selector
	jmp Read_Key_Done
Pal_Preview_Keys_None
	jmp Read_Key_Done

;-----------------------------------------------------------------------------
; Selector_Handle_I - load the selected image's "<name>.NFO" and open the info
; viewer (UI_Mode 4).  "Reading nfo..." shows in row 0 during the load; the
; info screen is then built in the back buffer and shown by Read_Key_Done in
; one blit.  Missing file -> row 0 restored, selector stays up.  A directory /
; ".." row has no .NFO - ignored, no disk access.
;-----------------------------------------------------------------------------
Selector_Handle_I
	lda ImageCount
	ora ImageCount+1
	beq Selector_Handle_I_Ret			; no images -> nothing to describe
	lda Sel_Index
	jsr UI_RowType
	bne Selector_Handle_I_Ret			; dir / ".." -> nothing to describe
	lda Sel_Index
	sta File_Index
	lda #<UI_Str_ReadNfo
	ldy #>UI_Str_ReadNfo
	jsr UI_Show_Busy					; "Reading nfo..." - on screen now
	lda #$01							; ext selector 1 = .NFO
	jsr Build_Filename					; FileNamePtr -> "D[n]:PATH<base>.NFO",0
	jsr Info_Load						; stream into NFO_BUF_VRAM, count records
	lda LoadStatus
	bne Selector_Handle_I_Show
	jmp Selector_Restore_LocRow			; OPEN failed (no .nfo) - selector stays up (tail)
Selector_Handle_I_Show
	lda #$00
	sta Nfo_Top
	sta Nfo_Top + $01
	jsr Text_Clear						; wipe the selector's grid/status/delay/legend
	jsr Info_Draw
	jsr Info_DrawFooter					; fixed "Esc.../Up-Down..." hint line
	lda #$04
	sta UI_Mode
Selector_Handle_I_Ret
	rts

;-----------------------------------------------------------------------------
; Info_DrawFooter - draw the info viewer's "Nav: ..." line in the footer band,
; on its 3rd/last row (row TEXT_MAIN_ROWS+2, i.e. row 22).  Called on entry to
; Info mode; the footer band's other two rows stay blank for this screen.  The
; arrows are CP437 codes both fonts carry (Text_Load_Fonts).
;-----------------------------------------------------------------------------
Info_DrawFooter
	jsr UI_Pen_Normal
	TXT_AT TEXT_MAIN_ROWS+2, 0, UI_Str_InfoHint
	rts

;=============================================================================
; Help page  (UI_Mode = 7) - static text assembled into the binary, no disk
; access.  Opened by the Help key from the Selector or the Info viewer (the
; two screens whose footer advertises it); only Esc returns there.
;=============================================================================
; Help_Key - Handle_Keys jumps here when HELPFLG was set (already cleared).
Help_Key
	lda UI_Mode
	beq Help_Key_Open					; 0 = selector
	cmp #$04
	beq Help_Key_Open					; 4 = info viewer
	jmp Read_Key_Done					; any other screen (Help itself included) - ignore
Help_Key_Open
	sta Help_Return_Mode
	jsr Help_Open
	jmp Read_Key_Done

; Help_Open - build section 1 in the back buffer; Read_Key_Done shows it.
Help_Open
	lda #$00
	sta Help_Page						; always open on section 1, at the top
	sta Help_Top
	jsr Help_Draw
	lda #$07
	sta UI_Mode
	rts

;-----------------------------------------------------------------------------
; Help_Draw - repaint the whole help screen for Help_Page (back buffer only):
; banner on row 0, the section's rows Help_Top .. Help_Top+HELP_VISROWS-1 on
; rows 1-19, "Section  n of 3" on row 20 (footer band), the Nav hint on row
; 22.  A section's text is a run of $00-terminated rows (an empty one = a
; blank row) ended by $FF.  Walks every row, leaving the total in
; Help_RowCount for the scroll clamp in Help_Keys.
;-----------------------------------------------------------------------------
Help_Draw
	jsr Text_Clear						; wipe the previous screen / section
	jsr UI_Pen_Normal
	TXT_AT 0, 0, UI_Str_HelpTitle

	jsr UI_Pen_HelpBody
	ldx Help_Page
	lda Help_Page_Lo,x
	sta Txt_Ptr
	lda Help_Page_Hi,x
	sta Txt_Ptr + $01
	lda #$00
	sta Txt_Col
	sta Help_RowCount					; = index of the row being walked
Help_Draw_L1
	ldy #$00
	lda (Txt_Ptr),y
	cmp #$FF
	beq Help_Draw_Footer				; end of section
	lda Help_RowCount
	sec
	sbc Help_Top
	bcc Help_Draw_Skip					; above the window
	cmp #HELP_VISROWS
	bcs Help_Draw_Skip					; below the window
	clc
	adc #$01							; window row 0 -> screen row 1
	sta Txt_Row
	jsr Text_PutStrAt					; (an empty row draws nothing)
Help_Draw_Skip
	ldy #$00
Help_Draw_L2							; step Txt_Ptr past this row's $00
	lda (Txt_Ptr),y
	beq Help_Draw_L3
	iny
	bne Help_Draw_L2
Help_Draw_L3
	iny
	tya
	clc
	adc Txt_Ptr
	sta Txt_Ptr
	bcc Help_Draw_NC
	inc Txt_Ptr + $01
Help_Draw_NC
	inc Help_RowCount
	jmp Help_Draw_L1

Help_Draw_Footer
	ldx Help_Page
	lda Help_PageNum_Lo,x
	sta Txt_Ptr
	lda Help_PageNum_Hi,x
	sta Txt_Ptr + $01
	lda #TEXT_MAIN_ROWS
	sta Txt_Row
	lda #[TEXT_COLS-15]/2				; "Section  n of 3" = 15 cells, centred (32 + 15 + 33)
	sta Txt_Col
	jsr Text_PutStrAt					; still in the help pen

	jsr UI_Pen_Normal
	TXT_AT TEXT_MAIN_ROWS+2, 0, UI_Str_HelpHint
	rts

Help_Keys							; Q does not quit here - Selector only
	lda CH
	and #KEY_CTRL_OFF					; arrows: with or without CTRL
	cmp #KEY_UP
	beq Help_Key_Up
	cmp #KEY_DOWN
	beq Help_Key_Down
	cmp #KEY_LEFT
	beq Help_Key_Prev
	cmp #KEY_RIGHT
	beq Help_Key_Next
	lda CH								; raw CH for the non-arrow keys
	cmp #KEY_ESC
	beq Help_Close
	jmp Read_Key_Done

Help_Key_Up								; scroll one row (no-op on a section that fits)
	lda Help_Top
	beq Help_Key_Done					; already at the top
	dec Help_Top
	jmp Help_Key_Redraw
Help_Key_Down
	lda Help_Top
	clc
	adc #HELP_VISROWS
	cmp Help_RowCount
	bcs Help_Key_Done					; last row already showing
	inc Help_Top
	jmp Help_Key_Redraw
Help_Key_Prev
	lda Help_Page
	beq Help_Key_Done					; already on section 1
	dec Help_Page
	jmp Help_Key_NewPage
Help_Key_Next
	lda Help_Page
	cmp #HELP_PAGES-1
	bcs Help_Key_Done					; already on the last section
	inc Help_Page
Help_Key_NewPage
	lda #$00
	sta Help_Top						; a new section starts at its top
Help_Key_Redraw
	jsr Help_Draw
Help_Key_Done
	jmp Read_Key_Done

; Help_Close - back to the screen Help was opened from.  The Info viewer's
; .NFO is still in NFO_BUF_VRAM and Nfo_Top is untouched, so it is rebuilt
; at the same scroll position with no disk read.
Help_Close
	lda Help_Return_Mode
	cmp #$04
	bne Help_Close_Selector
	jsr Text_Clear
	jsr Info_Draw
	jsr Info_DrawFooter
	lda #$04
	sta UI_Mode
	jmp Read_Key_Done
Help_Close_Selector
	jsr Enter_Selector
	jmp Read_Key_Done

;=============================================================================
; Slideshow  (UI_Mode = 2)
;=============================================================================
Slideshow_Keys						; Q does not quit here - Selector only
	lda CH
	cmp #KEY_ESC
	beq Slide_Key_Stop
	cmp #KEY_SPACE
	beq Slide_Key_Next
	jmp Read_Key_Done
Slide_Key_Stop
	jsr Selector_Sync_Cursor				; highlight follows the image on screen
	jsr Enter_Selector
	jmp Read_Key_Done
Slide_Key_Next
	jsr Clear_Screen
	jsr Increment_Image
	jsr Slideshow_Reload_Counter
	jmp Read_Key_Done

;-----------------------------------------------------------------------------
; Slideshow_Tick - called from main every frame.  Counts Slide_FrameCtr down
; and advances to the next image at zero.  No-op unless UI_Mode = 2.
;-----------------------------------------------------------------------------
Slideshow_Tick
	lda UI_Mode
	cmp #$02
	beq Slideshow_Tick_Run
	rts
Slideshow_Tick_Run
	lda Slide_FrameCtr
	bne Slideshow_Tick_Dec
	lda Slide_FrameCtr+1
	beq Slideshow_Tick_Fire				; counter reached 0
	dec Slide_FrameCtr+1
Slideshow_Tick_Dec
	dec Slide_FrameCtr
	rts
Slideshow_Tick_Fire
	jsr Clear_Screen
	jsr Increment_Image
	jsr Slideshow_Reload_Counter
	rts

;-----------------------------------------------------------------------------
; Slideshow_Reload_Counter - Slide_FrameCtr = Slide_Secs * framerate
;   framerate = 50 (PAL, Video_Flag = 0) or 60 (NTSC, Video_Flag = 1)
;-----------------------------------------------------------------------------
Slideshow_Reload_Counter
	lda #$00
	sta Slide_FrameCtr
	sta Slide_FrameCtr+1
	ldx Slide_Secs
	beq Slideshow_Reload_Done
	lda Video_Flag
	bne Slideshow_Reload_NTSC
	lda #50
	bne Slideshow_Reload_Set
Slideshow_Reload_NTSC
	lda #60
Slideshow_Reload_Set
	sta Reg1							; Reg1 = frames to add per second
Slideshow_Reload_L1
	clc
	lda Slide_FrameCtr
	adc Reg1
	sta Slide_FrameCtr
	bcc Slideshow_Reload_NoCarry
	inc Slide_FrameCtr+1
Slideshow_Reload_NoCarry
	dex
	bne Slideshow_Reload_L1
Slideshow_Reload_Done
	rts

;=============================================================================
; Info viewer  (UI_Mode = 4) - shows "<image>.NFO" on the 80-col text screen,
; scrollable.  The .NFO file IS the byte image of that screen: fixed 160-byte
; line records of 80 {glyph,attr} cell pairs (attr $07), no terminators, one
; all-$00 record marking end-of-text.  Info_Load streams it verbatim into
; NFO_BUF_VRAM (banks $25-$29); Info_Draw blits record 0 (the title rule,
; pinned to row 0) plus a 19-row scrolling window of the rest - two
; BLT_NFO_DRAW copies per scroll, no reformat, no re-walk.
;=============================================================================

;-----------------------------------------------------------------------------
; Info_Load - stream FileNamePtr into NFO_BUF_VRAM via LoadData, then count the
; line records.  LoadStatus (fileio.lib) = 0 if the OPEN failed.  No pre-wipe:
; the converter's trailing $00 record stops Info_Count_Lines before any stale
; tail from a previous, longer .NFO, and the scroll clamp keeps those records
; off screen.
;-----------------------------------------------------------------------------
Info_Load
	lda #NFO_BUF_BANK
	sta BankIndex
	jsr LoadData						; FileNamePtr was set by Build_Filename
	lda LoadStatus
	beq Info_Load_Ret					; OPEN failed - Selector_Handle_I bails
	jsr Info_Count_Lines				; sets Nfo_LineCount
Info_Load_Ret
	rts

;-----------------------------------------------------------------------------
; Info_Count_Lines - walk the loaded buffer in TEXT_PITCH (160-byte) steps and
; count records whose first byte is non-zero, stopping at the $00 sentinel or
; at NFO_MAX_LINES (127).  Leaves Nfo_LineCount (word; hi byte stays 0).
; Ptr_Lo/Hi is the $2000-window pointer, Nfo_WalkBank the mapped bank; a
; 160-byte step straddles a bank every ~25 records, handled inline.
;-----------------------------------------------------------------------------
Info_Count_Lines
	lda #$00
	sta Nfo_LineCount
	sta Nfo_LineCount + $01
	lda #NFO_BUF_BANK
	sta Nfo_WalkBank
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #<VBXE_WINDOW
	sta Ptr_Lo
	lda #>VBXE_WINDOW
	sta Ptr_Hi
Info_Count_L1
	ldy #$00
	lda (Ptr_Lo),y
	beq Info_Count_Done					; $00 first byte -> sentinel / end of text
	inc Nfo_LineCount
	lda Nfo_LineCount
	cmp #NFO_MAX_LINES
	bcs Info_Count_Done					; hit the record cap
	lda Ptr_Lo							; Ptr += TEXT_PITCH
	clc
	adc #TEXT_PITCH
	sta Ptr_Lo
	bcc Info_Count_L1
	inc Ptr_Hi
	lda Ptr_Hi
	cmp #>VBXE_WINDOW + $10				; crossed out of the 4K window ($30xx)?
	bcc Info_Count_L1
	sbc #$10							; C=1 from the cmp -> back to $20xx-$2Fxx
	sta Ptr_Hi
	inc Nfo_WalkBank					; and map the next NFO buffer bank
	lda Nfo_WalkBank
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	jmp Info_Count_L1
Info_Count_Done
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

;-----------------------------------------------------------------------------
; Info_Draw - the info screen, from the NFO buffer by blitter - no re-walk:
;   row 0     = record 0 (the report's ==== title rule), pinned - never scrolls
;   rows 1-19 = records 1+Nfo_Top onward (Nfo_Top scrolls the body only)
; Two BLT_NFO_DRAW copies (head, then body).  When the body is shorter than
; its 19 rows, clear first and blit only the records that exist.
;-----------------------------------------------------------------------------
Info_Draw
	lda #$01
	sta Txt_Dirty						; the blits below write the back buffer
	lda Nfo_LineCount
	ora Nfo_LineCount + $01
	bne Info_Draw_Some
	jmp Text_Clear						; empty .NFO - nothing to show (tail)
Info_Draw_Some
	jsr Info_Body_Rows
	cmp #NFO_VISROWS-1
	bcs Info_Draw_Head					; full body window - every row is overwritten
	jsr Text_Clear						; short body: clear the rows the blit won't reach
Info_Draw_Head
	lda #$00							; record 0 -> row 0, one row
	sta Reg1
	sta Reg2
	sta Reg4
	lda #<TEXT_BACK_VRAM
	sta Reg3
	jsr Info_Blit
	jsr Info_Body_Rows
	beq Info_Draw_Ret					; no body records
	sta Reg4
	dec Reg4							; Reg4 = height-1
; Reg2:Reg1 = (Nfo_Top + 1) * TEXT_PITCH  (Nfo_Top <= NFO_MAX_LINES-NFO_VISROWS -> <= $4380)
	lda #TEXT_PITCH
	sta Reg1
	lda #$00
	sta Reg2
	ldx Nfo_Top
	beq Info_Draw_Body
Info_Draw_MulL
	lda Reg1
	clc
	adc #TEXT_PITCH
	sta Reg1
	bcc Info_Draw_MulNC
	inc Reg2
Info_Draw_MulNC
	dex
	bne Info_Draw_MulL
Info_Draw_Body
	lda #<[TEXT_BACK_VRAM+TEXT_PITCH]	; row 1 (same bank/page - only the lo byte moves)
	sta Reg3
	jmp Info_Blit						; (tail)
Info_Draw_Ret
	rts

;-----------------------------------------------------------------------------
; Info_Body_Rows - A = body rows to show = min(Nfo_LineCount-1-Nfo_Top,
; NFO_VISROWS-1), Z set if 0.  Needs Nfo_LineCount >= 1 (the scroll clamp
; keeps Nfo_Top <= Nfo_LineCount-1).  Clobbers Reg5, Reg6.
;-----------------------------------------------------------------------------
Info_Body_Rows
	sec
	lda Nfo_LineCount
	sbc Nfo_Top
	sta Reg5
	lda Nfo_LineCount + $01
	sbc Nfo_Top + $01
	sta Reg6
	lda Reg5							; Reg6:Reg5 -= 1 (record 0 is the pinned head)
	sec
	sbc #$01
	sta Reg5
	lda Reg6
	sbc #$00
	bne Info_Body_Rows_Full				; >= 256 available
	lda Reg5
	cmp #NFO_VISROWS-1
	bcc Info_Body_Rows_Ret
Info_Body_Rows_Full
	lda #NFO_VISROWS-1
Info_Body_Rows_Ret
	cmp #$00							; Z = no rows
	rts

;-----------------------------------------------------------------------------
; Info_Blit - one BLT_NFO_DRAW copy: Reg2:Reg1 = source offset into the NFO
; buffer, Reg3 = destination lo byte (in the back buffer's first page),
; Reg4 = height-1.  Waits for the copy to finish.
;-----------------------------------------------------------------------------
Info_Blit
	lda #MEMAC_GLOBAL_ENABLE				; map VBXE bank $00 -> $2000 window (patch the BCB)
	vbsta VBXE_MA_BSEL
	lda Reg1
	sta BLT_NFO_DRAW + Src_Adr0			; source lo  = offset lo
	lda Reg2
	clc
	adc #$50							; + $50  (low 16 bits of NFO_BUF_VRAM = $5000)
	sta BLT_NFO_DRAW + Src_Adr1			; source mid ; source hi stays $02 (Reg2 max $43, no carry)
	lda Reg3
	sta BLT_NFO_DRAW + Dest_Adr0
	lda Reg4
	sta BLT_NFO_DRAW + Blt_H
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	lda #BLT_NFO_DRAW-BLT_CLEAR
	vbsta VBXE_BL_ADR0					; point the blitter at BLT_NFO_DRAW
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
Info_Blit_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Info_Blit_L1					; wait for any prior blit
	lda #$01
	vbsta VBXE_BLITTER_START
Info_Blit_L2
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Info_Blit_L2					; wait for the copy to finish
	rts

;-----------------------------------------------------------------------------
; Info_Can_Scroll_Down - C=1 iff (Nfo_Top + NFO_VISROWS) < Nfo_LineCount.
; Clobbers A, Reg5, Reg6.
;-----------------------------------------------------------------------------
Info_Can_Scroll_Down
	clc
	lda Nfo_Top
	adc #NFO_VISROWS
	sta Reg5
	lda Nfo_Top + $01
	adc #$00
	sta Reg6
	lda Reg5
	cmp Nfo_LineCount
	lda Reg6
	sbc Nfo_LineCount + $01
	bcc Info_Can_Scroll_Yes
	clc
	rts
Info_Can_Scroll_Yes
	sec
	rts

;-----------------------------------------------------------------------------
Info_Keys
	lda CH
	and #KEY_CTRL_OFF					; arrows: with or without CTRL
	cmp #KEY_UP
	bne InfK_1
	jmp Info_Key_Up
InfK_1
	cmp #KEY_DOWN
	bne InfK_1a
	jmp Info_Key_Down
InfK_1a
	cmp #KEY_LEFT						; Left/Right page ("LR Page" on the footer)
	bne InfK_1b
	jmp Info_Key_PageUp
InfK_1b
	cmp #KEY_RIGHT
	bne InfK_2
	jmp Info_Key_PageDown
InfK_2
	lda CH								; raw CH for the non-arrow keys
InfK_4							; Q does not quit here - Selector only
	cmp #KEY_ESC
	beq Info_Key_Leave
	cmp #KEY_I
	beq Info_Key_Leave
	jmp Read_Key_Done
Info_Key_Leave
	jsr Enter_Selector
	jmp Read_Key_Done

Info_Key_Up
	lda Nfo_Top
	ora Nfo_Top + $01
	beq Info_Key_RKD					; already at the top
	lda Nfo_Top
	bne Info_Key_Up_NB
	dec Nfo_Top + $01
Info_Key_Up_NB
	dec Nfo_Top
	jsr Info_Draw
Info_Key_RKD
	jmp Read_Key_Done

Info_Key_Down
	jsr Info_Can_Scroll_Down
	bcc Info_Key_RKD
	inc Nfo_Top
	bne Info_Key_Down_NC
	inc Nfo_Top + $01
Info_Key_Down_NC
	jsr Info_Draw
	jmp Read_Key_Done

Info_Key_PageUp
	ldx #NFO_VISROWS-1				; one body page (row 0 is pinned)
Info_Key_PageUp_L1
	lda Nfo_Top
	ora Nfo_Top + $01
	beq Info_Key_PageUp_Draw
	lda Nfo_Top
	bne Info_Key_PageUp_NB
	dec Nfo_Top + $01
Info_Key_PageUp_NB
	dec Nfo_Top
	dex
	bne Info_Key_PageUp_L1
Info_Key_PageUp_Draw
	jsr Info_Draw
	jmp Read_Key_Done

Info_Key_PageDown
	ldx #NFO_VISROWS-1				; one body page (row 0 is pinned)
Info_Key_PageDown_L1
	jsr Info_Can_Scroll_Down
	bcc Info_Key_PageDown_Draw
	inc Nfo_Top
	bne Info_Key_PageDown_NC
	inc Nfo_Top + $01
Info_Key_PageDown_NC
	dex
	bne Info_Key_PageDown_L1
Info_Key_PageDown_Draw
	jsr Info_Draw
	jmp Read_Key_Done

;=============================================================================
; Shared directory helpers
;-----------------------------------------------------------------------------
; Line_Has_Dir_Tag classifies a CIO directory line; Folder_Path_Push /
; Path_Pop_Segment maintain the Scan_Path segment stack ("NAME>NAME2>").  All
; three are driven from Build_Image_List and Sel_Key_Enter now that directory
; navigation lives in the selector itself.
;=============================================================================

;-----------------------------------------------------------------------------
; Line_Has_Dir_Tag - Z=0 (A=$01) if Dir_Line_Buf holds the "<DIR>" token that
; SpartaDOS X prints in the size column for a sub-directory; Z=1 (A=$00) if
; not.  Reads CPU RAM only - safe to call with a VBXE bank in the $2000 window.
;-----------------------------------------------------------------------------
Line_Has_Dir_Tag
	ldx #$00
Line_Has_Dir_Tag_L1
	lda Dir_Line_Buf,x
	cmp #'<'
	bne Line_Has_Dir_Tag_Next
	lda Dir_Line_Buf+1,x
	cmp #'D'
	bne Line_Has_Dir_Tag_Next
	lda Dir_Line_Buf+2,x
	cmp #'I'
	bne Line_Has_Dir_Tag_Next
	lda Dir_Line_Buf+3,x
	cmp #'R'
	bne Line_Has_Dir_Tag_Next
	lda Dir_Line_Buf+4,x
	cmp #'>'
	bne Line_Has_Dir_Tag_Next
	lda #$01							; found
	rts
Line_Has_Dir_Tag_Next
	inx
	cpx #[Dir_Line_Len-4]				; keep 5 bytes of headroom
	bcc Line_Has_Dir_Tag_L1
	lda #$00							; not found
	rts

;-----------------------------------------------------------------------------
; Folder_Path_Push - append "<name>>" to Scan_Path (name from Name_Row_Buf,
; space-padded).  Refuses if the result would not fit.
;-----------------------------------------------------------------------------
Folder_Path_Push
	ldx #$00
Folder_Path_Push_End
	lda Scan_Path,x
	beq Folder_Path_Push_Name
	inx
	cpx #$20							; keep room for name(8) + '>' + NUL
	bcc Folder_Path_Push_End
	rts									; path too long already - refuse
Folder_Path_Push_Name
	ldy #$00
Folder_Path_Push_L1
	lda Name_Row_Buf,y
	beq Folder_Path_Push_Sep
	cmp #' '
	beq Folder_Path_Push_Sep
	sta Scan_Path,x
	inx
	iny
	cpy #$08
	bcc Folder_Path_Push_L1
Folder_Path_Push_Sep
	lda #'>'
	sta Scan_Path,x
	inx
	lda #$00
	sta Scan_Path,x
	rts

;-----------------------------------------------------------------------------
; Path_Pop_Segment - "...>SEG>" -> "...>"  (or -> "" for the last segment)
;-----------------------------------------------------------------------------
Path_Pop_Segment
	ldx #$00
Path_Pop_End
	lda Scan_Path,x
	beq Path_Pop_Found
	inx
	cpx #$28
	bcc Path_Pop_End
Path_Pop_Found							; X = index of the NUL
	cpx #$00
	beq Path_Pop_Done					; already empty
	dex									; step onto the trailing '>'
Path_Pop_L1
	cpx #$00
	beq Path_Pop_Cut
	dex
	lda Scan_Path,x
	cmp #'>'
	bne Path_Pop_L1
	inx									; keep this separator
Path_Pop_Cut
	lda #$00
	sta Scan_Path,x
Path_Pop_Done
	rts

;=============================================================================
; UI strings  (ATASCII; the text renderer maps to internal codes)
;=============================================================================
; TXT_PEN,<pen> switches colour mid-string and takes no column (text80.asm),
; so these lay out exactly as their plain text.
UI_Str_Loc			dta c'Location: ',0	; drawn in UI_PEN_LOC, the same pen as the path
UI_Str_Empty		dta TXT_PEN,UI_PEN_EMPTY,c'* No images *',0
; Status panel rows 20-22: each starts with a 3-letter tag + ':' in UI_PEN_LOC.
; Row 21 = "Cfg:" (col 0) + the delay (cols 5-6) + UI_Str_DelayHint (col 7);
; row 22 = UI_Str_Legend (col 0).  Both rows are exactly 80 cells.
UI_Str_Delay		dta TXT_PEN,UI_PEN_LOC,c'Cfg:',0
UI_Str_DelayHint	dta TXT_PEN,UI_PEN_VALUE,c' sec '
					dta TXT_PEN,UI_PEN_KEY,c'<',TXT_PEN,UI_PEN_DESC,c' Less '
					dta TXT_PEN,UI_PEN_KEY,c'>',TXT_PEN,UI_PEN_DESC,c' More                  Press '
					dta TXT_PEN,UI_PEN_KEY,c'HELP',TXT_PEN,UI_PEN_DESC,c' for additional information',0
UI_Str_Legend		dta TXT_PEN,UI_PEN_LOC,c'Nav: ',TXT_PEN,UI_PEN_KEY
					dta $18,$19,$1B,$1A					; CP437 up down left right (both fonts)
					dta TXT_PEN,UI_PEN_DESC,c' Select '
					dta TXT_PEN,UI_PEN_KEY,c'Enter',TXT_PEN,UI_PEN_DESC,c' Choose '
					dta TXT_PEN,UI_PEN_KEY,c'S',TXT_PEN,UI_PEN_DESC,c' Slideshow '
					dta TXT_PEN,UI_PEN_KEY,c'D',TXT_PEN,UI_PEN_DESC,c' Drive '
					dta TXT_PEN,UI_PEN_KEY,c'P',TXT_PEN,UI_PEN_DESC,c' Palette '
					dta TXT_PEN,UI_PEN_KEY,c'I',TXT_PEN,UI_PEN_DESC,c' Info '
					dta TXT_PEN,UI_PEN_KEY,c'F',TXT_PEN,UI_PEN_DESC,c' Font '
					dta TXT_PEN,UI_PEN_KEY,c'Q',TXT_PEN,UI_PEN_DESC,c' Quit',0
; Info screen row 22 (col 0, 80 cells) - same scheme as UI_Str_Legend; the two
; arrows are CP437 codes both fonts carry.
UI_Str_InfoHint		dta TXT_PEN,UI_PEN_LOC,c'Nav: ',TXT_PEN,UI_PEN_KEY,c'ESC'
					dta TXT_PEN,UI_PEN_DESC,c' Go Back ',TXT_PEN,UI_PEN_KEY
					dta $18,$19,TXT_PEN,UI_PEN_DESC,c' Scroll ',TXT_PEN,UI_PEN_KEY
					dta $1B,$1A,TXT_PEN,UI_PEN_DESC,c' Page         Press '
					dta TXT_PEN,UI_PEN_KEY,c'HELP',TXT_PEN,UI_PEN_DESC,c' for additional information',0
; Help page (UI_Mode 7): title on row 0, nav hint on row 22.
; Row 0 banner: 29 '=' + 22-char title + 29 '=' (80 cells).  The '=' sweep is
; the .nfo report rule - Convertor/nfo_encode.py RULE_ATTRS, run-length coded
; ($38 x5, $39 x5, $3A x6, $3B x5, $3C x5, $3D x3 each side, mirrored) - and
; the title is its PEN_TITLE ($0F bright gold).  The version digits come from
; V_0..V_3 (view1024.asm), so the title stays 22 cells whatever V_3 holds
; (a letter, or $00 = a space).
UI_Str_HelpTitle	dta TXT_PEN,$38,c'=====',TXT_PEN,$39,c'=====',TXT_PEN,$3A,c'======'
					dta TXT_PEN,$3B,c'=====',TXT_PEN,$3C,c'=====',TXT_PEN,$3D,c'==='
					dta TXT_PEN,$0F,c'Slideshow V '
					DTA_SCR V_0
					dta c'.'
					DTA_SCR V_1
					DTA_SCR V_2
					DTA_SCR V_3
					dta c' Help'
					dta TXT_PEN,$3D,c'===',TXT_PEN,$3C,c'=====',TXT_PEN,$3B,c'====='
					dta TXT_PEN,$3A,c'======',TXT_PEN,$39,c'=====',TXT_PEN,$38,c'=====',0
UI_Str_HelpHint		dta TXT_PEN,UI_PEN_LOC,c'Nav: ',TXT_PEN,UI_PEN_KEY,c'ESC'
					dta TXT_PEN,UI_PEN_DESC,c' Go Back ',TXT_PEN,UI_PEN_KEY
					dta $18,$19,TXT_PEN,UI_PEN_DESC,c' Scroll ',TXT_PEN,UI_PEN_KEY
					dta $1B,$1A,TXT_PEN,UI_PEN_DESC,c' Section',0

; Help sections: one $00-terminated row each, $FF ends the section.  Up to
; HELP_VISROWS (19) rows show at once; a longer section scrolls with Up/Down
; (Help_Keys).  Drawn in UI_PEN_HELP; each section's name row switches to
; UI_PEN_HELPHEAD with a TXT_PEN escape.
Help_Page_Lo		dta <Help_Text_1,<Help_Text_2,<Help_Text_3
Help_Page_Hi		dta >Help_Text_1,>Help_Text_2,>Help_Text_3
Help_PageNum_Lo		dta <UI_Str_HelpPage1,<UI_Str_HelpPage2,<UI_Str_HelpPage3
Help_PageNum_Hi		dta >UI_Str_HelpPage1,>UI_Str_HelpPage2,>UI_Str_HelpPage3
UI_Str_HelpPage1	dta c'Section  1 of 3',0	; row 20, centred (col 32)
UI_Str_HelpPage2	dta c'Section  2 of 3',0
UI_Str_HelpPage3	dta c'Section  3 of 3',0

Help_Text_1
	dta TXT_PEN,UI_PEN_HELPHEAD,c'General Information:',0
	dta c'When the image viewer starts, it will scan the current directory',0
	dta c'Subdirectories are displayed alphabetically in Green',0
	dta c'The image (V1K) files will be displayed alphabetically in Blue',0
	dta c'Each V1K file must have a corresponding NFO file to populate the Info screen',0
	dta c'When displaying an image, pressing 0 1 2 3 display that single palette',0
	dta c'Pressing 4 turns the Colour Attribute Map back on and displays all palettes',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPHEAD,c'Display Information:',0
	dta c'The image viewer first sets up a standard 320 x 240 normal width XDL',0
	dta c'It then sets up the Colour Attribute Map to change the overlay palette',0
	dta c'It uses the smallest 8 x 1 cell 40 times per line for all 240 rows',0
	dta c'This allows us to choose any of the 4 palettes for the overlay every 8 pixels',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPHEAD,c'V1K Image Information:',0
	dta c'Each file is a contiguous block of binary data in the following order',0
	dta c'Palettes 0-3   - Each is 768 bytes of RGB data',0
	dta c'Attribute Map  - 9600 bytes which set the Palette to use for every 8*1 cell',0
	dta c'Raw Image Data - 76800 bytes which set the palette index (colour) for each pixel',0
	dta $FF

Help_Text_2
	dta TXT_PEN,UI_PEN_HELPHEAD,c'Main Menu Navigation:',0
	dta TXT_PEN,UI_PEN_HELPNAV,$18,$19,$1B,$1A,c'  ',TXT_PEN,UI_PEN_HELP,c'Move the selector (item will be shown in a brighter colour)',0
	dta TXT_PEN,UI_PEN_HELPNAV,c'Enter ',TXT_PEN,UI_PEN_HELP,c'Make a selection (scan Subdirectory or Open image)',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPNAV,c'S     ',TXT_PEN,UI_PEN_HELP,c'Start a slideshow starting from the selected image',0
	dta TXT_PEN,UI_PEN_HELPNAV,c'< >   ',TXT_PEN,UI_PEN_HELP,c'Set the display time for each image from 1 to 30 seconds',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPNAV,c'D     ',TXT_PEN,UI_PEN_HELP,c'Bring up the Drive Selector',0
	dta c'      D: is the directory from which this program launches, not D1:',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPNAV,c'P     ',TXT_PEN,UI_PEN_HELP,c'Display the 4 256 colour palettes of the highlighted image',0
	dta c'      If no image is highlighted, the 4 palettes used by the menu will be shown',0
	dta c'      Top row displays P0 and P1 while the bottom row displays P2 and P3',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPNAV,c'I     ',TXT_PEN,UI_PEN_HELP,c'Display the conversion report for the highlighted image',0
	dta c'      Jump to Section 3 of this Help screen for more details on this report',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPNAV,c'F     ',TXT_PEN,UI_PEN_HELP,c'Switch between the CGA font and the Atari font',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPNAV,c'Q     ',TXT_PEN,UI_PEN_HELP,c'Display the exit confirmation dialog',0
	dta c'      Y quits the program and returns to DOS',0
	dta c'      N or ESC closes the dialog',0
	dta $FF

Help_Text_3
	dta TXT_PEN,UI_PEN_HELPHEAD,c'Conversion Report:',0
	dta c'Press I on a highlighted image to show the report the convertor wrote for it',0
	dta c'The same report is saved on the PC as {name}_report.txt',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPHEAD,c'Source Information:',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Input / Description  ',TXT_PEN,UI_PEN_HELP,c'The source file name and its description',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Dimensions           ',TXT_PEN,UI_PEN_HELP,c'Size of the source image before resampling',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Resampled            ',TXT_PEN,UI_PEN_HELP,c'Resized to 320 x 240, with the filter and aspect fit used',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Cell width           ',TXT_PEN,UI_PEN_HELP,c'8 pixels per cell: 40 cells per line, 9600 cells in all',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Palettes x slots     ',TXT_PEN,UI_PEN_HELP,c'4 palettes of 256 (slot 0 is transparent, 255 usable)',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Transparent px       ',TXT_PEN,UI_PEN_HELP,c'Letterbox / pillarbox pixels, always shown as index 0',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Pre-quantized        ',TXT_PEN,UI_PEN_HELP,c'Source colours, and what they were reduced to (max 1020)',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Master colours       ',TXT_PEN,UI_PEN_HELP,c'Colours left to be packed into the 4 palettes',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Output colours       ',TXT_PEN,UI_PEN_HELP,c'Distinct colours actually shown on screen',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPHEAD,c'Conversion Settings and Result:',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Convertor Version    ',TXT_PEN,UI_PEN_HELP,c'The convertor release that made this image',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Strategy             ',TXT_PEN,UI_PEN_HELP,c'Fidelity (bias 0) gives the fewest block artifacts',0
	dta c'                     Balanced (bias above 0) trades block artifacts for colours',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Coherence            ',TXT_PEN,UI_PEN_HELP,c'Attribute map smoothing - neighbouring cells share a',0
	dta c'                     palette more often (Balanced strategy only)',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Dithering            ',TXT_PEN,UI_PEN_HELP,c'Pattern used to hide banding when colours were reduced',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Result               ',TXT_PEN,UI_PEN_HELP,c"Lossless - every colour fits its cell's palette, no loss",0
	dta c'                     Lossy - some pixels had to be recoloured to fit',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Recoloured pixels    ',TXT_PEN,UI_PEN_HELP,c'Lossy only: how many pixels changed, and their error',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPHEAD,c'Image Quality (compared to the same image without the 8 x 1 cell rule):',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Identical pixels     ',TXT_PEN,UI_PEN_HELP,c'Pixels unchanged by the cell rule (higher is better)',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'RMSE / PSNR          ',TXT_PEN,UI_PEN_HELP,c'Average colour error (lower RMSE, higher PSNR is better)',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Mean OKLab error     ',TXT_PEN,UI_PEN_HELP,c'Average perceptual colour error (lower is better)',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Worst OKLab error    ',TXT_PEN,UI_PEN_HELP,c"The single worst pixel's perceptual error",0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Cells damaged        ',TXT_PEN,UI_PEN_HELP,c'8 x 1 cells holding at least one changed pixel',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Cell seams           ',TXT_PEN,UI_PEN_HELP,c'About 1.00x = no visible cell grid, higher = blockier',0
	dta 0
	dta TXT_PEN,UI_PEN_HELPHEAD,c'Palette Use:',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Per-palette colours  ',TXT_PEN,UI_PEN_HELP,c'Colours found only in that palette (P0 to P3)',0
	dta TXT_PEN,UI_PEN_HELPKEY,c'Duplicated Colours   ',TXT_PEN,UI_PEN_HELP,c'Palette entries repeated in more than one palette',0
	dta $FF

UI_Str_DriveTitle	dta c'Log Drive',0
UI_Str_QuitConfirm	dta TXT_PEN,UI_PEN_QUITQ,c'Are You Sure To Quit',0
UI_Str_QuitYes		dta TXT_PEN,UI_PEN_YES,c'Y',0
UI_Str_QuitNo		dta TXT_PEN,UI_PEN_NO,c'N',0
UI_Str_Nfo			dta TXT_PEN,UI_PEN_LOC,c'Nfo:',TXT_PEN,UI_PEN_VALUE,c' ',0
UI_Str_StatusBlank	dta c'                                                                                ',0	; 80 spaces (Nfo: + NFO_NAME_CAP)
UI_Str_Scanning		dta c'Scanning directory...',0
UI_Str_ReadNfo		dta c'Reading nfo...',0
UI_Str_ReadPal		dta c'Reading palette...',0
UI_Str_Of			dta c' of ',0
UI_Str_Images		dta c' images',0
UI_Str_Image1		dta c' image ',0

;-----------------------------------------------------------------------------
; Sel_ColX - screen column for grid column c (0..UI_COLS-1), 10-char cells.
; Indexed by (list index AND [UI_COLS-1]).  Relocate the whole grid by
; changing UI_GRIDCOL0 alone.
;-----------------------------------------------------------------------------
Sel_ColX	dta UI_GRIDCOL0+0, UI_GRIDCOL0+10, UI_GRIDCOL0+20, UI_GRIDCOL0+30
			dta UI_GRIDCOL0+40, UI_GRIDCOL0+50, UI_GRIDCOL0+60, UI_GRIDCOL0+70

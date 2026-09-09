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
; Screen model (text80.asm): 80 columns x 30 rows, Palette 0.
;
; UI_Mode:  0 = selector   1 = image view   2 = slideshow
;           3 = drive picker (D-key save-under overlay)   4 = info viewer (.nfo)
;=============================================================================

.def	UI_VISROWS		= 24			; filename rows visible at once (rows 3..26)
.def	UI_FIRSTROW		= 3				; first screen row of the list
; row 27 = slideshow delay, row 28 = key legend, row 29 = bottom margin
.def	UI_SLIDE_MIN	= 1
.def	UI_SLIDE_MAX	= 30
; VBXE text-mode colour byte: bits 0-6 = foreground palette-0 entry (0-127),
; bit 7 = 1 -> opaque background (hardware-forced to palette[fg+128]), 0 ->
; transparent.  UI_Apply_TextPalette de-interleaves the Atari master into set 0
; so entry e = master colour 2e: hue = e>>3 (all 16 hues), luma = (e&7)*2.
; The cursor row is marked by FOREGROUND colour only - no opaque bar - because
; after the de-interleave palette[e+128] is the adjacent-luma neighbour of
; palette[e] and gives no contrast.  Tune the three indices once on screen.
.def	UI_PEN_FG		= $07			; normal text   : hue 0 grey,  luma 14
.def	UI_PEN_HI		= $0F			; highlighted   : hue 1 gold,  luma 14
.def	UI_PEN_DIR		= $62			; directory/".." : hue $C green, luma 4

.def	NFO_BANK		= $25			; VBXE bank(s) the .nfo text streams into (up to 2)
.def	NFO_TOPROW		= 0				; info viewer: first screen row of the scroll region
.def	NFO_VISROWS		= 30			; info viewer: visible text rows (full screen)
; (raise NFO_TOPROW / drop NFO_VISROWS once the fixed logo area is designed)
; NFO_VISROWS must equal TEXT_ROWS while there is no logo band, so the blit
; overwrites every row - anything less leaves the selector's legend on the tail.
.def	NFO_MAX_LINES	= 240			; cap on reformatted .nfo rows (fits banks $27-$2E)

; --- CH key codes (POKEY, no modifier).  Matches the bare-CH style in
;     Handle_Keys (Q $2F, Space $21, BkSp $34, Esc $1C, digits ...).
.def	KEY_UP			= $0E			; "-" key (up-arrow, unshifted)
.def	KEY_DOWN		= $0F			; "=" key (down-arrow, unshifted)
.def	KEY_RETURN		= $0C
.def	KEY_ESC			= $1C
.def	KEY_SPACE		= $21
.def	KEY_Q			= $2F
.def	KEY_S			= $3E
.def	KEY_D			= $3A
.def	KEY_P			= $0A
.def	KEY_I			= $0D
.def	KEY_COMMA		= $20			; "," - shorter slideshow delay
.def	KEY_DOT			= $22			; "." - longer slideshow delay

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

;=============================================================================
; Directory scan  (moved here from init_vbxe.asm's Scan_Images - the scan
; location is now chosen at runtime, so it can't be decided in the loader)
;=============================================================================

;-----------------------------------------------------------------------------
; Rescan_Images - scan Scan_Drive/Scan_Path for *.MAP, rebuild + sort the list.
; Tolerates zero matches (an ordinary state the selector shows).
;-----------------------------------------------------------------------------
Rescan_Images
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
	jsr Sort_Range						; *.MAP files A-Z

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

Build_Spec								; ... + "*.MAP" + EOL
	jsr Build_Spec_Prefix
	ldy #$00
Build_Spec_L1
	lda Build_Spec_MapWild,y
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

Build_Spec_MapWild	dta c'*.MAP',$9B
Build_Spec_AnyWild	dta c'*.*',$9B

;-----------------------------------------------------------------------------
; Build_Image_List - rebuild the selector list in IMAGE_BANK through the $2000
; window, grouped:  ".."  (only below the drive root)  |  sub-directories  |
; *.MAP files.  Rescan_Images sorts the two real groups A-Z afterwards.
; Sets ImageCount, Dir_Count and FileStart (index of the first *.MAP row).
;   - directory pass: OPEN "D[n]:PATH*.*" long DIR format (AUX2 = $80) and keep
;     only lines carrying SDX's "<DIR>" size-column tag (Line_Has_Dir_Tag).
;   - file pass:      OPEN "D[n]:PATH*.MAP" short format (AUX2 = $00) as before.
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

; --- file pass : "D[n]:PATH*.MAP", short format
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
; Enter_Selector - restore Palette 0 for text, show the text screen, draw it.
; Reached from start: (jsr) and from Handle_Escape (jsr) - always returns.
;-----------------------------------------------------------------------------
Enter_Selector
	jsr Restore_Palette0				; standard PAL/NTSC master palette -> set 0
	jsr UI_Apply_TextPalette			; ...then de-interleave it for text mode
	jsr Text_Activate					; point the XDL at the text screen
	lda #$00
	sta UI_Mode
	jsr Selector_Draw
	rts

;-----------------------------------------------------------------------------
; UI_Apply_TextPalette - Restore_Palette0 has just put the standard Atari 256-
; colour master into palette set 0.  The VBXE text mode can only reach entries
; 0-127 as a foreground, and in the master that range is hues 0-7 (no green).
; De-interleave it so:
;     entry e        (0..127) = master colour 2e    (all 16 hues, even lumas)
;     entry 128+e             = master colour 2e+1  (odd lumas - inverse bg)
; Build a page-aligned 768-byte image at VBXE $00800 (free: NTSC master
; $00200-$004FF, PAL master $00500-$007FF, VRAM from $01000) and re-upload it
; as set 0.  Runs only on entry to the selector - not per frame.
; Restore_Palette0 itself is left untouched so the DOS-exit path still restores
; the true master.  Clobbers A/X/Y, Ptr_Lo/Hi, Name_Ptr, Y_Register.
;-----------------------------------------------------------------------------
UI_APPLY_TP_BUF		= VBXE_WINDOW + $800		; page-aligned de-interleave buffer

UI_Apply_TextPalette
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

; --- upload the de-interleaved image as palette set 0
	lda #<UI_APPLY_TP_BUF
	sta Y_Register
	lda #>UI_APPLY_TP_BUF
	sta Y_Register+1
	lda #$00
	jsr VBXE_SetPalette2

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
; Selector_Draw - full repaint.  Only entered from Enter_Selector (boot / ESC)
; and after a rescan; the nav / delay keys repaint just what changed.
;-----------------------------------------------------------------------------
Selector_Draw
	jsr Text_Clear
	jsr UI_Pen_Normal
	TXT_AT 0, 2, UI_Str_Title
	TXT_AT 0, 40, UI_Str_Images
	lda ImageCount
	sec
	sbc FileStart						; count the *.MAP rows only, not ".."/dirs
	jsr Put_U8_Dec_Line
	TXT_AT 0, 48, Txt_Line

	TXT_AT 1, 2, UI_Str_Loc
	jsr UI_Build_LocLine
	TXT_AT 1, 12, Txt_Line

	jsr Selector_DrawList

	jsr UI_Pen_Normal
	TXT_AT 27, 2, UI_Str_Delay
	TXT_AT 27, 23, UI_Str_DelayHint
	TXT_AT 28, 2, UI_Str_Legend
	jmp Selector_DrawDelay				; the delay value at col 19, then rts

;-----------------------------------------------------------------------------
Selector_DrawList
	lda ImageCount
	ora ImageCount+1
	bne Selector_DrawList_Have
	jsr UI_Pen_Normal
	TXT_AT UI_FIRSTROW, 4, UI_Str_Empty
	rts
Selector_DrawList_Have
	lda #$00
	sta Reg5							; Reg5 = visible row 0..VISROWS-1
Selector_DrawList_L1
	lda Reg5
	cmp #UI_VISROWS
	bcs Selector_DrawList_Tail
	clc
	adc Sel_Top
	sta Reg6							; Reg6 = list index for this row
	cmp ImageCount
	bcs Selector_DrawList_Tail			; past the end of the list

	lda Reg6
	ldx #IMAGE_BANK
	jsr UI_ReadRec						; Name_Row_Buf = raw names[Reg6]
	lda Reg6
	jsr UI_RowType
	sta Reg7							; Reg7 = row type (0 file / 1 dir / 2 "..")
	jsr UI_Format_Row					; Name_Row_Buf -> fixed 10-char field

	lda Reg5
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	lda Reg6
	cmp Sel_Index
	bne Selector_DrawList_NotHi
	lda #$01							; pen code 1 = highlighted
	jmp Selector_DrawList_Put
Selector_DrawList_NotHi
	lda Reg7
	beq Selector_DrawList_Put			; file -> pen code 0
	lda #$02							; dir / ".." -> pen code 2
Selector_DrawList_Put
	jsr UI_DrawNameRow
	inc Reg5
	jmp Selector_DrawList_L1

Selector_DrawList_Tail
; list has rows but none are *.MAP files -> note it under the last entry
	lda FileStart
	cmp ImageCount
	bcc Selector_DrawList_Done			; some files present
	lda ImageCount
	beq Selector_DrawList_Done			; wholly empty -> UI_Str_Empty already drawn
	lda ImageCount
	sec
	sbc Sel_Top							; rows from the top of the window
	cmp #UI_VISROWS
	bcs Selector_DrawList_Done			; tail row is off-screen
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	jsr UI_Pen_Normal
	lda #$04
	sta Txt_Col
	lda #<UI_Str_Empty
	sta Txt_Ptr
	lda #>UI_Str_Empty
	sta Txt_Ptr + $01
	jsr Text_PutStrAt
Selector_DrawList_Done
	rts

;-----------------------------------------------------------------------------
; Selector_HiRow - A = list index.  Recolours just that row's 8 name cells
; (attribute bytes only, via the blitter - no glyph redraw), highlighted if the
; index == Sel_Index, else normal.  No-op if the row isn't on screen.  Used by
; the up/down keys: a cursor move only changes which row carries the bar.
;-----------------------------------------------------------------------------
Selector_HiRow
	sta Reg6							; Reg6 = list index
	cmp Sel_Top
	bcc Selector_HiRow_Skip				; above the window
	sec
	sbc Sel_Top
	cmp #UI_VISROWS
	bcs Selector_HiRow_Skip				; below the window
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	lda Reg6
	cmp ImageCount
	bcs Selector_HiRow_Skip				; past the end of the list
	lda #4
	sta Txt_Col
	lda #9
	sta Reg1							; width-1 = 10 cells ("<NAME....>")
	lda #$00
	sta Reg2							; height-1 = 1 row
	lda Reg6
	cmp Sel_Index
	beq Selector_HiRow_Hi
	lda Reg6
	jsr UI_RowType						; normal: dir/".." pen for those rows,
	beq Selector_HiRow_File				; file pen otherwise (foreground only)
	lda #UI_PEN_DIR
	jmp Text_FillColour					; tail
Selector_HiRow_File
	lda #UI_PEN_FG
	jmp Text_FillColour					; tail
Selector_HiRow_Hi
	lda #UI_PEN_HI						; highlighted: gold foreground, no bar
	jmp Text_FillColour					; tail
Selector_HiRow_Skip
	rts

;-----------------------------------------------------------------------------
; Selector_DrawDelay - repaint just the slideshow-delay value (row 27, col 19).
; A 3-char field so 10 -> 9 doesn't leave a stale digit.
;-----------------------------------------------------------------------------
Selector_DrawDelay
	jsr UI_Pen_Normal
	lda Slide_Secs
	jsr Put_U8_Dec_Line					; Txt_Line = "N" / "NN", NUL
	ldx #$00
Selector_DrawDelay_End
	lda Txt_Line,x
	beq Selector_DrawDelay_Pad
	inx
	bne Selector_DrawDelay_End
Selector_DrawDelay_Pad
	lda #' '
Selector_DrawDelay_Pad2
	sta Txt_Line,x
	inx
	cpx #$03
	bcc Selector_DrawDelay_Pad2
	lda #$00
	sta Txt_Line,x
	TXT_AT 27, 19, Txt_Line
	rts

;-----------------------------------------------------------------------------
; UI_DrawNameRow - A = pen code (0 file / 1 highlighted / 2 directory or "..").
; Draws Name_Row_Buf (already formatted by UI_Format_Row) at col 4 of Txt_Row.
;-----------------------------------------------------------------------------
UI_DrawNameRow
	tax									; X = pen code
	lda #4
	sta Txt_Col
	cpx #$01
	bne UI_DrawNameRow_1
	jsr UI_Pen_Invert
	jmp UI_DrawNameRow_P
UI_DrawNameRow_1
	cpx #$02
	bne UI_DrawNameRow_N
	jsr UI_Pen_DirRow
	jmp UI_DrawNameRow_P
UI_DrawNameRow_N
	jsr UI_Pen_Normal
UI_DrawNameRow_P
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
	bcs UI_RowType_File					; index >= FileStart -> *.MAP file
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
UI_Pen_Invert							; the highlighted list row (foreground only)
	lda #UI_PEN_HI
	ldx #$00							; transparent bg - no bar after the palette repack
	jmp Text_SetPen
UI_Pen_DirRow							; directory / ".." rows
	lda #UI_PEN_DIR
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
	cmp #KEY_DOWN
	bne SelK_1
	jmp Sel_Key_Down
SelK_1
	cmp #KEY_UP
	bne SelK_2
	jmp Sel_Key_Up
SelK_2
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

Sel_Key_Down
	lda ImageCount
	ora ImageCount+1
	beq Sel_Key_Nav_Done				; empty list
	ldx Sel_Index
	inx
	cpx ImageCount
	bcs Sel_Key_Nav_Done				; already on the last entry
	lda Sel_Index
	sta Reg3							; Reg3 = old (now un-highlighted) index
	stx Sel_Index
	txa									; T = Sel_Index - (VISROWS-1)
	sec
	sbc #[UI_VISROWS-1]
	bcc Sel_Key_Down_Rows				; T negative -> still visible
	cmp Sel_Top
	bcc Sel_Key_Down_Rows
	beq Sel_Key_Down_Rows
	sta Sel_Top							; scrolled -> repaint the whole list in place
	jsr Selector_DrawList
	jmp Read_Key_Done
Sel_Key_Down_Rows
	lda Reg3
	jsr Selector_HiRow					; un-highlight the row we left
	lda Sel_Index
	jsr Selector_HiRow					; highlight the row we moved to
Sel_Key_Nav_Done
	jmp Read_Key_Done

Sel_Key_Up
	lda Sel_Index
	beq Sel_Key_Nav_Done				; already at the top
	sta Reg3							; Reg3 = old (now un-highlighted) index
	sec
	sbc #$01
	sta Sel_Index
	cmp Sel_Top
	bcs Sel_Key_Up_Rows					; still visible
	sta Sel_Top							; scrolled -> repaint the whole list in place
	jsr Selector_DrawList
	jmp Read_Key_Done
Sel_Key_Up_Rows
	lda Reg3
	jsr Selector_HiRow
	lda Sel_Index
	jsr Selector_HiRow
	jmp Read_Key_Done

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
	jsr UI_Pen_Normal
	jsr Drive_Win_Geom
	jsr Text_Window_Save				; keep the list underneath intact
	jsr Text_Window_Frame

	lda #DRIVE_WIN_ROW+1					; title on the first interior row
	sta Txt_Row
	lda #DRIVE_WIN_COL+2
	sta Txt_Col
	lda #<UI_Str_DriveTitle
	sta Txt_Ptr
	lda #>UI_Str_DriveTitle
	sta Txt_Ptr + $01
	jsr Text_PutStrAt

	lda Scan_Drive						; seed the cursor from the current drive
	beq Sel_Key_Drive_Seed0
	sec
	sbc #'0'
	jmp Sel_Key_Drive_SeedSet
Sel_Key_Drive_Seed0
	lda #$00
Sel_Key_Drive_SeedSet
	sta Drive_Pick_Index

	jsr Drive_DrawRows
	lda #$03
	sta UI_Mode
	jmp Read_Key_Done

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
	bne DrvK_4
	jsr Drive_Win_Geom
	jsr Text_Window_Restore
	lda #$00
	sta UI_Mode
	jmp Read_Key_Done
DrvK_4
	cmp #KEY_Q
	bne Drive_Keys_Ret
	jmp Exit
Drive_Keys_Ret
	jmp Read_Key_Done

Sel_Key_P
	jsr Selector_Handle_P
	jmp Read_Key_Done
Sel_Key_I
	jsr Selector_Handle_I
	jmp Read_Key_Done
Sel_Key_Quit
	jmp Exit

;-----------------------------------------------------------------------------
; View_Selected - show Sel_Index as a full image (attribute-map path).
;-----------------------------------------------------------------------------
View_Selected
	lda Sel_Index
	sta File_Index
	jsr Text_Deactivate
	jsr Clear_Screen
	jsr Load_Image
	jsr Enable_Colour_Map
	rts

;-----------------------------------------------------------------------------
; Selector_Sync_Cursor - pull the selector highlight back onto File_Index.
; Space / Backspace (image view) and the slideshow move File_Index while an
; image is on screen; call this before returning to the selector so its
; highlight follows the picture you were actually looking at, scrolling the
; list if the entry is off-screen.  Mirrors Sel_Key_Down's scroll math.
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
	cmp Sel_Top
	bcs Selector_Sync_Bottom			; index >= Sel_Top - check the far edge
	sta Sel_Top							; scrolled up off the top
	rts
Selector_Sync_Bottom
	sec
	sbc #[UI_VISROWS-1]					; T = Sel_Index - (VISROWS-1)
	bcc Selector_Sync_Done				; T negative -> already visible
	cmp Sel_Top
	bcc Selector_Sync_Done
	beq Selector_Sync_Done
	sta Sel_Top							; scrolled down off the bottom
Selector_Sync_Done
	rts
Selector_Sync_Zero
	lda #$00
	sta Sel_Index
	sta Sel_Top
	rts

;-----------------------------------------------------------------------------
; Selector_Handle_P - stub (future: 4-palette screen; Stephen supplies XDL+data)
;-----------------------------------------------------------------------------
Selector_Handle_P
	rts

;-----------------------------------------------------------------------------
; Selector_Handle_I - load the selected image's "<name>.NFO" and open the info
; viewer (UI_Mode 4).  Missing file -> stay on the selector, do nothing.
;-----------------------------------------------------------------------------
Selector_Handle_I
	lda ImageCount
	ora ImageCount+1
	beq Selector_Handle_I_Ret			; no images -> nothing to describe
	lda Sel_Index
	sta File_Index
	lda #$03							; ext selector 3 = .NFO
	jsr Build_Filename					; FileNamePtr -> "D[n]:PATH<base>.NFO",0
	jsr Info_Load						; stream into NFO_BANK, count lines
	lda LoadStatus
	beq Selector_Handle_I_Ret			; OPEN failed (no .nfo) - selector stays up
	lda #$00
	sta Nfo_Top
	sta Nfo_Top + $01
	jsr Info_Draw
	lda #$04
	sta UI_Mode
Selector_Handle_I_Ret
	rts

;=============================================================================
; Slideshow  (UI_Mode = 2)
;=============================================================================
Slideshow_Keys
	lda CH
	cmp #KEY_ESC
	beq Slide_Key_Stop
	cmp #KEY_SPACE
	beq Slide_Key_Next
	cmp #KEY_Q
	beq Slide_Key_Quit
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
Slide_Key_Quit
	jmp Exit

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
; Info viewer  (UI_Mode = 4) - shows "<image>.NFO" verbatim, monochrome,
; scrollable.  The text is streamed into NFO_BANK (up to 2 VBXE banks); the
; first $00 byte past the file marks the end (the banks are wiped first).
;=============================================================================

;-----------------------------------------------------------------------------
; Info_Load - wipe NFO_BANK / NFO_BANK+1, stream FileNamePtr into them via
; LoadData, then count lines.  LoadStatus (fileio.lib) = 0 if the OPEN failed.
;-----------------------------------------------------------------------------
Info_Load
	lda #NFO_BANK
	sta Nfo_WalkBank
Info_Load_ClearMap
	lda Nfo_WalkBank
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #<VBXE_WINDOW
	sta Ptr_Lo
	lda #>VBXE_WINDOW
	sta Ptr_Hi
	ldx #$10							; 16 pages = one 4K bank
	lda #$00
	tay
Info_Load_ClearPage
	sta (Ptr_Lo),y
	iny
	bne Info_Load_ClearPage
	inc Ptr_Hi
	dex
	bne Info_Load_ClearPage
	inc Nfo_WalkBank
	lda Nfo_WalkBank
	cmp #NFO_BANK + 2
	bcc Info_Load_ClearMap
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL

	lda #NFO_BANK
	sta BankIndex
	jsr LoadData						; FileNamePtr was set by Build_Filename
	lda LoadStatus
	beq Info_Load_Ret					; OPEN failed - Selector_Handle_I bails
	jsr Info_Format_Page				; reformat -> MONO_PAGE, sets Nfo_LineCount
Info_Load_Ret
	rts

;-----------------------------------------------------------------------------
; Info_Walk_Advance - Ptr_Lo/Hi += 1, stepping to NFO_BANK+1 at the $3000 edge
; and re-mapping the window.  Returns C=1 if the 2-bank cap was hit (caller
; treats that as end-of-text), C=0 otherwise.
;-----------------------------------------------------------------------------
Info_Walk_Advance
	inc Ptr_Lo
	bne Info_Walk_OK
	inc Ptr_Hi
	lda Ptr_Hi
	cmp #>VBXE_WINDOW + $10
	bcc Info_Walk_OK
	inc Nfo_WalkBank
	lda Nfo_WalkBank
	cmp #NFO_BANK + 2
	bcs Info_Walk_Cap
	lda Nfo_WalkBank
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #<VBXE_WINDOW
	sta Ptr_Lo
	lda #>VBXE_WINDOW
	sta Ptr_Hi
Info_Walk_OK
	clc
	rts
Info_Walk_Cap
	sec
	rts

;-----------------------------------------------------------------------------
; Info_Format_Page - walk the raw .nfo (already streamed into NFO_BANK/+1) line
; by line, writing each line space-padded to TEXT_COLS bytes into MONO_PAGE
; (MONO_PAGE_STRIDE bytes/row), capped at NFO_MAX_LINES.  Leaves the row total
; in Nfo_LineCount.  Window left unmapped.
;-----------------------------------------------------------------------------
Info_Format_Page
	lda #$00
	sta Nfo_LineCount
	sta Nfo_LineCount + $01
	lda #NFO_BANK
	sta Nfo_WalkBank
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #<VBXE_WINDOW
	sta Nfo_WalkLo
	sta Ptr_Lo
	lda #>VBXE_WINDOW
	sta Nfo_WalkHi
	sta Ptr_Hi
	ldy #$00
	lda (Ptr_Lo),y
	bne Info_Fmt_Loop					; non-empty .nfo
	jmp Info_Fmt_Done					; empty .nfo -> 0 rows
Info_Fmt_Loop
	jsr Info_Copy_Line					; NfoLineBuf <- line; Reg7 = last-line flag
	lda NfoLineBuf
	bne Info_Fmt_Write
	lda Reg7
	bne Info_Fmt_Done					; trailing empty line - do not count it
Info_Fmt_Write
	jsr Info_Write_PageRow				; NfoLineBuf -> MONO_PAGE row Nfo_LineCount
	inc Nfo_LineCount
	bne Info_Fmt_NC
	inc Nfo_LineCount + $01
Info_Fmt_NC
	lda Reg7
	bne Info_Fmt_Done					; that was the last line
	lda Nfo_LineCount + $01
	bne Info_Fmt_Done					; > 255 rows (paranoia)
	lda Nfo_LineCount
	cmp #NFO_MAX_LINES
	bcs Info_Fmt_Done					; hit the row cap
	lda Nfo_WalkBank					; re-map the walk bank for the next Info_Copy_Line
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	jmp Info_Fmt_Loop
Info_Fmt_Done
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	rts

;-----------------------------------------------------------------------------
; Info_Write_PageRow - write NfoLineBuf (NUL-terminated, <= TEXT_COLS chars),
; space-padded to TEXT_COLS bytes, into MONO_PAGE at row Nfo_LineCount.  Maps a
; MONO_PAGE bank into the $2000 window; the caller re-maps the walk bank after.
; Requires Nfo_LineCount < NFO_MAX_LINES (< 256), so the 80-byte row cannot
; straddle a bank (MONO_PAGE_STRIDE 128 divides the 4K bank).
;-----------------------------------------------------------------------------
Info_Write_PageRow
	lda Nfo_LineCount
	pha									; keep the row number
	lsr									; row >> 5  -> MONO_PAGE bank offset
	lsr
	lsr
	lsr
	lsr
	clc
	adc #MONO_PAGE_BANK
	ora #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	pla
	and #$1F							; row & 31
	lsr									; (row & 31) >> 1  -> window page offset
	pha
	lda #$00
	ror									; row bit 0 -> bit 7  ->  $00 / $80
	sta Ptr_Lo
	pla
	clc
	adc #>VBXE_WINDOW					; + $20   ->  window ptr = $2000 + (row & 31)*128
	sta Ptr_Hi
	ldx #$00							; X != 0 once we are padding
	ldy #$00
Info_WPR_L1
	txa
	bne Info_WPR_Pad
	lda NfoLineBuf,y
	bne Info_WPR_Store
	inx									; NUL -> pad the rest of the row with spaces
Info_WPR_Pad
	lda #$20
Info_WPR_Store
	sta (Ptr_Lo),y
	iny
	cpy #TEXT_COLS
	bne Info_WPR_L1
	rts

;-----------------------------------------------------------------------------
; Info_Copy_Line - copy the line at Nfo_WalkLo/Hi (window already mapped to
; Nfo_WalkBank) into NfoLineBuf, NUL-terminated, clipped at TEXT_COLS.  Steps
; the walk pointer past the trailing EOL.  Reg7 = 1 if this was the last line.
; X = dest column.
;-----------------------------------------------------------------------------
Info_Copy_Line
	lda Nfo_WalkLo
	sta Ptr_Lo
	lda Nfo_WalkHi
	sta Ptr_Hi
	lda #$00
	sta Reg7
	ldx #$00
Info_Copy_L1
	ldy #$00
	lda (Ptr_Lo),y
	beq Info_Copy_EOF
	cmp #$9B
	beq Info_Copy_EOL
	cmp #$0A
	beq Info_Copy_EOL
	cmp #$0D
	beq Info_Copy_Skip					; ignore CR
	cpx #TEXT_COLS
	bcs Info_Copy_Skip					; clip past column 80
	sta NfoLineBuf,x
	inx
Info_Copy_Skip
	jsr Info_Walk_Advance
	bcc Info_Copy_L1
Info_Copy_EOF
	lda #$01
	sta Reg7
	jmp Info_Copy_Fin
Info_Copy_EOL
	jsr Info_Walk_Advance				; consume the EOL
	bcc Info_Copy_Fin
	lda #$01
	sta Reg7
Info_Copy_Fin
	lda #$00
	sta NfoLineBuf,x
	lda Ptr_Lo
	sta Nfo_WalkLo
	lda Ptr_Hi
	sta Nfo_WalkHi
	rts

;-----------------------------------------------------------------------------
; Info_Draw - blit an NFO_VISROWS window of MONO_PAGE (starting at row Nfo_Top)
; onto the text screen in one blitter chain - no per-key re-walk.  When the
; whole .nfo is shorter than the window, clear first and blit only real rows.
;-----------------------------------------------------------------------------
Info_Draw
; Reg6:Reg5 = Nfo_LineCount - Nfo_Top   (rows available; >= 0 by scroll invariant)
	sec
	lda Nfo_LineCount
	sbc Nfo_Top
	sta Reg5
	lda Nfo_LineCount + $01
	sbc Nfo_Top + $01
	sta Reg6
; rows = min(available, NFO_VISROWS)
	lda Reg6
	bne Info_Draw_Full					; >= 256 available -> full window
	lda Reg5
	cmp #NFO_VISROWS
	bcs Info_Draw_Full
; short document: clear, then blit only the rows that exist
	lda Reg5
	sta Reg4
	jsr Text_Clear
	lda Reg4
	beq Info_Draw_Ret					; nothing to draw
	dec Reg4							; Reg4 = height-1
	jmp Info_Draw_Blit
Info_Draw_Full
	lda #NFO_VISROWS-1
	sta Reg4
Info_Draw_Blit
; source = MONO_PAGE_VRAM + Nfo_Top * MONO_PAGE_STRIDE (128)
	lda Nfo_Top
	lsr									; Nfo_Top >> 1
	sta Reg2
	lda #$00
	ror									; Nfo_Top bit 0 -> bit 7  ->  $00 / $80
	sta Reg1							; source offset low
	lda Reg2
	clc
	adc #$70							; + $70  (low 16 bits of MONO_PAGE_VRAM = $7000)
	sta Reg2							; source offset mid
	lda #$02							; bits 16-18 of MONO_PAGE_VRAM
	sta Reg3
	lda #NFO_TOPROW
	sta Txt_Row
	lda #UI_PEN_FG
	jsr Text_BlitMonoPage
Info_Draw_Ret
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
	cmp #KEY_UP
	bne InfK_1
	jmp Info_Key_Up
InfK_1
	cmp #KEY_DOWN
	bne InfK_2
	jmp Info_Key_Down
InfK_2
	cmp #KEY_COMMA
	bne InfK_3
	jmp Info_Key_PageUp
InfK_3
	cmp #KEY_DOT
	bne InfK_4
	jmp Info_Key_PageDown
InfK_4
	cmp #KEY_ESC
	beq Info_Key_Leave
	cmp #KEY_I
	beq Info_Key_Leave
	cmp #KEY_Q
	bne InfK_None
	jmp Exit
InfK_None
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
	ldx #NFO_VISROWS
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
	ldx #NFO_VISROWS
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
UI_Str_Title		dta c'1024 Colour Picture Viewer',0
UI_Str_Images		dta c'Images: ',0
UI_Str_Loc			dta c'Location: ',0
UI_Str_Empty		dta c'(no images found here)',0
UI_Str_Delay		dta c'Slideshow delay: ',0
UI_Str_DelayHint	dta c's    , shorter    . longer',0
UI_Str_Legend		dta c'Up/Dn move  ENTER open  S slide  D drive  P pal  I info  Q quit',0
UI_Str_DriveTitle	dta c'Scan drive',0

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
; UI_Mode:  0 = selector   1 = image view   2 = slideshow   3 = folder browser
;=============================================================================

.def	UI_VISROWS		= 24			; filename rows visible at once (rows 3..26)
.def	UI_FIRSTROW		= 3				; first screen row of the list
; row 27 = slideshow delay, row 28 = key legend, row 29 = bottom margin
.def	UI_SLIDE_MIN	= 1
.def	UI_SLIDE_MAX	= 30
; VBXE text-mode colour byte: low 7 bits = foreground palette entry (0-127),
; bit 7 = 1 -> opaque (coloured) background, 0 -> transparent.  So Text_SetPen
; takes A = fg palette index, X = 0 (transparent bg) / non-zero (opaque bg).
; The highlighted row is drawn opaque; the plain rows transparent.  Tune the
; two indices once it's on screen.
.def	UI_PEN_FG		= $0F			; normal text foreground (palette 0 index)
; Highlighted row: hardware forces bg = UI_PEN_HI+$80 (hue 8, blue) and text =
; UI_PEN_HI (hue 0, grey), sharing the luma nibble.  $04 = royal-blue bar,
; dark-grey text - readable; $00 was a near-black bar.
.def	UI_PEN_HI		= $04			; highlighted-row text foreground

.def	DIRBROW_BANK	= $41			; VBXE bank holding the folder-browser list
.def	DIRBROW_MAX		= 200			; cap on browser entries

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
.def	KEY_F			= $38
.def	KEY_P			= $0A
.def	KEY_A			= $3F
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
	jsr Build_Spec						; Scan_Spec = "D[n]:PATH*.MAP",EOL
	jsr Build_Image_List				; fills IMAGE_BANK, sets ImageCount
	jsr Sort_Image_List
	lda #$00
	sta Sel_Index
	sta Sel_Top
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
; Build_Image_List - OPEN Scan_Spec as a directory (the wildcard filters), GET
; each line, pack every base name as an 8-byte space-padded record into
; IMAGE_BANK through the $2000 window.  ImageCount = entries stored.
;-----------------------------------------------------------------------------
Build_Image_List
	lda #$00
	sta ImageCount
	sta ImageCount+1

	jsr Find_First_IOCB
	cpy #$01
	beq Build_Image_List_Have_IOCB
	rts									; No free IOCB - ImageCount stays 0
Build_Image_List_Have_IOCB
	stx Dir_IOCB

	lda #CIO_dir
	sta ICAX1,x
	lda #$00								; AUX2 = short DIRS format: plain name lines,
	sta ICAX2,x							; no "Volume:"/"Directory:" header records to
										; mistake for image names (Parse_Dir_Line has
										; no "<DIR>" filter on this path)
	lda #<Scan_Spec
	sta ICBAL,x
	lda #>Scan_Spec
	sta ICBAH,x
	lda #CIO_open
	sta ICCOM,x
	jsr CIOV
	bmi Build_Image_List_Done			; OPEN failed - nothing to scan

	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	mwa #ImageNames Name_Ptr

Build_Image_List_L1
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
	bmi Build_Image_List_Close			; Negative status (EOF or error) - done

; Table full? Compare the write cursor to the end of the reserved space
	lda Name_Ptr+1
	cmp #>ImageNames_End
	bcc Build_Image_List_Room
	bne Build_Image_List_L1				; Hi byte over end - full, skip storing
	lda Name_Ptr
	cmp #<ImageNames_End
	bcs Build_Image_List_L1				; At/past end - full
Build_Image_List_Room
	jsr Parse_Dir_Line
	beq Build_Image_List_L1				; A=0 - not a real filename

	inc ImageCount
	bne Build_Image_List_Adv
	inc ImageCount+1
Build_Image_List_Adv
	lda Name_Ptr
	clc
	adc #$08
	sta Name_Ptr
	bcc Build_Image_List_L1
	inc Name_Ptr+1
	jmp Build_Image_List_L1

Build_Image_List_Close
	ldx Dir_IOCB
	lda #CIO_close
	sta ICCOM,x
	jsr CIOV

	lda #MEMAC_GLOBAL_DISABLE			; Give the CPU back $2000-$2FFF
	vbsta VBXE_MA_BSEL
Build_Image_List_Done
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
	jsr Text_Activate					; point the XDL at the text screen
	lda #$00
	sta UI_Mode
	jsr Selector_Draw
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
	bcs Selector_DrawList_Done
	clc
	adc Sel_Top
	sta Reg6							; Reg6 = list index for this row
	cmp ImageCount
	bcs Selector_DrawList_Done			; past the end of the list

	lda Reg6
	ldx #IMAGE_BANK
	jsr UI_ReadRec						; Name_Row_Buf = names[Reg6]

	lda Reg5
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	lda Reg6
	cmp Sel_Index
	beq Selector_DrawList_Hi
	lda #$00
	jmp Selector_DrawList_Put
Selector_DrawList_Hi
	lda #$01
Selector_DrawList_Put
	jsr UI_DrawNameRow
	inc Reg5
	jmp Selector_DrawList_L1
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
	lda #7
	sta Reg1							; width-1 = 8 name cells
	lda #$00
	sta Reg2							; height-1 = 1 row
	lda Reg6
	cmp Sel_Index
	beq Selector_HiRow_Hi
	lda #UI_PEN_FG						; normal: attr $0F (fg $0F, transparent bg)
	jmp Text_FillColour					; tail
Selector_HiRow_Hi
	lda #UI_PEN_HI | $80				; highlighted: attr $84 (fg $04, opaque bg)
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
; UI_DrawNameRow - A = 0 normal / non-zero highlighted.  Name_Row_Buf -> col 4
; of the screen row already in Txt_Row.
;-----------------------------------------------------------------------------
UI_DrawNameRow
	tax									; stash the highlight flag
	lda #4
	sta Txt_Col
	txa
	beq UI_DrawNameRow_N
	jsr UI_Pen_Invert
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
UI_Pen_Normal
	lda #UI_PEN_FG
	ldx #$00							; transparent background
	jmp Text_SetPen
UI_Pen_Invert							; the highlighted list row
	lda #UI_PEN_HI
	ldx #$01							; opaque background (attribute bit 7)
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

Folder_ReadName							; A = browser index -> Name_Row_Buf
	ldx #DIRBROW_BANK
	jmp UI_ReadRec

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
	bne SelK_7
	jmp Sel_Key_Drive
SelK_7
	cmp #KEY_F
	bne SelK_8
	jmp Sel_Key_Folder
SelK_8
	cmp #KEY_P
	bne SelK_9
	jmp Sel_Key_P
SelK_9
	cmp #KEY_A
	bne SelK_10
	jmp Sel_Key_A
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
	jsr View_Selected
	lda #$01
	sta UI_Mode
	jmp Read_Key_Done

Sel_Key_Show
	lda ImageCount
	ora ImageCount+1
	beq Sel_RD
	jsr View_Selected
	jsr Slideshow_Reload_Counter
	lda #$02
	sta UI_Mode
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

Sel_Key_Drive
	lda Scan_Drive
	bne Sel_Key_Drive_Digit
	lda #'1'-1							; $00 -> begin cycling at '1'
Sel_Key_Drive_Digit
	clc
	adc #$01
	cmp #'8'+1
	bcc Sel_Key_Drive_Store
	lda #$00							; past '8' -> back to a bare "D:"
Sel_Key_Drive_Store
	sta Scan_Drive
	lda #$00
	sta Scan_Path						; new drive -> start at its root
	jsr Rescan_Images
	jmp Sel_Redraw

Sel_Key_Folder
; save the current path so ESC in the browser can cancel back to it.
; Folder_Saved_Path is a dedicated buffer - Txt_Line is rewritten by every
; screen draw the browser does, so it cannot survive the session.
	ldy #$00
Sel_Key_Folder_Save
	lda Scan_Path,y
	sta Folder_Saved_Path,y
	beq Sel_Key_Folder_Go
	iny
	cpy #$28
	bcc Sel_Key_Folder_Save
Sel_Key_Folder_Go
	jsr Folder_Scan
	lda #$00
	sta Brow_Index
	sta Brow_Top
	lda #$03
	sta UI_Mode
	jsr Folder_Draw
	jmp Read_Key_Done

Sel_Key_P
	jsr Selector_Handle_P
	jmp Read_Key_Done
Sel_Key_A
	jsr Selector_Handle_A
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
; Selector_Handle_A - load the selected image's "<name>.NFO" and open the info
; viewer (UI_Mode 4).  Missing file -> stay on the selector, do nothing.
;-----------------------------------------------------------------------------
Selector_Handle_A
	lda ImageCount
	ora ImageCount+1
	beq Selector_Handle_A_Ret			; no images -> nothing to describe
	lda Sel_Index
	sta File_Index
	lda #$03							; ext selector 3 = .NFO
	jsr Build_Filename					; FileNamePtr -> "D[n]:PATH<base>.NFO",0
	jsr Info_Load						; stream into NFO_BANK, count lines
	lda LoadStatus
	beq Selector_Handle_A_Ret			; OPEN failed (no .nfo) - selector stays up
	lda #$00
	sta Nfo_Top
	sta Nfo_Top + $01
	jsr Info_Draw
	lda #$04
	sta UI_Mode
Selector_Handle_A_Ret
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
	beq Info_Load_Ret					; OPEN failed - Selector_Handle_A bails
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
	cmp #KEY_A
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
; Folder browser  (UI_Mode = 3)
;-----------------------------------------------------------------------------
; Lists the sub-directories under D[n]:Scan_Path (files are filtered out by the
; "<DIR>" tag SDX puts in a CIO directory listing).  ENTER descends into the
; highlighted entry (append ">name") and re-scans; ".." pops a segment.  SPACE
; commits the current location (rescan images, back to the selector).  ESC
; restores the path we came in with and returns.
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
; Folder_Scan - build the browser list in DIRBROW_BANK from D[n]:Scan_Path*.*
;-----------------------------------------------------------------------------
Folder_Scan
	lda #$00
	sta Brow_Count

; ".." at slot 0 whenever we are below the drive root
	lda Scan_Path
	beq Folder_Scan_Open
	lda #DIRBROW_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	lda #'.'
	sta VBXE_WINDOW+0
	sta VBXE_WINDOW+1
	lda #' '
	sta VBXE_WINDOW+2
	sta VBXE_WINDOW+3
	sta VBXE_WINDOW+4
	sta VBXE_WINDOW+5
	sta VBXE_WINDOW+6
	sta VBXE_WINDOW+7
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
	inc Brow_Count

Folder_Scan_Open
	jsr Build_Browse_Spec
	jsr Find_First_IOCB
	cpy #$01
	beq Folder_Scan_Have_IOCB
	rts
Folder_Scan_Have_IOCB
	stx Dir_IOCB
	lda #CIO_dir
	sta ICAX1,x
	lda #$80								; AUX2 = long DIR format: subdirs get the
	sta ICAX2,x							; "<DIR>" size-field tag Line_Has_Dir_Tag
										; looks for.  AUX2=0 gives the short (DIRS)
										; format where a subdir is only flagged by a
										; ':' name prefix, so every folder was being
										; read then misclassified as a file and
										; dropped.  Long format also prepends
										; "Volume:"/"Directory:" header lines - those
										; carry no "<DIR>" tag so the filter below
										; discards them anyway.  $A8 stays <= 40
										; chars/line (fits Dir_Line_Buf).
	lda #<Scan_Spec
	sta ICBAL,x
	lda #>Scan_Spec
	sta ICBAH,x
	lda #CIO_open
	sta ICCOM,x
	jsr CIOV
	bmi Folder_Scan_Done				; OPEN failed - keep just ".."

	lda Brow_Count						; write cursor starts after ".."
	jsr Sort_SetNamePtr					; Name_Ptr = ImageNames + Brow_Count*8
	lda #DIRBROW_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL

Folder_Scan_L1
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
	bmi Folder_Scan_Close

	lda Brow_Count
	cmp #DIRBROW_MAX
	bcs Folder_Scan_L1					; list full - drain the rest

	jsr Parse_Dir_Line
	beq Folder_Scan_L1					; not a real name

	ldy #$00							; drop "." / ".." from the listing itself
	lda (Name_Ptr),y
	cmp #'.'
	beq Folder_Scan_L1

	jsr Line_Has_Dir_Tag				; SDX marks subdirs with "<DIR>" in the listing
	beq Folder_Scan_L1					; no tag -> it's a file, skip it

	inc Brow_Count
	lda Name_Ptr
	clc
	adc #$08
	sta Name_Ptr
	bcc Folder_Scan_L1
	inc Name_Ptr+1
	jmp Folder_Scan_L1

Folder_Scan_Close
	ldx Dir_IOCB
	lda #CIO_close
	sta ICCOM,x
	jsr CIOV
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
Folder_Scan_Done
	rts

;-----------------------------------------------------------------------------
; Folder_Draw - full repaint (Text_Clear + chrome + list + legend).  Only from
; Sel_Key_Folder and Folder_Redraw; the nav keys use Folder_HiRow (cursor move)
; / Folder_DrawList (scroll) in place, like the selector.
;-----------------------------------------------------------------------------
Folder_Draw
	jsr Text_Clear
	jsr UI_Pen_Normal
	TXT_AT 0, 2, UI_Str_FolderTitle
	TXT_AT 1, 2, UI_Str_Loc
	jsr UI_Build_LocLine
	TXT_AT 1, 12, Txt_Line

	jsr Folder_DrawList

	jsr UI_Pen_Normal
	TXT_AT 28, 2, UI_Str_FolderLegend
	rts

;-----------------------------------------------------------------------------
; Folder_RealCount - A = browser entries that are not the synthetic ".." (which
; sits at slot 0 only when Scan_Path is non-empty).
;-----------------------------------------------------------------------------
Folder_RealCount
	lda Scan_Path
	beq Folder_RealCount_Raw			; at the drive root - no ".."
	lda Brow_Count
	beq Folder_RealCount_Raw			; (defensive) nothing at all
	sec
	sbc #$01
	rts
Folder_RealCount_Raw
	lda Brow_Count
	rts

;-----------------------------------------------------------------------------
; Folder_DrawList - repaint the whole browser list in place (no Text_Clear, no
; chrome).  Adds "(no directories found here)" below the last row when there
; are no real sub-directories.
;-----------------------------------------------------------------------------
Folder_DrawList
	jsr Folder_DrawList_Body
	jsr Folder_RealCount
	bne Folder_DrawList_Ret
	jsr UI_Pen_Normal
	lda Brow_Count						; 0 (root) or 1 (just "..") -> row after it
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	lda #4
	sta Txt_Col
	lda #<UI_Str_NoDirs
	sta Txt_Ptr
	lda #>UI_Str_NoDirs
	sta Txt_Ptr + $01
	jsr Text_PutStrAt
Folder_DrawList_Ret
	rts

Folder_DrawList_Body
	lda #$00
	sta Reg5							; Reg5 = visible row 0..VISROWS-1
Folder_DrawList_L1
	lda Reg5
	cmp #UI_VISROWS
	bcs Folder_DrawList_Done
	clc
	adc Brow_Top
	sta Reg6							; Reg6 = list index for this row
	cmp Brow_Count
	bcs Folder_DrawList_Done

	lda Reg6
	ldx #DIRBROW_BANK
	jsr UI_ReadRec

	lda Reg5
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	lda Reg6
	cmp Brow_Index
	beq Folder_DrawList_Hi
	lda #$00
	jmp Folder_DrawList_Put
Folder_DrawList_Hi
	lda #$01
Folder_DrawList_Put
	jsr UI_DrawNameRow
	inc Reg5
	jmp Folder_DrawList_L1
Folder_DrawList_Done
	rts

;-----------------------------------------------------------------------------
; Folder_HiRow - A = list index.  Recolours just that row's 8 name cells via
; the blitter (no glyph redraw), highlighted if index == Brow_Index.  No-op if
; off screen.  Mirrors Selector_HiRow.
;-----------------------------------------------------------------------------
Folder_HiRow
	sta Reg6
	cmp Brow_Top
	bcc Folder_HiRow_Skip
	sec
	sbc Brow_Top
	cmp #UI_VISROWS
	bcs Folder_HiRow_Skip
	clc
	adc #UI_FIRSTROW
	sta Txt_Row
	lda Reg6
	cmp Brow_Count
	bcs Folder_HiRow_Skip
	lda #4
	sta Txt_Col
	lda #7
	sta Reg1
	lda #$00
	sta Reg2
	lda Reg6
	cmp Brow_Index
	beq Folder_HiRow_Hi
	lda #UI_PEN_FG
	jmp Text_FillColour					; tail
Folder_HiRow_Hi
	lda #UI_PEN_HI | $80
	jmp Text_FillColour					; tail
Folder_HiRow_Skip
	rts

;-----------------------------------------------------------------------------
Folder_Keys
	lda CH
	cmp #KEY_DOWN
	bne FolK_1
	jmp Folder_Key_Down
FolK_1
	cmp #KEY_UP
	bne FolK_2
	jmp Folder_Key_Up
FolK_2
	cmp #KEY_RETURN
	bne FolK_3
	jmp Folder_Key_Open
FolK_3
	cmp #KEY_SPACE
	bne FolK_4
	jmp Folder_Key_Commit
FolK_4
	cmp #KEY_ESC
	bne FolK_5
	jmp Folder_Key_Cancel
FolK_5
	cmp #KEY_Q
	bne FolK_None
	jmp Folder_Key_Quit
FolK_None
	jmp Read_Key_Done

Folder_Redraw
	jsr Folder_Draw
	jmp Read_Key_Done

Folder_Key_Down
	lda Brow_Count
	beq Folder_Nav_Done					; empty list
	ldx Brow_Index
	inx
	cpx Brow_Count
	bcs Folder_Nav_Done					; already on the last entry
	lda Brow_Index
	sta Reg3							; Reg3 = old (now un-highlighted) index
	stx Brow_Index
	txa
	sec
	sbc #[UI_VISROWS-1]
	bcc Folder_Key_Down_Rows			; still visible
	cmp Brow_Top
	bcc Folder_Key_Down_Rows
	beq Folder_Key_Down_Rows
	sta Brow_Top						; scrolled -> repaint the list in place
	jsr Folder_DrawList
	jmp Read_Key_Done
Folder_Key_Down_Rows
	lda Reg3
	jsr Folder_HiRow					; un-highlight the row we left
	lda Brow_Index
	jsr Folder_HiRow					; highlight the row we moved to
Folder_Nav_Done
	jmp Read_Key_Done

Folder_Key_Up
	lda Brow_Index
	beq Folder_Nav_Done					; already at the top
	sta Reg3
	sec
	sbc #$01
	sta Brow_Index
	cmp Brow_Top
	bcs Folder_Key_Up_Rows				; still visible
	sta Brow_Top						; scrolled -> repaint the list in place
	jsr Folder_DrawList
	jmp Read_Key_Done
Folder_Key_Up_Rows
	lda Reg3
	jsr Folder_HiRow
	lda Brow_Index
	jsr Folder_HiRow
	jmp Read_Key_Done

Folder_Key_Open
	lda Brow_Count
	beq Folder_Redraw					; nothing to open
	jsr Folder_Open_Selected
	lda #$00
	sta Brow_Index
	sta Brow_Top
	jmp Folder_Redraw

Folder_Key_Commit
	jsr Rescan_Images
	jsr Enter_Selector
	jmp Read_Key_Done

Folder_Key_Cancel
	ldy #$00							; restore the saved path (Folder_Saved_Path)
Folder_Key_Cancel_L1
	lda Folder_Saved_Path,y
	sta Scan_Path,y
	beq Folder_Key_Cancel_Done
	iny
	cpy #$28
	bcc Folder_Key_Cancel_L1
Folder_Key_Cancel_Done
	jsr Enter_Selector
	jmp Read_Key_Done

Folder_Key_Quit
	jmp Exit

;-----------------------------------------------------------------------------
; Folder_Open_Selected - descend into Brow_Index (or pop for ".."), re-scan.
;-----------------------------------------------------------------------------
Folder_Open_Selected
	lda Brow_Index
	jsr Folder_ReadName					; Name_Row_Buf = entry
	lda Name_Row_Buf
	cmp #'.'
	beq Folder_Open_Pop
	jsr Folder_Path_Push
	jmp Folder_Scan
Folder_Open_Pop
	jsr Path_Pop_Segment
	jmp Folder_Scan

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
UI_Str_NoDirs		dta c'(no directories found here)',0
UI_Str_Delay		dta c'Slideshow delay: ',0
UI_Str_DelayHint	dta c's    , shorter    . longer',0
UI_Str_Legend		dta c'Up/Dn move  ENTER view  S slide  D drive  F folder  P pal  A info  Q quit',0
UI_Str_FolderTitle	dta c'Select folder for image scan',0
UI_Str_FolderLegend	dta c'Up/Dn move   ENTER open   SPACE scan here   ESC cancel',0

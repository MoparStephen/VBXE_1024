 ; .loadsym "C:\Users\Stephen\source\Claude\VBXE_1024\Viewer\out\getdir.lab"

;-----------------------------------------------------------------------------
;  HARDWARE EQUATES
;-----------------------------------------------------------------------------
    icl 'equates.asm'

;-----------------------------------------------------------------------------
; Defines go here
;-----------------------------------------------------------------------------
.def	__VBXE_AUTO__
.def	VBXE_WINDOW						= $2000		; MEMAC 4K window

	org $3000

    icl 'fileio_min.asm'					; CIO_dir/CIO_gettext, Find_First_IOCB, PutLine
    icl 'vbxe_min.asm'						; VBXE_Detect, vbsta/vblda, VBXE_MA_BSEL etc.
    icl 'sdx_con.asm'						; SpartaDOS X 40/80-column soft-console control

;-----------------------------------------------------------------------------
;  DIRECTORY SEARCH CONSTANTS
;-----------------------------------------------------------------------------
IMAGE_BANK		equ $40							; Dedicated VBXE bank for the name list
MAX_IMAGES		equ 372							; 32MB partition / ~88KB per image
ImageNames		equ VBXE_WINDOW					; Where the list lives once IMAGE_BANK
												; is mapped in - costs 0 bytes of CPU RAM
ImageNames_End	equ ImageNames + (MAX_IMAGES*8)	; = $2BA0 - $460 spare bytes left in the bank
;-----------------------------------------------------------------------------
; Clean up and exit
;-----------------------------------------------------------------------------
Cleanup_Exit
	jsr SDX_Console_Restore				; Put the SDX soft console back if it was on

	lda #$FF
	sta CH								; Clear last key pressed

	jmp (DOSVEC)						; Return to DOS

;-----------------------------------------------------------------------------
; Main loop
;-----------------------------------------------------------------------------
main
	jsr SDX_Console_Save_And_40			; Force standard 40-col text if SDX soft console is up
	jsr VBXE_Detect						; Sets VBXEBase for vbsta/vblda below
	jsr Build_Image_List				; Search D:*.MAP once and build ImageNames

; All done - now loop forever
Main_Loop
	lda #$00
	sta ATRACT							; Disable Attract Mode

	jsr Wait_For_Sync					; Wait for VSYNC - this calls keyboard handler
	jmp Main_Loop

; Set RUN Vector
	run main

;-----------------------------------------------------------------------------
; END OF CODE
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Subroutines BEGIN
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Handle_Keys
;-----------------------------------------------------------------------------
Handle_Keys
; If present, the next 3 lines will allow a "jump to exit" on a specific key press
	lda CH
	cmp #$2F							; Press Q to quit
	beq Exit
Handle_Keys_Done						; No more keys to test
	jmp Read_Key_Done

Read_Key_Done
	lda #$FF
	sta CH								; Clear last key pressed
	rts									; Else return to caller
Exit
	jmp Cleanup_Exit					; Clean up and exit (accounts for any long branch issues)
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
; Build_Image_List - Opens D:*.MAP via CIO (the wildcard does the searching),
; GETs each directory line, and packs every match into ImageNames - a
; dedicated 4K VBXE bank (IMAGE_BANK) rather than CPU RAM - as an 8-byte,
; space-padded base filename (no drive prefix, no extension). Also echoes
; each raw DIR line to the screen via PutLine.
; No parameters, no return value - ImageCount says how many entries landed.
;-----------------------------------------------------------------------------
Build_Image_List
	lda #$00
	sta ImageCount
	sta ImageCount+1

	jsr Find_First_IOCB					; X = free IOCB offset, Y = status
	cpy #$01
	beq Build_Image_List_Have_IOCB
	rts									; No free IOCB - bail, ImageCount stays 0
Build_Image_List_Have_IOCB
	stx Dir_IOCB

; Open the directory - the wildcard filters to *.MAP for us
	lda #CIO_dir
	sta ICAX1,x
	lda #<Dir_Spec
	sta ICBAL,x
	lda #>Dir_Spec
	sta ICBAH,x
	lda #CIO_open
	sta ICCOM,x
	jsr CIOV
	bmi Build_Image_List_Done			; Open failed - nothing to search, VBXE untouched

; Map IMAGE_BANK in and point the write cursor at the start of it
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
	bcc Build_Image_List_Room			; Hi byte lower - definitely room
	bne Build_Image_List_Echo			; Hi byte higher - definitely full
	lda Name_Ptr
	cmp #<ImageNames_End
	bcs Build_Image_List_Echo			; Same hi byte, lo byte at/past end - full
Build_Image_List_Room
	jsr Parse_Dir_Line					; Writes candidate name at Name_Ptr
	beq Build_Image_List_Echo			; A=0 - not a real filename, don't advance

	inc ImageCount
	bne Build_Image_List_Adv
	inc ImageCount+1
Build_Image_List_Adv
	lda Name_Ptr
	clc
	adc #$08
	sta Name_Ptr
	bcc Build_Image_List_Echo
	inc Name_Ptr+1

Build_Image_List_Echo
	mwa #Dir_Line_Buf TextPtr
	jsr PutLine							; Show the raw DIR line so it's visible it worked
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
; Parse_Dir_Line - pulls the base filename out of one Dir_Line_Buf entry and
; writes it, space-padded to exactly 8 bytes, at Name_Ptr.
; Skips leading spaces/protect-flag ('*'); stops the name at space/'.'/EOL.
; Rejects an all-digit "name" (catches a trailing "nnn FREE SECTORS" line).
; takes:
; Name_Ptr - destination slot (not advanced here - caller does that)
; returns:
; A - $01 if a name was written, $00 if this line had none (slot untouched
;     beyond what was speculatively written, safe to overwrite next call)
;-----------------------------------------------------------------------------
Parse_Dir_Line
	ldx #$00							; X = source index into Dir_Line_Buf
Parse_Skip_L1							; Skip leading spaces / protect flag
	lda Dir_Line_Buf,x
	cmp #$9B
	beq Parse_Dir_Line_Reject			; Hit EOL before any name - nothing here
	cmp #' '
	beq Parse_Skip_Next
	cmp #'*'
	bne Parse_Skip_Done
Parse_Skip_Next
	inx
	cpx #Dir_Line_Len
	bcc Parse_Skip_L1
	bcs Parse_Dir_Line_Reject			; Ran off the end of the buffer - nothing here
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
	bcs Parse_Copy_Next					; Name already full - keep scanning, don't store
	lda Dir_Line_Buf,x
	sta (Name_Ptr),y
	iny
Parse_Copy_Next
	inx
	cpx #Dir_Line_Len
	bcc Parse_Copy_L1

Parse_Copy_Done
	lda Reg1
	beq Parse_Dir_Line_Reject			; All digits - e.g. "nnn FREE SECTORS", reject

Parse_Pad_L1							; Right-pad the rest of the 8-byte slot with
										; spaces, so every entry is a fixed 8 bytes
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
; Directory search data
;-----------------------------------------------------------------------------
Dir_Spec	dta c'D:*.MAP',$9B				; Wildcard - DOS does the filtering
Dir_Line_Len	equ $28						; Max length of one GET RECORD line

.zpvar	Reg1			.byte				; Scratch - "saw a non-digit" flag
.zpvar	Name_Ptr		.word				; Write cursor into ImageNames (VBXE RAM)

.var	Dir_IOCB		.byte				; IOCB offset used for the dir search
.var	ImageCount		.word				; How many ImageNames entries are populated
.var	Dir_Line_Buf	:$28 .byte			; One GET RECORD line (Dir_Line_Len bytes)

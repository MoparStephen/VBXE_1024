.def	NUM_DOTS						= $06
;-----------------------------------------------------------------------------
; Initialization
;-----------------------------------------------------------------------------
; Step $01 - Clear screen and print initial loading screen
	org LOAD_ADDRESS + $300
.proc Step_1
; Save any values that will be changed so they can be restored on exit
	lda DOSINI
	sta DOSINIL_OLD
	lda DOSINI + 1
	sta DOSINIH_OLD						; Save DOSINI so we can restore it later

	lda SDMCTL
	sta SDMCTL_OLD						; Save SDMCTL so we can restore it later

	lda CRSINH
	sta CRSINH_OLD						; Save CRSINH so we can restore it later

	lda LMARGIN
	sta LMARGIN_OLD						; Save LMARGIN so we can restore it later

	lda COLOR2
	sta COLOR2_OLD						; Save COLOR2 so we can restore it later

	tsx									; X now holds the SP
	stx SP_REG_OLD						; Save SP so we can restore it later

	lda SDLSTL
	sta SDLSTL_OLD

	lda SDLSTL+1
	sta SDLSTH_OLD

; Determine and save the Video Format
	lda #$00
	sta Ptr_Lo
Wait1
	lda vcount
	beq Wait1
Wait2
	tay									; Save largest value in Y
	lda vcount
	bne Wait2
; VCount = zero, but we've saved the largest possible in Y
	cpy #$85							; NTSC will never get this high
	bcc NTSC_Detected

PAL_Detected
	lda #$30							; P
	sta Step1_Message + $73
	lda #$21							; A
	sta Step1_Message + $74
	lda #$2C							; L
	sta Step1_Message + $75				; Set text in Row 2 of Step1_Message
	lda #$00
	jmp Check_SDX

NTSC_Detected
	lda #$2E							; N
	sta Step1_Message + $72
	lda #$34							; T
	sta Step1_Message + $73
	lda #$33							; S
	sta Step1_Message + $74
	lda #$23							; C
	sta Step1_Message + $75				; Set text in Row 2 of Step1_Message
	lda #$01

; If SpartaDOS X has its 64/80-column soft console up (CON.SYS / CON64.SYS on a
; base such as S_VBXE.SYS), drop it to the standard 40-column OS editor. The
; original mode is put back by SDX_Console_Restore in Cleanup_Exit.
Check_SDX
	sta Video_Flag						; Save for later

	jsr SDX_Console_Save_And_40

	lda #$00
	sta LMARGIN

	lda #$01
	sta CRSINH

	mwa #Clear_Screen TextPtr
	jsr PutLine							; Cheap way to get a channel open to the screen

	lda #$B0							; Dark Green
	sta COLOR2							; Set playfield
	lda #$BA							; Light Green
	sta COLOR1							; Set text

; Grab the pointer to the top of screen ram
	lda SAVMSC
	sta Ptr_Lo
	lda SAVMSC+1
	sta Ptr_Hi

; Print the initial loading message
; Each subsequent init stage will update it
	ldy #$00
Print_Loading_L1						; Copy the 1st $100 bytes
	lda Step1_Message,y
	sta (Ptr_Lo),y
	dey
	bne Print_Loading_L1

	ldy #$17
	inc Ptr_Hi
Print_Loading_L2						; Copy the last $180 bytes
	lda Step1_Message+$100,y
	sta (Ptr_Lo),y
	dey
	bpl Print_Loading_L2

	dec Ptr_Hi							; Restore to beginning of screen RAM
	lda #$CA
	sta Reg1							; Pointer to screen RAM for progress dots

	; jsr Wait_For_Key_Exit
	rts									; Return controll to loader

Clear_Screen
	.byte $7D,$9B
Step1_Message							; Internal screen codes
	.byte $51,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$45
	.byte $7C,$00,$36,$22,$38,$25,$00,$11,$10,$12,$14,$00,$23,$6F,$6C,$6F,$75,$72,$00,$30,$69,$63,$74,$75,$72,$65,$00,$36,$69,$65,$77,$65,$72,$00,V_0,$0E,V_1,V_2,V_3,$7C
	.byte $7C,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$7C
	.byte $7C,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$7C
	.byte $41,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$44
	.byte $7C,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$7C
	.byte $5A,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$52,$43
.endp
	ini Step_1

; Step $02 - Ensure RAMTOP is = $C0 and no BASIC cart/ROM is present
	org LOAD_ADDRESS + $300
.proc Check_RAMTOP
; Disable BASIC
	lda #$C0							; Check if RAMTOP is already OK
	cmp RAMTOP							; Prevent flickering if BASIC is already off
	beq Ram_Ok

	lda #$01							; Set BASICF for OS
	sta BASICF							; So BASIC remains OFF after RESET

	lda PORTB							; Disable BASIC bit in PORTB for MMU
	ora #$02							; By Setting bit 2
	sta PORTB

	lda $A000							; Check if BASIC ROM area is now RAM
	inc $A000							; This will also catch SDX not launching
	cmp $A000							; The app via X
	beq Ram_Not_Ok						; If not, perform print error and exit

	lda #$0C							; 12 = CLOSE
	jsr Do_CIOV							; Close editor

	lda #$C0
	sta RAMTOP							; Set RAMTOP to end of BASIC
	sta RAMSIZ							; Set RAMSIZ also

	ldx #$00							; Channel #0
	lda #$04							; 4 = OPEN_READ
Do_CIOV
	sta ICCOM							; Store the Command
	lda #<Device_Name
	sta ICBAL							; Use channel #0
	lda #>Device_Name
	sta ICBAH
	jsr CIOV

Ram_Ok
	; jsr Wait_For_Key_Exit
	rts

Ram_Not_Ok								; Add your error handling here, there still is a ROM....
	ldy #$42							; Dark Red
	sty COLOR2							; Set playfield

; Print RAM_Failure_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
RAM_Failure_Message_L1
	lda RAM_Failure_Message_Line1,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$23							; Copy $23 characters
	bne RAM_Failure_Message_L1

; Print RAM_Failure_Message - line 5
	ldy #$D1
	ldx #$00
RAM_Failure_Message_L2
	lda RAM_Failure_Message_Line2,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$15							; Copy $15 characters
	bne RAM_Failure_Message_L2

	jsr Wait_For_Key_Exit

	jmp WARMSV							; Warm Start

Device_Name
	dta c'E:', $00
RAM_Failure_Message_Line1
	.byte $34,$68,$69,$73,$00,$70,$72,$6F,$67,$72,$61,$6D,$00,$72,$65,$71,$75,$69,$72,$65,$73,$00,$61,$74,$00,$6C,$65,$61,$73,$74,$00,$14,$18,$6B,$22
RAM_Failure_Message_Line2
	.byte $30,$72,$65,$73,$73,$00,$61,$6E,$79,$00,$6B,$65,$79,$00,$74,$6F,$00,$65,$78,$69,$74,$80
.endp
	ini Check_RAMTOP

; Step $03 - Detect the VBXE and print address or Quit if not found
	org LOAD_ADDRESS + $300
.proc Detecting_VBXE
	jsr VBXE_Detect						; VBXE core 1.07 and above detection TODO: This is apparently broken, fix it so D700 works (6/23/2026)
	bcc VBXE_Found						; If found skip the code below.  X register contains High Nybble of VBXE address

VBXE_Not_Found
	ldy #$42							; Dark Red
	sty COLOR2							; Set playfield

; Print VBXE_NPresent - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_VBXE_NPresent_L1
	lda VBXE_NPresent,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_VBXE_NPresent_L1

	jsr Wait_For_Key_Exit
	jmp Cleanup_Exit					; Cleanup then return controll to DOS

VBXE_Found
	cpx #$D6							; X register contains High Nybble of VBXE address
	beq VBXE_Found_Done					; VBXE at D6
	inc VBXE_Address+2					; VBXE at D7 so change text!

VBXE_Found_Done
; Print VBXE_Detected - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_VBXE_Detected_L1
	lda VBXE_Detected,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_VBXE_Detected_L1

; Print VBXE address - line 2 (y = $51)
	ldy #$52
	ldx #$01
Print_VBXE_Address_L1
	lda VBXE_Address,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$05							; Copy $04 characters (we are counting from 1 this time)
	bne Print_VBXE_Address_L1

; Update Progress bar - line 5 (y = $CB + (4 * increment #))
	ldy Reg1
	lda #$54							; Screen RAM code for Ctrl+T
	ldx #NUM_DOTS						; Number of dots to write
Progress_Bar_Loop
	sta (Ptr_Lo),y
	iny
	dex
	bne Progress_Bar_Loop
	sty Reg1							; Save pointer for progress bar updates

	; jsr Wait_For_Key_Exit

	rts									; Return controll to loader

VBXE_Detected
	.byte $36,$22,$38,$25,$00,$24,$65,$74,$65,$63,$74,$65,$64,$00,$61,$74,$00	; VBXE Detected at
VBXE_Address
	.byte $04,$24,$16,$14,$10,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00	; $D640
VBXE_NPresent
	.byte $01,$00,$36,$22,$38,$25,$00,$6E,$6F,$74,$00,$66,$6F,$75,$6E,$64,$00,$0D,$00,$61,$6E,$79,$00,$6B,$65,$79,$00,$31,$75,$69,$74,$00,$01,$00	; ! VBXE not found - any key Quit !

.endp
	ini Detecting_VBXE

; Step $04 - Clear VBXE RAM
	org LOAD_ADDRESS + $300
.proc clear_vbxe
; Print Clearing_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_Clearing_Message_L1
	lda Clearing_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_Clearing_Message_L1

; Update Progress bar - line 5 (y = $CB + (4 * increment #))
	ldy Reg1
	lda #$54							; Screen RAM code for Ctrl+T
	ldx #NUM_DOTS						; Number of dots to write
Progress_Bar_Loop
	sta (Ptr_Lo),y
	iny
	dex
	bne Progress_Bar_Loop
	sty Reg1							; Save pointer for progress bar updates

	; jsr Wait_For_Key_Exit

; Set the base address of MEMA window to VBXE_WINDOW
; Size to 4k and accesible only by CPU
	lda #>VBXE_WINDOW + 8
	vbsta VBXE_MA_CTL

	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

	; Copy blit to VBXE memory
	ldx #$14
	mva:rpl blit_clear,x VBXE_WINDOW,x-

	; Kick blit
	lda #$00
	vbsta VBXE_BL_ADR0
	vbsta VBXE_BL_ADR1
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BLITTER_START			; Start the blit

	; Wait for blit complete
	vblda:rne VBXE_BLITTER_BUSY

	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL

	rts									; Return controll to loader

blit_clear
	; clear 496kB (leave bottom 16kB for the SVBXE.SYS driver)
	; 496x16 zoom 8x8 clear blit (this takes 2 frames)

	;	dta e($00000)	; Source address
	;	dta a($0000)	; Source step y
	;	dta 0			; Source step x
	;	dta e($7BFFF)	; Destination address
	;	dta a(-$0F80)	; Destination step y (backwards 3968 bytes) - NOTE: this equals 496 * zoom factor of 8
	;	dta -1			; Destination step x (backwards	1 byte)
	;	dta a($01EF)	; Width-1  (495)	496 * 8 bytes wide
	;	dta $0F			; Height-1 (15)		 16 * 8 bytes high
	;	dta $00			; And mask (And mask equal to 0 so clear)
	;	dta $00			; Xor mask (will be filled with xor mask)
	;	dta $00			; Collision and mask
	;	dta $77			; Zoom (BLT_ZOOMY = 7, BLT_ZOOMX = 7 so 8Y*8X)
	;	dta $00			; Pattern feature
	;	dta $00			; Control (Mode 0 with NEXT bit Cleared)

	dta e($00000), a($0000), 0, e($7BFFF), a(-$0F80), -1, a($01EF), $0F, $00, $00, $00, $77, $00, $00
Clearing_Message
	.byte $23,$6C,$65,$61,$72,$69,$6E,$67,$00,$36,$22,$38,$25,$00,$32,$21,$2D,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00	; Clearing VBXE RAM

.endp
	ini clear_vbxe

; Step $05 - Load the XDL
	org LOAD_ADDRESS + $300
.proc Load_XDL
	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

; Print Load_XDL_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_Load_XDL_Message_L1
	lda Load_XDL_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_Load_XDL_Message_L1

; Update Progress bar - line 5 (y = $CB + (4 * increment #))
	ldy Reg1
	lda #$54							; Screen RAM code for Ctrl+T
	ldx #NUM_DOTS						; Number of dots to write
Progress_Bar_Loop
	sta (Ptr_Lo),y
	iny
	dex
	bne Progress_Bar_Loop
	sty Reg1							; Save pointer for progress bar updates

	; jsr Wait_For_Key_Exit

	rts									; Return controll to loader

Load_XDL_Message
	.byte $2C,$6F,$61,$64,$69,$6E,$67,$00,$38,$24,$2C,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00	; Loading XDLs

.endp
	ini Load_XDL

	org VBXE_WINDOW						; Load data directly into VBXE RAM
XDL_START
	icl 'xdl.asm'
XDL_Length	equ *-XDL_START

; Step $06 - Load the BCBs
	org LOAD_ADDRESS + $300
.proc Load_BCB
	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

; Print Load_BCB_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_Load_BCB_Message_L1
	lda Load_BCB_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_Load_BCB_Message_L1

; Update Progress bar - line 5 (y = $CB + (4 * increment #))
	ldy Reg1
	lda #$54							; Screen RAM code for Ctrl+T
	ldx #NUM_DOTS						; Number of dots to write
Progress_Bar_Loop
	sta (Ptr_Lo),y
	iny
	dex
	bne Progress_Bar_Loop
	sty Reg1							; Save pointer for progress bar updates

	; jsr Wait_For_Key_Exit

	rts									; Return controll to loader

Load_BCB_Message
	.byte $2C,$6F,$61,$64,$69,$6E,$67,$00,$22,$23,$22,$73,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00	; Loading BCBs

.endp
	ini Load_BCB

	org VBXE_WINDOW + $100				; Load data directly into VBXE RAM
BCB_START
	icl 'bcbs.asm'
BLT_Length	equ *-BCB_START

; Step $07 - Load VBXE NTSC Palette so we can restore it on exit
	org LOAD_ADDRESS + $300
.proc Load_Palette1
	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

; Print Load_Palette1_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_Load_Palette1_Message_L1
	lda Load_Palette1_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_Load_Palette1_Message_L1

; Update Progress bar - line 5 (y = $CB + (4 * increment #))
	ldy Reg1
	lda #$54							; Screen RAM code for Ctrl+T
	ldx #NUM_DOTS						; Number of dots to write
Progress_Bar_Loop
	sta (Ptr_Lo),y
	iny
	dex
	bne Progress_Bar_Loop
	sty Reg1							; Save pointer for progress bar updates

	; jsr Wait_For_Key_Exit

	rts									; Return controll to loader

Load_Palette1_Message
	.sb 'Loading vbxe_ntsc.pal            '

.endp
	ini Load_Palette1

	org VBXE_WINDOW + $200				; Load data directly into VBXE RAM
Palette1
	ins 'vbxe_ntsc.pal'

; Step $08 - Load VBXE PAL Palette so we can restore it on exit
	org LOAD_ADDRESS + $300
.proc Load_Palette2
	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

; Print Load_Palette_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_Load_Palette2_Message_L1
	lda Load_Palette2_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_Load_Palette2_Message_L1

; Update Progress bar - line 5 (y = $CB + (4 * increment #))
	ldy Reg1
	lda #$54							; Screen RAM code for Ctrl+T
	ldx #NUM_DOTS						; Number of dots to write
Progress_Bar_Loop
	sta (Ptr_Lo),y
	iny
	dex
	bne Progress_Bar_Loop
	sty Reg1							; Save pointer for progress bar updates

	; jsr Wait_For_Key_Exit

	lda #$FF
	sta CH

	rts									; Return controll to loader

Load_Palette2_Message
	.sb 'Loading vbxe_pal.pal             '

.endp
	ini Load_Palette2

	org VBXE_WINDOW + $500				; Load data directly into VBXE RAM
Palette2
	ins 'vbxe_pal.pal'

; Step $08b - Scan D:*.MAP and build the image name list in VBXE bank IMAGE_BANK
	org LOAD_ADDRESS + $300
.proc Scan_Images
	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

; Print Scan_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_Scan_Message_L1
	lda Scan_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_Scan_Message_L1

	jsr Build_Image_List				; Fills IMAGE_BANK, sets ImageCount

	jsr Sort_Image_List					; (future UI option: alphabetical order)

	lda ImageCount
	ora ImageCount+1
	bne Scan_Images_Done				; At least one image - carry on

; No images: mirror the VBXE-not-found path (still safe here, pre-start)
	ldy #$42							; Dark Red
	sty COLOR2

	ldy #$79
	ldx #$00
Print_No_Images_L1
	lda No_Images_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_No_Images_L1

	jsr Wait_For_Key_Exit
	jmp Cleanup_Exit

Scan_Images_Done
	lda #$FF
	sta CH

	rts									; Return controll to loader

;-----------------------------------------------------------------------------
; Build_Image_List - OPEN D:*.MAP as a directory (the wildcard filters), GET
; each line, and pack every base name as an 8-byte space-padded record into
; IMAGE_BANK (mapped through the $2000 window). ImageCount = entries stored.
; Ported from getdir.asm, minus the per-line screen echo.
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
	lda #<Dir_Spec
	sta ICBAL,x
	lda #>Dir_Spec
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
; write it space-padded to exactly 8 bytes at Name_Ptr. Skips leading spaces
; and the '*' protect flag; stops the name at space/'.'/EOL. Rejects an
; all-digit "name" (the trailing "nnn FREE SECTORS" line).
;  returns A = $01 if a name was written, $00 if not.
; Ported verbatim from getdir.asm (Reg1 is already declared in view1024.asm).
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

Dir_Spec
	dta c'D:*.MAP',$9B					; Wildcard - DOS does the filtering

Scan_Message
	.sb 'Scanning disk for images         '
No_Images_Message
	.sb 'No images found - press any key   '

.endp
	ini Scan_Images

; Step $09 - Print instructions
	org LOAD_ADDRESS + $300
.proc Wait_Start
; Print Load_Palette_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
Wait_Start_L1
	lda Wait_Start_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$26							; Copy $26 characters
	bne Wait_Start_L1

	jsr Wait_For_Key_Exit

	lda #$FF
	sta CH

	rts									; Return controll to loader

Wait_Start_Message
	.sb ' Space/BkSp next/prev image    Q quit '

.endp
	ini Wait_Start

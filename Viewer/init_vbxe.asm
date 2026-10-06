.def	NUM_DOTS						= $04		; 8 stages x 4 = 32 dots, centred in the 38-col box (cols 4-35)
.def	LOAD_DOTS_START					= $CC		; row 5, col 4 - first progress dot
.def	LOAD_MSG_ROW3					= $79		; row 3, col 1 - stage message (33 chars)

; OS state Step_1 / Check_RAMTOP change and the Exit path restores (COLOR2_OLD
; is declared in view1024.asm alongside the other _OLD saves).
.var	RAMTOP_OLD		.byte = $4E2	; Check_RAMTOP forces RAMTOP to $C0; SDX soft console needs its own
.var	COLOR1_OLD		.byte = $4E3	; Step_1 recolours COLOR1 for the loader
.var	COLOR4_OLD		.byte = $4E4	; parity with the racer's exit path

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

	lda COLOR1
	sta COLOR1_OLD						; Step_1 recolours COLOR1 for the loader
	lda COLOR4
	sta COLOR4_OLD						; parity with the racer's exit path

	tsx									; X now holds the SP
	stx SP_REG_OLD						; Save SP so we can restore it later

	lda SDLSTL
	sta SDLSTL_OLD

	lda SDLSTL+1
	sta SDLSTH_OLD

	lda RAMTOP
	sta RAMTOP_OLD						; Check_RAMTOP forces RAMTOP to $C0; the SDX
										;   soft console reserves its own top of RAM

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
	lda #LOAD_DOTS_START
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

; Step $09 - Menu banner palette-demo overlay: assembly-embed the RGB ramps
; for hardware palettes 1-3 directly into MENU_BANNER_PAL_VRAM (bank $34),
; at the same $0300/$0600/$0900 slot offsets Apply_Menu_Palettes
; (view1024.asm) already reads for registers 1/2/3.  Replaces the old
; D:MENU.PAL disk load - same "select bank, then org+ins" idiom as
; Load_Palette1/Load_Palette2 above, so the bytes land straight into VBXE
; RAM as the OS loader streams this .xex in, no runtime copy needed.
	org LOAD_ADDRESS + $300
.proc Load_Menu_Ramps
	lda #(MENU_BANNER_PAL_VRAM / $1000) | MEMAC_GLOBAL_ENABLE	; Bank $34 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

; Print Load_Menu_Ramps_Message - line 3 (y = $79)
	ldy #$79
	ldx #$00
Print_Load_Menu_Ramps_Message_L1
	lda Load_Menu_Ramps_Message,x
	sta (Ptr_Lo),y
	inx
	iny
	cpx #$21							; Copy $21 characters
	bne Print_Load_Menu_Ramps_Message_L1

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

	rts									; Return controll to loader

Load_Menu_Ramps_Message
	.sb 'Loading menu banner ramps        '

.endp
	ini Load_Menu_Ramps

	org VBXE_WINDOW + $300				; -> MENU_BANNER_PAL_VRAM+$0300 (hw palette register 1 slot)
Menu_Ramp_Red
	ins 'Assets/RAMP_RED.PAL'

	org VBXE_WINDOW + $600				; -> MENU_BANNER_PAL_VRAM+$0600 (hw palette register 2 slot)
Menu_Ramp_Green
	ins 'Assets/RAMP_GRN.PAL'

	org VBXE_WINDOW + $900				; -> MENU_BANNER_PAL_VRAM+$0900 (hw palette register 3 slot)
Menu_Ramp_Blue
	ins 'Assets/RAMP_BLU.PAL'

; Step $0A - Menu separator row: assembly-embed the 160-byte pattern table
; (Assets/MENU_SEP.RAW, built by Convertor/make_logo.py --export-sep) directly
; into MENU_SEP_VRAM (bank $33) - same "select bank, then org+ins" idiom as
; Load_Menu_Ramps.  Loaded once here and never written again; all three
; separator rows of XDL_MainMenu point at it.  No message / progress dots -
; this is a tiny load, part of the menu ramps stage.
	org LOAD_ADDRESS + $300
.proc Load_Menu_Sep
	lda #(MENU_SEP_VRAM / $1000) | MEMAC_GLOBAL_ENABLE	; Bank $33 VBXE Window Enabled
	vbsta VBXE_MA_BSEL
	rts
.endp
	ini Load_Menu_Sep

	org VBXE_WINDOW + (MENU_SEP_VRAM & $FFF)	; -> MENU_SEP_VRAM
Menu_Sep_Data
	ins 'Assets/MENU_SEP.RAW'

; The image-list scan (Build_Image_List / Parse_Dir_Line) and the old
; "press a key to start" gate (Wait_Start) used to live here as init steps.
; They moved to ui.asm (main segment): the scan location is now user-selectable
; at runtime, so the scan - and the "no images" case, which is now an ordinary
; state the selector shows - cannot be decided during the loader.

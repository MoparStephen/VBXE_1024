 ; .loadsym "C:\Users\Stephen\source\Claude\VBXE_1024\Viewer\out\view1024.lab"
 
;-----------------------------------------------------------------------------
; Memory Map
;-----------------------------------------------------------------------------
; Load Address = 
; Run Address = 
; VBXE:
;    XDLs            = $00000 - $00020
;    BCBs            = $00100 - $001FF
;    NTSC_Palette    = $00200 - $004FF (Used to restore Palette 0 on program exit)
;    PAL_Palette     = $00500 - $006FF (Used to restore Palette 0 on program exit)
;    VRAM            = $01000 - $13BFF (Video Ram)
;    CRAM_Buffer     = $14000 - $1657F (Compressed palette bytes)
;    CRAM            = $17000 - $205FF (Colour Ram)
;    Palette_Buffers = $21000 - $21FFF (Temp 4kB buffer for loading palettes)

;-----------------------------------------------------------------------------
;  HARDWARE EQUATES
;-----------------------------------------------------------------------------
    icl 'equates.asm'

;-----------------------------------------------------------------------------
; Structure Declarations
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Variables go here
;-----------------------------------------------------------------------------
; Page 0 user data ($80 to $FF with some reserved for OS)
.zpvar Reg1				.byte			; Multi-Use Variables
.zpvar Reg2				.byte			; Multi-Use Variables
.zpvar Reg3				.byte			; Multi-Use Variables
.zpvar Reg4				.byte			; Multi-Use Variables
.zpvar Reg5				.byte			; Multi-Use Variables
.zpvar Reg6				.byte			; Multi-Use Variables
.zpvar Reg7				.byte			; Multi-Use Variables
.zpvar Reg8				.byte			; Multi-Use Variables
.zpvar Ptr_Lo			.byte			; Lo byte of pointer
.zpvar Ptr_Hi			.byte			; Hi byte of pointer

; Non Page-0 Variables
;	$480 to $4FF free
;	$600 to $6FF free
; When using PMG the 1st $300 bytes are always free
.var SDMCTL_OLD			.byte = $480	; Save DMA
.var CRSINH_OLD			.byte = $481	; Save CRSINH (Mouse Pointer)
.var LMARGIN_OLD		.byte = $482	; Save LMARGIN
.var COLOR2_OLD			.byte = $483	; Save COLOR2
.var SP_REG_OLD			.byte = $484	; Save the Stack Pointer
.var SDLSTL_OLD			.byte = $485	; Save the Display List Pointer
.var SDLSTH_OLD			.byte = $486	; Save the Display List Pointer
.var DOSINIL_OLD		.byte = $487	; Save the DOSINI Pointer
.var DOSINIH_OLD		.byte = $488	; Save the DOSINI Pointer
.var Video_Flag			.byte = $489	; PAL = 0, NTSC = 1
.var File_Index			.byte = $48A	; Index into arrays of filenames

;-----------------------------------------------------------------------------
; Defines go here
;-----------------------------------------------------------------------------
.def	__VBXE_AUTO__
.def	VBXE_WINDOW						= $2000
.def	VBXE_WINDOW_SIZE_4k				= $1000
.def	VBXE_WINDOW_SIZE_8k				= $2000
.def	LOAD_ADDRESS					= VBXE_WINDOW + VBXE_WINDOW_SIZE_4k

; BCB field byte offsets
.def	Src_Adr0						= $00
.def	Src_Adr1						= $01
.def	Src_Adr2						= $02
.def	Dest_Adr0						= $06
.def	Dest_Adr1						= $07
.def	Dest_Adr2						= $08
.def	Blt_Ctrl						= $14

; Temp debug stuff
.def	V_0								= $10	; 0 (Screen code used for Version in loading screen)
.def	V_1								= $10	; 0 (Screen code used for Version in loading screen)
.def	V_2								= $19	; 9 (Screen code used for Version in loading screen)
.def	V_3								= $00	; 61=a (Screen code used for Version in loading screen)

;-----------------------------------------------------------------------------
; VBXE Helpers
;-----------------------------------------------------------------------------
	org LOAD_ADDRESS
.pages 3								; DO NOT go past $3300
	icl 'fileio.lib'
	icl 'vbxe_min.asm'					; Use my VBXE_SetPalette2 to load linear palete

;-----------------------------------------------------------------------------
; Clean up and exit
;-----------------------------------------------------------------------------
Cleanup_Exit
	lda #$00
	sta SDMCTL

	jsr Restore_Palette0

	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL
	vbsta VBXE_VIDEO_CONTROL			; Disable XDL

	lda LMARGIN_OLD
	sta LMARGIN							; Restore LMARGIN

	lda DOSINIL_OLD
	sta DOSINI
	lda DOSINIH_OLD
	sta DOSINI + 1						; Restore DOSINI

	lda #$FF
	sta CH								; Clear last key pressed

	lda SDMCTL_OLD
	sta SDMCTL							; Restore SDMCTL

	jmp (DOSVEC)						; Return to DOS

Wait_For_Key_Exit
	lda #$FF
	sta CH								; Clear last key pressed
Wait_For_Key_Exit_L1
	lda CH
	cmp #$FF
	beq Wait_For_Key_Exit_L1			; Wait for Key Press
	rts									; Exit on  Key Press
.endpg

; Multi-stage loader & program initialization code begins here
	icl 'init_vbxe.asm'

	org LOAD_ADDRESS + $300				; Libraries live above

;-----------------------------------------------------------------------------
; Main loop
;-----------------------------------------------------------------------------
start
; Initialization code can go here

	lda #$00							; Setup VBXE for displaying picture data
	vbsta VBXE_XDL_ADR0					; But don't show the overlay just yet!
	vbsta VBXE_XDL_ADR2
	vbsta VBXE_XDL_ADR1

	lda #$00
	sta SDMCTL							; Turn ANTIC DMA off

	lda #%00000011						; XDL,XCOLOR Enabled and transparent color index 0
	vbsta VBXE_VIDEO_CONTROL

	lda #$FF							; Must set priority when using Attribute Map
	vbsta VBXE_P0						; because VBXE defaults PO-P$ to #$00 on power-up

	lda #$00
	sta File_Index						; Start at index 0
	tax
	jsr Load_Image

main
; All done - now loop forever
	lda #$00
	sta ATRACT							; Disable Attract Mode

	jsr Wait_For_Sync					; Wait for VSYNC - this calls keyboard handler
	jmp main

; Set RUN Vector
	run start

;-----------------------------------------------------------------------------
; END OF CODE
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Subroutines BEGIN
;-----------------------------------------------------------------------------
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
; Setup_Cmap1 - Sets byte 4 for all cmap entries via blitter
;-----------------------------------------------------------------------------
Setup_Cmap1
	lda #BLT_SETUP_CMAP_1-BLT_CLEAR
	vbsta VBXE_BL_ADR0					; Setup the blitter for memory fill operation
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
	lda #$00
Setup_Cmap1_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Setup_Cmap1_L1					; Wait for blitter to finish
	lda #$01
	vbsta VBXE_BLITTER_START			; Start the blit
	rts

;-----------------------------------------------------------------------------
; Clear_Screen - Clears a contiguous 128kB block of VBXE RAM
;-----------------------------------------------------------------------------
Clear_Screen
	lda #BLT_CLEAR_SCREEN-BLT_CLEAR
	vbsta VBXE_BL_ADR0					; Setup the blitter for memory fill operation
	lda #$00
	vbsta VBXE_BL_ADR2
	lda #$01
	vbsta VBXE_BL_ADR1
	lda #$00
Clear_Screen_L1
	vblda VBXE_BLITTER_BUSY
	cmp #$00
	bne Clear_Screen_L1					; Wait for blitter to finish
	lda #$01
	vbsta VBXE_BLITTER_START			; Start the blit
	rts

;-----------------------------------------------------------------------------
; Restores VBXE Palette 0 based on NTSC/PAL test
;-----------------------------------------------------------------------------
Restore_Palette0
	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

	lda Video_Flag						; 0 = PAL, 1 = NTSC
	bne Restore_Palette0_Setup_NTSC
Restore_Palette0_Setup_PAL
	lda <(VBXE_WINDOW + $0500)
	sta Y_Register
	lda >(VBXE_WINDOW + $0500)			; PAL_Palette = $00500 - $006FF
	sta Y_Register + $01
	jmp Restore_Palette0_SetPalette

Restore_Palette0_Setup_NTSC
	lda <(VBXE_WINDOW + $0200)
	sta Y_Register
	lda >(VBXE_WINDOW + $0200)			; NTSC_Palette = $00200 - $004FF
	sta Y_Register + $01

Restore_Palette0_SetPalette
	lda #$00							; Set Palette 0
	jsr VBXE_SetPalette2

Restore_Palette0_Done
	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL

	rts

;-----------------------------------------------------------------------------
; Load_Image
; File_Index must be set before calling this!  No range checking is done!
;-----------------------------------------------------------------------------
Load_Image
; Load the Palettes
	lda #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	clc
	lda #<Palettes
	adc File_Index
	sta FileNamePtr
	lda #>Palettes
	adc #$00
	sta FileNamePtr + $01
	lda #$21
	sta BankIndex						; Load Colour Map data under $21000
	jsr LoadData

	lda #$21 | MEMAC_GLOBAL_ENABLE		; Bank $21 VBXE Window Enabled
	vbsta VBXE_MA_BSEL
	lda <(VBXE_WINDOW + $0000)
	sta Y_Register
	lda >(VBXE_WINDOW + $0000)
	sta Y_Register + $01
	lda #$00							; Set Palette 0
	jsr VBXE_SetPalette2

	lda <(VBXE_WINDOW + $0300)
	sta Y_Register
	lda >(VBXE_WINDOW + $0300)
	sta Y_Register + $01
	lda #$01							; Set Palette 1
	jsr VBXE_SetPalette2

	lda <(VBXE_WINDOW + $0600)
	sta Y_Register
	lda >(VBXE_WINDOW + $0600)
	sta Y_Register + $01
	lda #$02							; Set Palette 2
	jsr VBXE_SetPalette2

	lda <(VBXE_WINDOW + $0900)
	sta Y_Register
	lda >(VBXE_WINDOW + $0900)
	sta Y_Register + $01
	lda #$03							; Set Palette 3
	jsr VBXE_SetPalette2

; Load the Attribute Colour Map
	lda #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	clc
	lda #<Colour
	adc File_Index
	sta FileNamePtr
	lda #>Colour
	adc #$00
	sta FileNamePtr + $01
	lda #$14
	sta BankIndex						; Load Colour Map data under $14000
	jsr LoadData

	jsr Setup_Cmap1						; Expand the data out to $17000

; Load the Image
	lda #MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL
	clc
	lda #<Image
	adc File_Index
	sta FileNamePtr
	lda #>Image
	adc #$00
	sta FileNamePtr + $01
	lda #$01
	sta BankIndex						; Load Colour Map data under $01000
	jsr LoadData
	
Load_Image_Done
	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL

	rts

;-----------------------------------------------------------------------------
; Handle_Keys
;-----------------------------------------------------------------------------
Handle_Keys
; If present, the next 3 lines will allow a "jump to exit" on a specific key press
	lda CH
	cmp #$2F							; Press Q to quit
	beq Exit
	cmp #$21							; Space
	beq Handle_Space
	cmp #$32							; 0
	beq Handle_0
	cmp #$1F							; 1
	beq Handle_1
	cmp #$1E							; 2
	beq Handle_2
	cmp #$1A							; 3
	beq Handle_3
	cmp #$18							; 4
	beq Handle_4
Handle_Keys_Done						; No more keys to test
	jmp Read_Key_Done

Handle_Space
	jsr Clear_Screen					; Clear the VBXE RAM
	jsr Increment_Image					; Display the next image
	jmp Read_Key_Done

Handle_0
	ldx #$00
	jsr Set_Palette						; Disable Colour Map and set Palette to X register
	jmp Read_Key_Done

Handle_1
	ldx #$01
	jsr Set_Palette						; Disable Colour Map and set Palette to X register
	jmp Read_Key_Done

Handle_2
	ldx #$02
	jsr Set_Palette						; Disable Colour Map and set Palette to X register
	jmp Read_Key_Done

Handle_3
	ldx #$03
	jsr Set_Palette						; Disable Colour Map and set Palette to X register
	jmp Read_Key_Done

Handle_4
	jsr Enable_Colour_Map				; Enable Colour Map
	jmp Read_Key_Done

Read_Key_Done
	lda #$FF
	sta CH								; Clear last key pressed
	rts									; Else return to caller
Exit
	jmp Cleanup_Exit					; Clean up and exit (accounts for any long branch issues)

;-----------------------------------------------------------------------------
; Increment_Image
;-----------------------------------------------------------------------------
Increment_Image
	clc
	lda File_Index
	adc #$10
	cmp #$B0							; Past index C
	bcc Increment_Image_Valid
	lda #$00							; Wrap to index 0
Increment_Image_Valid
	sta File_Index
	tax
	jsr Load_Image
	rts

;-----------------------------------------------------------------------------
; Set_Palette
;  X register contains Palette #
;  XDL_Normal + $08 = the byte we need to change
;  XDL OV PALETTE bits 5,4 need changed (00 to 11), bit 0 always needs on
;-----------------------------------------------------------------------------
Set_Palette
	jsr Disable_Colour_Map

	lda #$00 | MEMAC_GLOBAL_ENABLE		; Bank $00 VBXE Window Enabled
	vbsta VBXE_MA_BSEL

	txa									; A contains Palette #
	asl
	asl
	asl
	asl									; Put low-nybble in high-nybble
	ora #$01							; Set bit 0
	sta VBXE_WINDOW + $1D

	lda #MEMAC_GLOBAL_DISABLE			; USE CPU address space
	vbsta VBXE_MA_BSEL

	rts

;-----------------------------------------------------------------------------
; Disable_Colour_Map (Point XDL to XDL_Normal)
;-----------------------------------------------------------------------------
Disable_Colour_Map
	lda #$00							; Setup VBXE for displaying picture data
	vbsta VBXE_XDL_ADR2
	vbsta VBXE_XDL_ADR1
	lda #$15
	vbsta VBXE_XDL_ADR0

	rts

;-----------------------------------------------------------------------------
; Enable_Colour_Map (Point XDL to XDL_Attribute)
;-----------------------------------------------------------------------------
Enable_Colour_Map
	lda #$00							; Setup VBXE for displaying picture data
	vbsta VBXE_XDL_ADR0
	vbsta VBXE_XDL_ADR2
	vbsta VBXE_XDL_ADR1

	rts

;-----------------------------------------------------------------------------
; Subroutines END
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Data Tables go here
;-----------------------------------------------------------------------------
Palettes								; Each entry must be $10 bytes!
	dta c'D2:IMG1.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMG2.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMG3.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMG4.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMG5.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMG6.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMG7.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMG8.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMG9.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMGA.PAL',$00,$00,$00,$00,$00
	dta c'D2:IMGB.PAL',$00,$00,$00,$00,$00
Colour									; Each entry must be $10 bytes!
	dta c'D2:IMG1.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMG2.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMG3.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMG4.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMG5.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMG6.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMG7.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMG8.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMG9.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMGA.MAP',$00,$00,$00,$00,$00
	dta c'D2:IMGB.MAP',$00,$00,$00,$00,$00
Image									; Each entry must be $10 bytes!
	dta c'D2:IMG1.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMG2.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMG3.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMG4.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMG5.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMG6.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMG7.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMG8.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMG9.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMGA.RAW',$00,$00,$00,$00,$00
	dta c'D2:IMGB.RAW',$00,$00,$00,$00,$00
	
;-----------------------------------------------------------------------------
; 
;-----------------------------------------------------------------------------
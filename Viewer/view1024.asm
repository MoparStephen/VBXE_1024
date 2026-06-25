 ; .loadsym "C:\Users\Stephen\source\Claude\VBXE_1024\Viewer\out\view1024.lab"
 
;-----------------------------------------------------------------------------
; Memory Map
;-----------------------------------------------------------------------------
; Load Address = 
; Run Address = 
; VBXE:
;    XDL           = $00000 - $00014
;    BCBs          = $00100 - $001FF
;    NTSC_Palette  = $00200 - $004FF (Used to restore Palette 0 on program exit)
;    PAL_Palette   = $00500 - $006FF (Used to restore Palette 0 on program exit)
;    VRAM          = $01000 - $13BFF (Video Ram)
;    CRAM_Buffer   = $14000 - $1657F (Compressed palette bytes)
;    CRAM          = $17000 - $205FF (Colour Ram)

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
.def	V_2								= $13	; 3 (Screen code used for Version in loading screen)
.def	V_3								= $00	; 61=a (Screen code used for Version in loading screen)

;-----------------------------------------------------------------------------
; VBXE Helpers
;-----------------------------------------------------------------------------
	org LOAD_ADDRESS
.pages 3								; DO NOT go past $3300
	icl	'fileio.lib'
	icl	'vbxe_min.asm'					; Use my VBXE_SetPalette2 to load linear palete

;-----------------------------------------------------------------------------
; Clean up and exit
;-----------------------------------------------------------------------------
Cleanup_Exit
	lda #$00
	sta SDMCTL

	jsr Restore_Palette0

	lda	#MEMAC_GLOBAL_DISABLE			; USE CPU address space
	sta VBXE_MA_BSEL
	sta VBXE_VIDEO_CONTROL				; Disable XDL

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

	jmp	(DOSVEC)						; Return to DOS

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

	lda	#0								; Setup VBXE for displaying picture data
	sta	VBXE_XDL_ADR0					; But don't show the overlay just yet!
	sta	VBXE_XDL_ADR2
	sta	VBXE_XDL_ADR1

	lda	#$00
	;sta SDMCTL							; Turn ANTIC DMA off

	lda	#%00000011						; XDL,XCOLOR Enabled and transparent color index 0
	sta	VBXE_VIDEO_CONTROL
	jsr Wait_For_Sync

; Load the Attribute Colour Map
	lda	#MEMAC_GLOBAL_ENABLE
	sta	VBXE_MA_BSEL
	mwa	#Colour FileNamePtr
	lda	#$14
	sta	BankIndex						; Load Colour Map data under $14000
	jsr	LoadData

	jsr Setup_Cmap1						; Expand the data out to $17000

; Load the Image
	lda	#MEMAC_GLOBAL_ENABLE
	sta	VBXE_MA_BSEL
	mwa	#Image FileNamePtr
	lda	#$01
	sta	BankIndex						; Load Colour Map data under $01000
	jsr	LoadData

main
; All done - now loop forever
	lda #$00
	sta ATRACT							; Disable Attract Mode

	jsr Wait_For_Sync					; Wait for VSYNC, Q quits
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
	bit	VCOUNT
	bmi *-3
	bit	VCOUNT
	bpl *-3
; If present, the next 3 lines will allow a "jump to exit" on a specific key press
	lda CH
	cmp #$2F							; Press Q to quit
	beq	Exit
	rts									; Else return to caller
Exit
	jmp	Cleanup_Exit					; Clean up and exit (accounts for any long branch issues)

;-----------------------------------------------------------------------------
; Setup_Cmap1 - Sets byte 4 for all cmap entries via blitter
;-----------------------------------------------------------------------------
Setup_Cmap1
	lda	#BLT_SETUP_CMAP_1-BLT_CLEAR
	sta	VBXE_BL_ADR0					; Setup the blitter for memory fill operation
	lda	#0
	sta	VBXE_BL_ADR2					; See the description of BCB at the end of this
	lda	#$01							; Source
	sta	VBXE_BL_ADR1
	lda	#0
Setup_Cmap1_L1
	lda	VBXE_BLITTER_BUSY
	cmp	#0
	bne	Setup_Cmap1_L1					; Wait for blitter to finish
	lda	#1
	sta	VBXE_BLITTER_START				; Start the blit
	rts

;-----------------------------------------------------------------------------
; Restores VBXE Palette 0 based on NTSC/PAL test
;-----------------------------------------------------------------------------
Restore_Palette0

	rts

;-----------------------------------------------------------------------------
; Subroutines END
;-----------------------------------------------------------------------------

;-----------------------------------------------------------------------------
; Data Tables go here
;-----------------------------------------------------------------------------
Colour
	dta c'D2:ATTRIB.MAP'
Image
	dta c'D2:IMAGE.RAW'
	
;-----------------------------------------------------------------------------
; 
;-----------------------------------------------------------------------------
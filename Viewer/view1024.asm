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
;    Image name list = $40000 - $40FFF (bank $40: up to MAX_IMAGES=255 base
;                      names, 8 bytes each, built at startup by Scan_Images)
;
; MAX_IMAGES is a hard design ceiling of 255 - each image is a ~90kB
; .PAL/.MAP/.RAW set, so 255 far exceeds any real slideshow, and a one-byte
; count keeps every nav/sort loop small. Not intended to ever be raised.

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
.zpvar Name_Ptr			.word			; Scan write-cursor / Build_Filename source ptr
.zpvar Sort_Ptr			.word			; Sort_Image_List 2nd record ptr

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
.var File_Index			.byte = $48A	; 0-based image ordinal (0 .. ImageCount-1)
.var ImageCount			.word = $48B	; Images found by Scan_Images (hi byte always 0)
.var Path_Buf			:16 .byte = $48D	; Built "D:NAME.EXT",$00 for LoadData ($48D-$49C)
.var Dir_IOCB			.byte = $49D	; IOCB used by Build_Image_List (init only)
.var Dir_Line_Buf		:$28 .byte = $600	; One GET RECORD dir line, init only ($600-$627)

;-----------------------------------------------------------------------------
; Defines go here
;-----------------------------------------------------------------------------
.def	__VBXE_AUTO__
.def	VBXE_WINDOW						= $2000
.def	VBXE_WINDOW_SIZE_4k				= $1000
.def	VBXE_WINDOW_SIZE_8k				= $2000
.def	LOAD_ADDRESS					= VBXE_WINDOW + VBXE_WINDOW_SIZE_4k

; Image name list (built at startup by Scan_Images - see init_vbxe.asm)
.def	IMAGE_BANK						= $40	; VBXE bank holding the name list
.def	MAX_IMAGES						= 255	; Hard ceiling - see Memory Map note
.def	ImageNames						= VBXE_WINDOW	; List base once IMAGE_BANK is mapped
.def	ImageNames_End					= ImageNames + (MAX_IMAGES * 8)
.def	Dir_Line_Len					= $28	; Max length of one dir GET RECORD line

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
.def	V_1								= $11	; 1 (Screen code used for Version in loading screen)
.def	V_2								= $10	; 0 (Screen code used for Version in loading screen)
.def	V_3								= $61	; 61=a (Screen code used for Version in loading screen)

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

	jsr SDX_Console_Restore				; Re-enable the SDX soft console if it was up at startup

	jmp (DOSVEC)						; Return to DOS

Wait_For_Key_Exit
	lda #$FF
	sta CH								; Clear last key pressed
Wait_For_Key_Exit_L1
	lda CH
	cmp #$FF
	beq Wait_For_Key_Exit_L1			; Wait for Key Press
	rts									; Exit on  Key Press

;-----------------------------------------------------------------------------
; Restores VBXE Palette 0 based on NTSC/PAL test.
; MUST stay in this resident block: Cleanup_Exit calls it, and Cleanup_Exit is
; reached from the init-time abort paths (no images / VBXE not found) while the
; main segment is not yet loaded.
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

; SpartaDOS X 40/80-column soft-console control (lives in the always-resident
; page-3 block so Step_1's ini-time call resolves to loaded code)
	icl 'sdx_con.asm'
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
; Load_Image
; File_Index must be set before calling this!  No range checking is done!
;-----------------------------------------------------------------------------
Load_Image
; Load the Palettes (D:<name>.PAL -> VBXE $21000)
	lda #$00							; ext 0 = .PAL
	jsr Build_Filename
	lda #$21
	sta BankIndex						; Load palette data under $21000
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

; Load the Attribute Colour Map (D:<name>.MAP -> VBXE $14000)
	lda #$01							; ext 1 = .MAP
	jsr Build_Filename
	lda #$14
	sta BankIndex						; Load Colour Map data under $14000
	jsr LoadData

	jsr Setup_Cmap1						; Expand the data out to $17000

; Load the Image (D:<name>.RAW -> VBXE $01000)
	lda #$02							; ext 2 = .RAW
	jsr Build_Filename
	lda #$01
	sta BankIndex						; Load raw image data under $01000
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
	cmp #$21							; Space - next image
	beq Handle_Space
	cmp #$34							; Backspace - previous image
	beq Handle_Backspace
	cmp #$1C							; Esc - return to viewer UI (stub)
	beq Handle_Escape
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

Handle_Backspace
	jsr Clear_Screen					; Clear the VBXE RAM
	jsr Decrement_Image					; Display the previous image
	jmp Read_Key_Done

Handle_Escape
; TODO: enter the viewer UI once it exists - stubbed to a no-op for now
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
; Increment_Image - advance File_Index, wrapping past the last image to 0.
; ImageCount fits one byte (MAX_IMAGES = 255), so the low byte is all we test.
;-----------------------------------------------------------------------------
Increment_Image
	ldx File_Index
	inx
	cpx ImageCount
	bcc Increment_Image_Valid
	ldx #$00							; Wrap to the first image
Increment_Image_Valid
	stx File_Index
	jsr Load_Image
	rts

;-----------------------------------------------------------------------------
; Decrement_Image - step File_Index back, wrapping from 0 to the last image.
;-----------------------------------------------------------------------------
Decrement_Image
	ldx File_Index
	bne Decrement_Image_Valid
	ldx ImageCount						; Wrap: 0 -> ImageCount, then dex below
Decrement_Image_Valid
	dex
	stx File_Index
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
; Build_Filename
;  In:  A          = 0 -> .PAL, 1 -> .MAP, 2 -> .RAW
;       File_Index = image ordinal
;  Out: FileNamePtr -> Path_Buf holding  "D:" + base(<=8) + "." + ext + $00
;       IMAGE_BANK unmapped (MEMAC_GLOBAL_DISABLE) on return
;  The base name is the space-padded 8-byte record Scan_Images stored in
;  IMAGE_BANK; copying stops at the first space.
;-----------------------------------------------------------------------------
Build_Filename
	sta Reg2							; Reg2 = extension selector

; Name_Ptr = ImageNames + File_Index * 8   (16-bit; File_Index up to 254)
	lda File_Index
	sta Reg3
	lda #$00
	sta Reg4
	asl Reg3
	rol Reg4
	asl Reg3
	rol Reg4
	asl Reg3
	rol Reg4							; Reg3/Reg4 = File_Index * 8
	lda Reg3
	clc
	adc #<ImageNames
	sta Name_Ptr
	lda Reg4
	adc #>ImageNames
	sta Name_Ptr + $01

	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL					; Map the name list into the $2000 window

	lda #'D'
	sta Path_Buf
	lda #':'
	sta Path_Buf + $01

	ldx #$02							; X = write index into Path_Buf
	ldy #$00							; Y = read index into the 8-byte record
Build_Filename_Base
	lda (Name_Ptr),y
	cmp #' '
	beq Build_Filename_Ext				; Space -> end of base name
	sta Path_Buf,x
	inx
	iny
	cpy #$08
	bcc Build_Filename_Base

Build_Filename_Ext
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL					; Give the CPU back the $2000 window

	lda #'.'
	sta Path_Buf,x
	inx

	lda Reg2							; ext selector * 3
	sta Reg3
	asl Reg3
	clc
	adc Reg3							; A = selector * 3
	tay
	lda Ext_Table,y
	sta Path_Buf,x
	inx
	lda Ext_Table + $01,y
	sta Path_Buf,x
	inx
	lda Ext_Table + $02,y
	sta Path_Buf,x
	inx
	lda #$00
	sta Path_Buf,x						; Terminator for CIO OPEN

	lda #<Path_Buf
	sta FileNamePtr
	lda #>Path_Buf
	sta FileNamePtr + $01
	rts

Ext_Table
	dta c'PALMAPRAW'

;-----------------------------------------------------------------------------
; Sort_Image_List - in-place alphabetical (lexicographic) selection sort of
; the ImageCount 8-byte space-padded records in IMAGE_BANK.
; NOT CALLED YET - hook is the commented "jsr Sort_Image_List" in Scan_Images
; (init_vbxe.asm). Resident and self-contained so a future viewer UI can also
; call it at runtime. O(n^2) byte compares; trivial at MAX_IMAGES = 255.
; Clobbers A/X/Y, Reg2..Reg8, Name_Ptr, Sort_Ptr, Path_Buf[0..7].
;-----------------------------------------------------------------------------
Sort_Image_List
	lda ImageCount
	cmp #$02
	bcc Sort_Image_List_Done			; 0 or 1 records -> nothing to do
	sta Reg5							; Reg5 = n
	sec
	sbc #$01
	sta Reg6							; Reg6 = n-1 (outer limit)

	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL

	lda #$00
	sta Reg2							; i = 0
Sort_Outer
	lda Reg2
	cmp Reg6
	bcs Sort_Image_List_Unmap			; i >= n-1 -> done

	sta Reg4							; m = i
	jsr Sort_SetNamePtr					; Name_Ptr = rec(m)

	lda Reg2
	clc
	adc #$01
	sta Reg3							; j = i + 1
Sort_Inner
	lda Reg3
	cmp Reg5
	bcs Sort_Inner_Done					; j >= n

	lda Reg3
	jsr Sort_SetSortPtr					; Sort_Ptr = rec(j)
	jsr Cmp_Records						; rec(m) : rec(j)
	bcc Sort_Inner_Next					; rec(m) < rec(j) -> keep m
	beq Sort_Inner_Next					; equal          -> keep m
	lda Reg3							; rec(m) > rec(j) -> new min is j
	sta Reg4
	lda Sort_Ptr
	sta Name_Ptr
	lda Sort_Ptr + $01
	sta Name_Ptr + $01
Sort_Inner_Next
	inc Reg3
	jmp Sort_Inner
Sort_Inner_Done
	lda Reg4
	cmp Reg2
	beq Sort_Outer_Next					; min already in place
	lda Reg2
	jsr Sort_SetSortPtr					; Sort_Ptr = rec(i)
	lda Reg4
	jsr Sort_SetNamePtr					; Name_Ptr = rec(m)
	jsr Swap_Records
Sort_Outer_Next
	inc Reg2
	jmp Sort_Outer

Sort_Image_List_Unmap
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
Sort_Image_List_Done
	rts

;-----------------------------------------------------------------------------
; Cmp_Records - lexicographic compare of the 8 bytes at (Name_Ptr) vs
; (Sort_Ptr). Returns C=0 if (Name_Ptr) < (Sort_Ptr); C=1 (and Z=1 when fully
; equal) otherwise.
;-----------------------------------------------------------------------------
Cmp_Records
	ldy #$00
Cmp_Records_L1
	lda (Name_Ptr),y
	cmp (Sort_Ptr),y
	bne Cmp_Records_Done					; C/Z set from the mismatching byte
	iny
	cpy #$08
	bcc Cmp_Records_L1					; all 8 equal -> falls out with C=1,Z=1
Cmp_Records_Done
	rts

;-----------------------------------------------------------------------------
; Swap_Records - exchange the 8-byte records at (Name_Ptr) and (Sort_Ptr),
; using Path_Buf as scratch.
;-----------------------------------------------------------------------------
Swap_Records
	ldy #$00
Swap_Records_L1
	lda (Name_Ptr),y
	sta Path_Buf,y
	lda (Sort_Ptr),y
	sta (Name_Ptr),y
	lda Path_Buf,y
	sta (Sort_Ptr),y
	iny
	cpy #$08
	bcc Swap_Records_L1
	rts

;-----------------------------------------------------------------------------
; Sort_SetNamePtr / Sort_SetSortPtr - A = record index -> set the zp pointer
; to ImageNames + index*8. Sort_IndexToOffset does the 16-bit math in Reg7/Reg8.
;-----------------------------------------------------------------------------
Sort_SetNamePtr
	jsr Sort_IndexToOffset
	lda Reg7
	sta Name_Ptr
	lda Reg8
	sta Name_Ptr + $01
	rts

Sort_SetSortPtr
	jsr Sort_IndexToOffset
	lda Reg7
	sta Sort_Ptr
	lda Reg8
	sta Sort_Ptr + $01
	rts

Sort_IndexToOffset
	sta Reg7
	lda #$00
	sta Reg8
	asl Reg7
	rol Reg8
	asl Reg7
	rol Reg8
	asl Reg7
	rol Reg8							; Reg7/Reg8 = index * 8
	lda Reg7
	clc
	adc #<ImageNames
	sta Reg7
	lda Reg8
	adc #>ImageNames
	sta Reg8
	rts

;-----------------------------------------------------------------------------
;
;-----------------------------------------------------------------------------
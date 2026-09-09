 ; .loadsym "C:\Users\Stephen\source\Claude\VBXE_1024\Viewer\out\view1024.lab"
 
;-----------------------------------------------------------------------------
; Memory Map
;-----------------------------------------------------------------------------
; Load Address = 
; Run Address = 
; VBXE:
;    XDLs            = $00000 - $0002D (image attribute + image normal + text)
;    BCBs            = $00100 - $001FF
;    NTSC_Palette    = $00200 - $004FF (256 RGB triplets; restores Palette 0 on exit)
;    PAL_Palette     = $00500 - $007FF (256 RGB triplets; restores Palette 0 on exit)
;    Text pal buffer = $00800 - $00AFF (UI_Apply_TextPalette de-interleave scratch)
;    VRAM            = $01000 - $13BFF (Video Ram)
;    CRAM_Buffer     = $14000 - $1657F (Compressed palette bytes)
;    CRAM            = $17000 - $205FF (Colour Ram)
;    Palette_Buffers = $21000 - $21FFF (Temp 4kB buffer for loading palettes)
;    Text fonts      = $22000 - $22FFF (CGA.F08 @ $22000 / ATARI.F08 @ $22800;
;                      F toggles XDL_Text CHBASE between them - see text80.asm)
;    Text screen RAM = $23000 - $242BF (80x30 {glyph,attr} cells)
;    .nfo raw text   = $25000 - $26FFF (bank $25/$26: verbatim .NFO file bytes)
;    Mono text page  = $27000 - $2EFFF (banks $27-$2E: reformatted mono glyphs,
;                      MONO_PAGE_STRIDE bytes/row - .nfo body + list bodies,
;                      blitted to the text screen by Text_BlitMonoPage)
;    Text win save   = $2F000 - $2FFFF (WIN_SAVE_VRAM: save-under for the D window)
;    Image name list = $40000 - $40FFF (bank $40: up to MAX_IMAGES=255 rows -
;                      "..", sub-dirs and *.MAP files, 8 bytes each; + a 10-char
;                      display field is formatted in place at draw time)
;    (bank $41 is free - the old folder browser used it)
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
.zpvar Sort_Ptr			.word			; Sort_Range 2nd record ptr

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
.var ImageCount			.word = $48B	; Images found by Rescan_Images (hi byte always 0)
.var Path_Buf			:56 .byte = $48D	; Built "D[n]:PATH>NAME.EXT",$00 for LoadData ($48D-$4C4)
.var Dir_IOCB			.byte = $4C5	; IOCB used by Build_Image_List
; --- viewer UI state (ui.asm) ---
.var UI_Mode			.byte = $4C6	; 0 selector / 1 image / 2 slideshow / 3 drive picker / 4 info
.var Sel_Index			.byte = $4C7	; highlighted list entry (0-based)
.var Sel_Top			.byte = $4C8	; list index of the first visible row (scroll)
.var Slide_Secs			.byte = $4C9	; slideshow delay, seconds (1..30)
.var Slide_FrameCtr		.word = $4CA	; slideshow countdown, frames
.var Scan_Drive			.byte = $4CC	; '1'..'8', or $00 for a bare "D:"
.var Name_Row_Buf		:12 .byte = $4CD	; one name record / formatted row, NUL-terminated
.var Dir_Count			.byte = $4D9	; selector list: number of sub-directory rows
.var FileStart			.byte = $4DA	; selector list: index of the first *.MAP row (= upCount + Dir_Count)
.var Drive_Pick_Index	.byte = $4DB	; drive picker (UI_Mode 3): 0 = "D:", 1..8 = "Dn:"
.var Nfo_Top			.word = $4DC	; info viewer: first visible line (0-based)
.var Nfo_LineCount		.word = $4DE	; info viewer: total lines in the loaded .nfo
.var Font_Sel			.byte = $4E0	; text font: 0 = CGA ($44), 1 = Atari ($45)
;	$4E1 to $4FF free
.var Dir_Line_Buf		:$28 .byte = $600	; One GET RECORD dir line ($600-$627)
.var Scan_Path			:$28 .byte = $628	; subdirectory part, ">DIR>DIR>" or empty ($628-$64F)
.var Scan_Spec			:$30 .byte = $650	; assembled "D[n]:PATH*.MAP",$9B ($650-$67F)
.var Txt_Line			:$30 .byte = $680	; scratch line assembled for Text_PutStrAt ($680-$6AF)
;	$6B7 to $6FF free (text80.asm uses $6B0-$6B6)
; Info viewer (.nfo) line buffer + walk pointers.  Overlays Scan_Spec+Txt_Line
; ($650-$6AF): both are idle whenever UI_Mode = 4, and Selector_Draw rebuilds
; Txt_Line / the next scan rebuilds Scan_Spec on the way out.
.var NfoLineBuf			:81 .byte = $650	; one .nfo line, NUL-terminated, for Text_PutStrAt ($650-$6A0)
.var Nfo_WalkLo			.byte = $6A1	; .nfo window walk pointer, low
.var Nfo_WalkHi			.byte = $6A2	; .nfo window walk pointer, high
.var Nfo_WalkBank		.byte = $6A3	; .nfo VBXE bank currently mapped ($25 or $26)

;-----------------------------------------------------------------------------
; Defines go here
;-----------------------------------------------------------------------------
.def	__VBXE_AUTO__
.def	VBXE_WINDOW						= $2000
.def	VBXE_WINDOW_SIZE_4k				= $1000
.def	VBXE_WINDOW_SIZE_8k				= $2000
.def	LOAD_ADDRESS					= VBXE_WINDOW + VBXE_WINDOW_SIZE_4k

; Image name list (built by Rescan_Images - see ui.asm)
.def	IMAGE_BANK						= $40	; VBXE bank holding the name list
.def	MAX_IMAGES						= 255	; Hard ceiling - see Memory Map note
.def	ImageNames						= VBXE_WINDOW	; List base once IMAGE_BANK is mapped
.def	ImageNames_End					= ImageNames + (MAX_IMAGES * 8)
.def	Dir_Line_Len					= $28	; Max length of one dir GET RECORD line

; VBXE text screen (text80.asm + XDL_Text in xdl.asm - these MUST agree).
; Chosen clear of the image framebuffer/CRAM ($01000-$205FF), palette buffer
; ($21000), the name list ($40000) and the dir browser ($41000).
.def	TEXT_FONT_VRAM					= $22000	; CGA.F08 (2048 bytes) lands here
.def	TEXT_FONT_BANK					= TEXT_FONT_VRAM / $1000	; = $22  (LoadData target bank)
.def	TEXT_CHBASE						= TEXT_FONT_VRAM / $800	; = $44  (XDL_Text CHBASE byte, CGA - boot default)
.def	TEXT_FONT2_VRAM					= TEXT_FONT_VRAM + $800	; $22800 - Atari font (2nd 2K slot in bank $22)
.def	TEXT_CHBASE2					= TEXT_FONT2_VRAM / $800	; = $45  (XDL_Text CHBASE byte, Atari)
.def	TEXT_SCREEN_VRAM				= $23000	; 80x30 {glyph,attr} cells = 4800 bytes
.def	TEXT_SCREEN_BANK				= TEXT_SCREEN_VRAM / $1000	; = $23  (first bank of screen RAM)
.def	TEXT_COLS						= 80
.def	TEXT_ROWS						= 30
.def	TEXT_PITCH						= TEXT_COLS * 2	; $A0 = 160  (XDL_Text OVSTEP)
.def	TEXT_SCREEN_BYTES				= TEXT_ROWS * TEXT_PITCH	; $12C0 = 4800

; Off-screen mono text page: one glyph byte per column, fixed stride.  Filled by
; Info_Format_Page (.nfo) / the list draw (selector, folder) and blitted to the
; text screen by Text_BlitMonoPage (BLT_DRAW_TEXT_MONO).  Stride $80 divides 4K
; so no row ever straddles a VBXE bank - the CPU row-writer never has to split.
.def	MONO_PAGE_VRAM					= $27000	; 8 banks ($27000-$2EFFF), above the .nfo raw banks
.def	MONO_PAGE_BANK					= MONO_PAGE_VRAM / $1000	; = $27
.def	MONO_PAGE_STRIDE				= $80		; 128 bytes/row (32 rows per 4K bank)

; Save-under text window (Text_Window_Save/Restore/Frame in text80.asm).  The
; covered {glyph,attr} rectangle is blit-copied here at screen pitch (160) and
; blitted back on close.  $2F000 is the first free 4K above the mono page.
.def	WIN_SAVE_VRAM					= $2F000
; Drive picker (UI_Mode 3) geometry - a small overlay of "D:" + "D1:".."D8:".
.def	DRIVE_WIN_ROW					= 6
.def	DRIVE_WIN_COL					= 30
.def	DRIVE_WIN_W						= 12		; cells wide  (border + "  Dn:  ")
.def	DRIVE_WIN_H						= 13		; rows        (border + title + 9 + border)

; BCB field byte offsets
.def	Src_Adr0						= $00
.def	Src_Adr1						= $01
.def	Src_Adr2						= $02
.def	Dest_Adr0						= $06
.def	Dest_Adr1						= $07
.def	Dest_Adr2						= $08
.def	Blt_W0							= $0C	; Width-1  low byte
.def	Blt_W1							= $0D	; Width-1  bit 8
.def	Blt_H							= $0E	; Height-1
.def	Blt_And							= $0F	; And mask (0 = constant source)
.def	Blt_Xor							= $10	; Xor mask (= fill value when And = 0)
.def	Blt_Ctrl						= $14

; Temp debug stuff
.def	V_0								= $10	; 0 (Screen code used for Version in loading screen)
.def	V_1								= $11	; 1 (Screen code used for Version in loading screen)
.def	V_2								= $12	; 1 (Screen code used for Version in loading screen)
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
	jsr Text_Init						; Build the 80-column text screen (text80.asm)

	lda #$00
	sta Scan_Drive						; Default scan location = "D:" (current drive)
	sta Scan_Path						; No subdirectory
	sta Font_Sel						; Start on the CGA font (XDL_Text CHBASE = $44)
	lda #$05
	sta Slide_Secs						; Default slideshow delay, seconds

	lda #$00
	sta SDMCTL							; Turn ANTIC DMA off - VBXE owns the display

	lda #%00000011						; XDL,XCOLOR Enabled and transparent color index 0
	vbsta VBXE_VIDEO_CONTROL

	lda #$FF							; Must set priority when using Attribute Map
	vbsta VBXE_P0						; because VBXE defaults P0-P3 to #$00 on power-up

	jsr Text_Activate					; show the text XDL now (Rescan_Images can be slow)

	jsr Rescan_Images					; Scan Scan_Drive/Scan_Path, sort the list
	jsr Enter_Selector					; Show the file selector

main
; All done - now loop forever
	lda #$00
	sta ATRACT							; Disable Attract Mode

	jsr Wait_For_Sync					; Wait for VSYNC - this calls keyboard handler
	jsr Slideshow_Tick					; Advance the slideshow, if one is running
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
; Dispatch on the current UI mode - the selector, slideshow, drive picker and
; info viewer each have their own key set (ui.asm); mode 1 (image view) uses
; the set below.
	lda CH
	cmp #KEY_F							; F toggles the text font on every screen
	bne Handle_Keys_Mode
	jsr Toggle_Font
	jmp Read_Key_Done
Handle_Keys_Mode
	lda UI_Mode
	bne Handle_Keys_NotSelector
	jmp Selector_Keys					; 0 = selector
Handle_Keys_NotSelector
	cmp #$02
	bne Handle_Keys_NotSlide
	jmp Slideshow_Keys					; 2 = slideshow
Handle_Keys_NotSlide
	cmp #$03
	bne Handle_Keys_NotFolder
	jmp Drive_Keys						; 3 = drive picker (D-key overlay)
Handle_Keys_NotFolder
	cmp #$04
	bne Handle_Keys_ImageView
	jmp Info_Keys						; 4 = info viewer (.nfo)
Handle_Keys_ImageView

; If present, the next 3 lines will allow a "jump to exit" on a specific key press
	lda CH
	cmp #$2F							; Press Q to quit
	beq Exit
	cmp #$21							; Space - next image
	beq Handle_Space
	cmp #$34							; Backspace - previous image
	beq Handle_Backspace
	cmp #$1C							; Esc - back to the file selector
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
	jsr Selector_Sync_Cursor				; highlight follows Space/BkSp navigation
	jsr Enter_Selector					; Leave the image, return to the file selector
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
; Restore the OS state Step_1 / Check_RAMTOP changed, BEFORE Cleanup_Exit runs
; SDX_Console_Restore (its XIO 32 wants the real RAMTOP back).  Lives here, not
; in the resident Cleanup_Exit, which is page-fenced below $3300 and full - the
; init-time abort paths that jmp straight to Cleanup_Exit simply skip this.
	lda CRSINH_OLD
	sta CRSINH							; Restore Cursor
	lda COLOR1_OLD						; Restore the editor colours Step_1 changed
	sta COLOR1
	lda COLOR2_OLD
	sta COLOR2
	lda COLOR4_OLD
	sta COLOR4
	lda RAMTOP_OLD						; Give the SDX soft console its top-of-RAM back
	sta RAMTOP
	sta RAMSIZ
	jmp Cleanup_Exit					; Clean up and exit (accounts for any long branch issues)

;-----------------------------------------------------------------------------
; Increment_Image - advance File_Index within the *.MAP file band
; [FileStart, ImageCount), wrapping past the last file to the first.
; No-op when the list holds no files.  (The selector list may now also carry
; ".." and directory rows below FileStart - Space/BkSp must skip those.)
;-----------------------------------------------------------------------------
Increment_Image
	lda FileStart
	cmp ImageCount
	bcs Increment_Image_Done			; no *.MAP files in the list
	ldx File_Index
	inx
	cpx ImageCount
	bcc Increment_Image_Store
	ldx FileStart						; wrap past the last file to the first
Increment_Image_Store
	stx File_Index
	jsr Load_Image
Increment_Image_Done
	rts

;-----------------------------------------------------------------------------
; Decrement_Image - step File_Index back within [FileStart, ImageCount),
; wrapping from the first file to the last.  No-op when the list holds no files.
;-----------------------------------------------------------------------------
Decrement_Image
	lda FileStart
	cmp ImageCount
	bcs Decrement_Image_Done
	ldx File_Index
	cpx FileStart
	bne Decrement_Image_Step
	ldx ImageCount						; wrap: first file -> (last file + 1)
Decrement_Image_Step
	dex
	stx File_Index
	jsr Load_Image
Decrement_Image_Done
	rts

;-----------------------------------------------------------------------------
; Set_Palette
;  X register contains Palette #
;  XDL_Image_Normal + $08 = the byte we need to change
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
; Disable_Colour_Map (Point XDL to XDL_Image_Normal)
;-----------------------------------------------------------------------------
Disable_Colour_Map
	lda #$00							; Setup VBXE for displaying picture data
	vbsta VBXE_XDL_ADR2
	vbsta VBXE_XDL_ADR1
	lda #$15
	vbsta VBXE_XDL_ADR0

	rts

;-----------------------------------------------------------------------------
; Enable_Colour_Map (Point XDL to XDL_Image_Attribute)
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
;  In:  A          = 0 -> .PAL, 1 -> .MAP, 2 -> .RAW, 3 -> .NFO
;       File_Index = image ordinal
;  Out: FileNamePtr -> Path_Buf holding
;         "D[n]:" + Scan_Path + base(<=8) + "." + ext + $00
;       IMAGE_BANK unmapped (MEMAC_GLOBAL_DISABLE) on return
;  The base name is the space-padded 8-byte record Rescan_Images stored in
;  IMAGE_BANK; copying stops at the first space.  Emit_Path_Prefix (ui.asm)
;  writes the "D[n]:" + Scan_Path part and returns X = the next Path_Buf index.
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

	jsr Emit_Path_Prefix				; Path_Buf = "D[n]:" + Scan_Path, X = cursor

	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL					; Map the name list into the $2000 window

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
	dta c'PALMAPRAWNFO'					; selector 0=PAL 1=MAP 2=RAW 3=NFO

;-----------------------------------------------------------------------------
; Sort_Range - in-place alphabetical selection sort of the records
; [start .. start+count) in IMAGE_BANK (8-byte space-padded, lexicographic).
;   In:  A = start index, X = count.  count < 2 -> no-op.
; Rescan_Images (ui.asm) calls it once per group (dirs, then files) so the
; ".." / dir / file grouping is preserved.  O(n^2) byte compares; trivial.
; Clobbers A/X/Y, Reg2..Reg6, Name_Ptr, Sort_Ptr, Path_Buf[0..7].
;-----------------------------------------------------------------------------
Sort_Range
	cpx #$02
	bcc Sort_Range_Done					; 0 or 1 records -> nothing to do
	sta Reg2							; Reg2 = i = start
	stx Reg3							; Reg3 = count (temp)
	clc
	adc Reg3
	sta Reg5							; Reg5 = end = start + count
	sec
	sbc #$01
	sta Reg6							; Reg6 = end - 1 (outer limit)

	lda #IMAGE_BANK | MEMAC_GLOBAL_ENABLE
	vbsta VBXE_MA_BSEL

Sort_Range_Outer
	lda Reg2
	cmp Reg6
	bcs Sort_Range_Unmap				; i >= end-1 -> done

	sta Reg4							; m = i
	jsr Sort_SetNamePtr					; Name_Ptr = rec(m)

	lda Reg2
	clc
	adc #$01
	sta Reg3							; j = i + 1
Sort_Range_Inner
	lda Reg3
	cmp Reg5
	bcs Sort_Range_Inner_Done			; j >= end

	lda Reg3
	jsr Sort_SetSortPtr					; Sort_Ptr = rec(j)
	jsr Cmp_Records						; rec(m) : rec(j)
	bcc Sort_Range_Inner_Next			; rec(m) < rec(j) -> keep m
	beq Sort_Range_Inner_Next			; equal          -> keep m
	lda Reg3							; rec(m) > rec(j) -> new min is j
	sta Reg4
	lda Sort_Ptr
	sta Name_Ptr
	lda Sort_Ptr + $01
	sta Name_Ptr + $01
Sort_Range_Inner_Next
	inc Reg3
	jmp Sort_Range_Inner
Sort_Range_Inner_Done
	lda Reg4
	cmp Reg2
	beq Sort_Range_Outer_Next			; min already in place
	lda Reg2
	jsr Sort_SetSortPtr					; Sort_Ptr = rec(i)
	lda Reg4
	jsr Sort_SetNamePtr					; Name_Ptr = rec(m)
	jsr Swap_Records
Sort_Range_Outer_Next
	inc Reg2
	jmp Sort_Range_Outer

Sort_Range_Unmap
	lda #MEMAC_GLOBAL_DISABLE
	vbsta VBXE_MA_BSEL
Sort_Range_Done
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
; Viewer UI (main segment)
;-----------------------------------------------------------------------------
	icl 'text80.asm'					; VBXE 80-column text screen + font + palette
	icl 'ui.asm'						; File selector, slideshow, directory scan

;-----------------------------------------------------------------------------
;
;-----------------------------------------------------------------------------
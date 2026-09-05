 ; .loadsym "C:\Users\Stephen\source\Claude\VBXE_1024\Viewer\out\getdir.lab"
 
;-----------------------------------------------------------------------------
;  HARDWARE EQUATES
;-----------------------------------------------------------------------------
    icl 'equates.asm'

	org $3000
;-----------------------------------------------------------------------------
; Clean up and exit
;-----------------------------------------------------------------------------
Cleanup_Exit
	lda #$FF
	sta CH								; Clear last key pressed

	jmp (DOSVEC)						; Return to DOS

;-----------------------------------------------------------------------------
; Main loop
;-----------------------------------------------------------------------------
main
; All done - now loop forever
	lda #$00
	sta ATRACT							; Disable Attract Mode

	jsr Wait_For_Sync					; Wait for VSYNC - this calls keyboard handler
	jmp main

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

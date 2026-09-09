; With Attribute Map (for displaying image with the 40*240 cell attribute map on)
XDL_Image_Attribute						; Graphics mode,SD resolution, 240 lines, start at $01000, $140 bytes/line
;		 76543210  76543210
	dta %01101010,%00001110				; XDLC (2 Bytes)
	dta $EE								; XDLC_RPTL (1 byte)    No change for $EF(239) lines
	dta $00,$10,$00,$40,$01				; XDLC_OVADR (5 bytes)  Start @ $001000, Step $0140, End @ $13BFF
	dta $00,$70,$01,$A0,$00				; XDLC_MAPADR (5 bytes) Start @ $017000, Step $00A0, End @ $
	dta $00,$00,$07,$00					; XDLC_MAPPAR (4 bytes) No Scroll, size 8x1
	dta %00010001,$FF					; XDLC_OVATT (2 bytes)
;		 76543210  76543210
	dta %00000000,%10000000				; XDLC (2 Bytes) - End of XDL, wait for VSYNC

; Without Attribute Map (for displaying image using 1 palette)
XDL_Image_Normal						; Graphics mode,SD resolution, 240 lines, start at $01000, $140 bytes/line
;		 76543210
	dta %01110010						; XDLC Byte 1 $72 (XDLC_GMON | XDLC_MAPOFF | XDLC_RPTL | XDLC_OVADR)
	dta %00001000						; XDLC Byte 2 $08 (XDLC_ATT)
	dta $EE								; XDLC_RPTL (1 byte)    No change for $EF(239) lines
	dta $00,$10,$00,$40,$01				; XDLC_OVADR (5 bytes)  Start @ $001000, Step $0140, End @ $13BFF
	dta %00010001,$FF					; XDLC_OVATT (2 bytes)  
;		 76543210  76543210
	dta %00000000,%10000000				; XDLC (2 Bytes) - End of XDL, wait for VSYNC

; VBXE hardware text mode - 80 x 30 CGA-font cells for the viewer UI.
; *** PLACEHOLDER *** - assembles and roughly works; Stephen is tuning the
; resolution/width/attribute bits.  Font @ TEXT_FONT_VRAM, screen RAM @
; TEXT_SCREEN_VRAM, OVSTEP = TEXT_PITCH - all from view1024.asm's .def block so
; this XDL and text80.asm cannot drift.  OV_PALETTE = 0 (ui.asm's Restore_Palette0
; keeps standard PAL/NTSC colours in palette 0).
XDL_Text								; 240 text scanlines = 30 rows, no scroll
;		 76543210
	dta %01110001						; XDLC Byte 1 (XDLC_TMON | XDLC_MAPOFF | XDLC_RPTL | XDLC_OVADR)
	dta %00001001						; XDLC Byte 2 (XDLC_CHBASE | XDLC_ATT)
	dta $EE								; XDLC_RPTL (1 byte)    No change for 239 more lines
	dta <TEXT_SCREEN_VRAM, >TEXT_SCREEN_VRAM, TEXT_SCREEN_VRAM >> 16, <TEXT_PITCH, >TEXT_PITCH	; XDLC_OVADR (3) + OVSTEP (2)
	dta TEXT_CHBASE						; XDLC_CHBASE (1 byte)  font @ TEXT_FONT_VRAM
	dta %00000001,$FF					; XDLC_OVATT (2 bytes)  OV_WIDTH=01 | OV_PALETTE=00 | PF_PALETTE=00 ; Priority $FF
;		 76543210  76543210
	dta %00000000,%10000000				; XDLC (2 Bytes) - End of XDL, wait for VSYNC
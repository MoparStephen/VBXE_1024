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

; VBXE hardware split-screen menu/info XDL - banner + main text + separator +
; footer text + separator, framed by blank borders.  Used by both the file
; selector (UI_Mode 0) and the info/.nfo viewer (UI_Mode 4); the image viewer
; (XDL_Image_Attribute/Normal above) is untouched.  Font/screen/pitch equates
; all come from view1024.asm's .def block so this XDL and text80.asm cannot
; drift.  OV_PALETTE = 0 (ui.asm's Restore_Palette0 keeps standard PAL/NTSC
; colours in palette 0); the banner's attribute map lives in its own
; dedicated, resident MENU_BANNER_MAP_VRAM (loaded once at boot, never the
; shared CRAM $017000 the image viewer uses) so it never needs a reload.
; Only the banner's palette REGISTERS (1-3) need a per-Enter_Selector
; refresh - a cheap resident-VRAM-to-register copy, no disk access - since
; VBXE has exactly 4 physical palette registers total and Load_Image
; legitimately overwrites them for every real image viewed; see
; Apply_Menu_Banner_Palette (view1024.asm).
;
; 240-scanline layout (confirmed with Stephen):
;   8  blank (top border)
;  36  med-res graphics + attribute map (banner)                  MENU_BANNER_VRAM
; 160  text, 20 rows (main content: grid / Location / NFO scroll) TEXT_SCREEN_VRAM
;   1  lo-res graphics, no attribute map (separator)               MENU_SEP_VRAM
;   1  blank
;  24  text, 3 rows (footer: status/delay/legend, or info hint)   TEXT_FOOTER_VRAM
;   1  lo-res graphics, no attribute map (separator, same image)   MENU_SEP_VRAM
;   9  blank (bottom border)
;  ---
; 240  total
XDL_MainMenu
; Blank-group encoding (XDLC_OVOFF|XDLC_MAPOFF|XDLC_RPTL, no OVADR/OVATT) and
; the RPTL = scanlines-1 formula both come from Stephen's own working draft.
;		 76543210
; --- Block 1: 8 blank scanlines (top border) --------------------------------
	dta %00110100						; XDLC Byte 1 $34 (XDLC_OVOFF | XDLC_MAPOFF | XDLC_RPTL)
	dta $00								; XDLC Byte 2 (no ATT/CHBASE)
	dta $07								; XDLC_RPTL = 8-1

; --- Block 2: 36 med-res scanlines, banner (attribute-mapped) --------------
	dta %01101010,%00001110			; XDLC (GMON|MAPON|RPTL|OVADR, ATT) - matches XDL_Image_Attribute
	dta $23								; XDLC_RPTL = 36-1
	dta <MENU_BANNER_VRAM, >MENU_BANNER_VRAM, MENU_BANNER_VRAM >> 16, <MENU_BANNER_PITCH, >MENU_BANNER_PITCH
	dta <MENU_BANNER_MAP_VRAM, >MENU_BANNER_MAP_VRAM, MENU_BANNER_MAP_VRAM >> 16, <$00A0, >$00A0	; XDLC_MAPADR (5 bytes) - dedicated, resident (NOT shared CRAM), Step $00A0
	dta $00,$00,$07,$00					; XDLC_MAPPAR (4 bytes) No Scroll, size 8x1
	dta %00010001,$FE					; XDLC_OVATT (2 bytes)  Priority $FE (per Stephen's draft)

; --- Block 3: 160 text scanlines, 20 rows (main content) -------------------
	dta %01110001						; XDLC Byte 1 (XDLC_TMON | XDLC_MAPOFF | XDLC_RPTL | XDLC_OVADR)
	dta %00001001						; XDLC Byte 2 (XDLC_CHBASE | XDLC_ATT)
	dta $9F								; XDLC_RPTL = 160-1
	dta <TEXT_SCREEN_VRAM, >TEXT_SCREEN_VRAM, TEXT_SCREEN_VRAM >> 16, <TEXT_PITCH, >TEXT_PITCH
XDL_MainMenu_CHBase						; Toggle_Font pokes this byte - see text80.asm
	dta TEXT_CHBASE						; XDLC_CHBASE (1 byte)  font @ TEXT_FONT_VRAM
	dta %00000001,$FE					; XDLC_OVATT (2 bytes)  OV_WIDTH=01 | OV_PALETTE=00 ; Priority $FE

; --- Block 4: 1 lo-res scanline, separator (no attribute map) --------------
; OV_WIDTH=00 (vs the banner/text's 01) for the narrower 160-byte/row lo-res
; pitch - UNVERIFIED, tune against Altirra alongside the RPTL/chaining checks
; this whole XDL already needs (see the implementation plan's risk notes).
	dta %01110010						; XDLC Byte 1 (XDLC_GMON | XDLC_MAPOFF | XDLC_RPTL | XDLC_OVADR)
	dta %00101000						; XDLC Byte 2 (XDLC_ATT | XDLC_LR)
	dta $00								; XDLC_RPTL = 1-1
	dta <MENU_SEP_VRAM, >MENU_SEP_VRAM, MENU_SEP_VRAM >> 16, <MENU_SEP_PITCH, >MENU_SEP_PITCH
	dta %00000001,$FE					; XDLC_OVATT (2 bytes)  OV_WIDTH=00 (lo-res) | OV_PALETTE=00 ; Priority $FE

; --- Block 5: 1 blank scanline ----------------------------------------------
	dta %00110100
	dta $00
	dta $00								; XDLC_RPTL = 1-1

; --- Block 6: 24 text scanlines, 3 rows (footer) ----------------------------
	dta %01110001
	dta %00001001
	dta $17								; XDLC_RPTL = 24-1
	dta <TEXT_FOOTER_VRAM, >TEXT_FOOTER_VRAM, TEXT_FOOTER_VRAM >> 16, <TEXT_PITCH, >TEXT_PITCH
XDL_MainMenu_CHBase2						; Toggle_Font pokes this byte too - see text80.asm
	dta TEXT_CHBASE
	dta %00000001,$FE

; --- Block 7: 1 lo-res scanline, separator (same image as Block 4) ---------
	dta %01110010
	dta %00101000
	dta $00								; XDLC_RPTL = 1-1
	dta <MENU_SEP_VRAM, >MENU_SEP_VRAM, MENU_SEP_VRAM >> 16, <MENU_SEP_PITCH, >MENU_SEP_PITCH
	dta %00000001,$FE

; --- Block 8: 9 blank scanlines (bottom border) -----------------------------
	dta %00110100
	dta $00
	dta $08								; XDLC_RPTL = 9-1

;		 76543210  76543210
	dta %00000000,%10000000				; XDLC (2 Bytes) - End of XDL, wait for VSYNC
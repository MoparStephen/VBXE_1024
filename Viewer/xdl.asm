XDL										; Graphics mode,SD resolution, 240 lines, start at $01000, $140 bytes/line
;		 76543210  76543210
	dta %01101010,%00001110				; XDLC (2 Bytes)        
	dta $EE								; XDLC_RPTL (1 byte)    No change for $EF(239) lines
	dta $00,$10,$00,$40,$01				; XDLC_OVADR (5 bytes)  Start @ $001000, Step $140, End @ $13BFF
	dta $00,$70,$01,$40,$01				; XDLC_MAPADR (5 bytes) Start @ $014000, Step $140, End @ $
	dta $00,$00,$00,$00					; XDLC_MAPPAR (4 bytes) No Scroll, size 8*1
	dta	%00010001,$FF					; XDLC_OVATT (2 bytes)  
;		 76543210  76543210
	dta %00000000,%10000000				; XDLC (2 Bytes) - End of XDL, wait for VSYNC
; Clear 496kB (leave bottom 16kB for the SVBXE.SYS driver)
; 496x16 zoom 8x8 clear blit (this takes 2 frames)
BLT_CLEAR
	dta $00,$00,$00						; Source address
	dta $00,$00							; Source step y
	dta $00								; Source step x
	dta $FF,$BF,$07						; Destination address
	dta a(-$0F80)						; Destination step y (backwards 3968 bytes) - NOTE: this equals 496 * zoom factor of 8
	dta -$01							; Destination step x (backwards	1 byte)
	dta $EF,$01							; Width-1  (495)	496 * 8 bytes wide
	dta $0F								; Height-1 (15)		 16 * 8 bytes high
	dta $00								; And mask (And mask equal to 0 so clear)
	dta $00								; Xor mask (will be filled with xor mask)
	dta $00								; Collision and mask
	dta $77								; Zoom (BLT_ZOOMY = 7, BLT_ZOOMX = 7 so 8Y*8X)
	dta $00								; Pattern feature
	dta $00								; Control (Mode 0 with NEXT bit Cleared)

; Copy 9600 attrib bytes from $14000, placing each at every 4th dest byte from $17003
; 40 cells/row * 240 rows = 9600 bytes; dest stride 4 writes to $17003,$17007,$1700B...
; The 3 zero bytes before each data byte are left intact from BLT_SETUP_CMAP_1
BLT_SETUP_CMAP_1
	dta $00,$40,$01						; Source address ($14000)
	dta $28,$00							; Source step y = 40 (advance to next row: 40 cells * 1 byte)
	dta $01								; Source step x (1)
	dta $03,$70,$01						; Destination address ($17003)
	dta $A0,$00							; Destination step y = 160 (advance to next row: 40 cells * 4 bytes)
	dta $04								; Destination step x (4)
	dta $27,$00							; Width-1 = 39   (40 cells/row)
	dta $EF								; Height-1 = 239 (240 rows; 40*240 = 9600)
	dta $FF								; And mask ($FF - pass-through, copies zero values too)
	dta $00								; Xor mask (no inversion)
	dta $00								; Collision mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control: MODE=0 (copy), NEXT=0 (last BCB)

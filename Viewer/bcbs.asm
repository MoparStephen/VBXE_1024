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

; Fill the ColourMap area ($17000-$) with the MAP OV palette every 4 bytes
; This sets up the Palette & Priority bytes for the entire Colour Map
; GTIA/ANTIC is not used at all so these bytes will always be $00
BLT_SETUP_CMAP_1
	dta $00,$40,$01						; Source address ($14000)
	dta $40,$01							; Source step y
	dta $01								; Source step x
	dta $03,$70,$01						; Destination address ($17003)
	dta $40,$01							; Destination step y
	dta $04								; Destination step x
	dta $3F,$01							; Width ($140)
	dta $EF								; Height ($F0)
	dta %00110000						; And mask (Clear all but bits 5 and 4 i.e., only set MAP OV palette)
	dta $00								; Xor mask (Direct Copy)
	dta $00								; Collision and mask
	dta $00								; Zoom
	dta $00								; Pattern feature
	dta $00								; Control

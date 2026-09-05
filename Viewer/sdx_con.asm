;-----------------------------------------------------------------------------
; sdx_con.asm - SpartaDOS X CON: soft-console 40/80-column control
;-----------------------------------------------------------------------------
; When the user boots SpartaDOS X with the 64/80-column soft console active
; (CON.SYS or CON64.SYS - the extended "E:" driver - layered on a base such as
; S_VBXE.SYS), that console fights a program that drives the VBXE directly.
;
; SDX_Console_Save_And_40  - call once at startup. Detects the soft console,
;                            remembers whether it was in extended mode, and
;                            drops it to the standard 40-column OS editor.
; SDX_Console_Restore      - call once just before jmp (DOSVEC). If the soft
;                            console was in 64/80-column mode at startup, it is
;                            put back; otherwise nothing happens.
;
; Mechanism - SDX 4.50 Programmer's/User Guide, section 6.9 "Using the CON:
; Drivers in Own Programs":
;   XIO 33,#0,12,0,"E:"    - detect. Success (status 1) means CON.SYS/CON64.SYS
;                            is loaded; the call also returns
;                              ICAX5 = activity flag ($80 = extended mode on)
;                              ICAX6 = max columns / function code (64 or 80)
;                            An error (esp. 146) means no soft console -> no-op.
;   XIO nc,#0,12,0,"E:"    - nc = the ICAX6 value; AUX2 = 0 disables the
;                            extended console (back to 40 columns).
;   XIO nc,#0,12,128,"E:"  - AUX2 = 128 re-enables it.
;
; Operates on IOCB #0, which the OS keeps open to E:/CON:. Needs the CIO
; equates from equates.asm. No other dependencies - safe to icl from any build.
;-----------------------------------------------------------------------------

SDX_CON_IOCB	equ $00						; IOCB #0 - OS editor / CON:
SDX_CON_QUERY	equ $21						; XIO 33 - detect / query extension
SDX_CON_RW		equ $0C						; AUX1 = read + write
SDX_CON_ENABLE	equ $80						; AUX2 value that enables extended mode

.var SDX_Con_Func		.byte				; function code from ICAX6 (64 or 80)
.var SDX_Con_WasExt		.byte				; $80 = extended mode active at startup

;-----------------------------------------------------------------------------
; SDX_Console_Save_And_40
;-----------------------------------------------------------------------------
SDX_Console_Save_And_40
	lda #$00
	sta SDX_Con_Func
	sta SDX_Con_WasExt

	ldx #SDX_CON_IOCB
	lda #SDX_CON_QUERY
	sta ICCOM,x
	lda #<SDX_Con_EDev
	sta ICBAL,x
	lda #>SDX_Con_EDev
	sta ICBAH,x
	lda #SDX_CON_RW
	sta ICAX1,x
	lda #$00
	sta ICAX2,x
	jsr CIOV
	bmi SDX_Console_Save_Done				; error 146 etc - no soft console

	lda ICAX6,x								; max columns / function code
	cmp #64
	beq SDX_Console_Save_FuncOK
	cmp #80
	bne SDX_Console_Save_Done				; unexpected - leave well alone
SDX_Console_Save_FuncOK
	sta SDX_Con_Func

	lda ICAX5,x								; activity flag: $80 = extended mode on
	and #$80
	sta SDX_Con_WasExt
	beq SDX_Console_Save_Done				; already 40-col - nothing to force

	lda #$00								; AUX2 = 0 -> disable extended console
	jsr SDX_Con_ModeCall
	jsr SDX_Con_ClearScreen
SDX_Console_Save_Done
	rts

;-----------------------------------------------------------------------------
; SDX_Console_Restore
;-----------------------------------------------------------------------------
SDX_Console_Restore
	lda SDX_Con_WasExt
	beq SDX_Console_Restore_Done			; started in 40-col / no soft console
	lda #SDX_CON_ENABLE						; AUX2 = 128 -> re-enable extended mode
	jsr SDX_Con_ModeCall
	jsr SDX_Con_ClearScreen
SDX_Console_Restore_Done
	rts

;-----------------------------------------------------------------------------
; SDX_Con_ModeCall - issue XIO <SDX_Con_Func>,#0,12,A,"E:"
;   A = AUX2 (0 = disable extended console, 128 = enable)
;-----------------------------------------------------------------------------
SDX_Con_ModeCall
	ldx #SDX_CON_IOCB
	sta ICAX2,x
	lda SDX_Con_Func
	sta ICCOM,x
	lda #SDX_CON_RW
	sta ICAX1,x
	lda #<SDX_Con_EDev
	sta ICBAL,x
	lda #>SDX_Con_EDev
	sta ICBAH,x
	jmp CIOV

;-----------------------------------------------------------------------------
; SDX_Con_ClearScreen - send CLEAR (125) to IOCB #0 so the editor resyncs.
; PUT BYTES with a zero buffer length makes CIO output the char in A.
;-----------------------------------------------------------------------------
SDX_Con_ClearScreen
	ldx #SDX_CON_IOCB
	lda #$0B								; PUT BYTES
	sta ICCOM,x
	lda #$00
	sta ICBLL,x
	sta ICBLH,x
	lda #$7D								; ATASCII clear screen
	jmp CIOV

SDX_Con_EDev
	dta c"E:",$9B

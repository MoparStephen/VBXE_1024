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
; SDX_Console_Restore      - call once just before jmp (DOSVEC). If a soft
;                            console was present at startup, re-assert its
;                            startup mode (40 or 64/80 col) so it re-inits and
;                            redraws - cursor included - then clear the loader
;                            screen off it. No soft console -> no-op.
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
; Operates on IOCB #0, which the OS keeps open to E:/CON:. Needs the CIO equates
; plus ROWCRS/COLCRS/OLDROW/OLDCOL from equates.asm. No other dependencies -
; safe to icl from any build.
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
	lda SDX_Con_Func						; 0 = no soft console at startup -> no-op
	beq SDX_Console_Restore_Done

	lda SDX_Con_WasExt						; $00 -> re-assert 40-col, $80 -> re-enable 64/80
	jsr SDX_Con_ModeCall

	; SDX 4.50 User Guide 6.9.3: before quitting to DOS the driver's internal
	; state must be reset by homing the cursor coords and THEN sending Clear
	; Screen (125).  The mode call alone leaves the cursor block undrawn -
	; CRSINH is already 0 but nothing has repainted it - until the console does
	; a full-screen operation (the user sees it come back on the first DIR).
	lda #$00
	sta ROWCRS
	sta COLCRS
	sta COLCRS+1
	sta OLDROW
	sta OLDCOL
	sta OLDCOL+1
	jsr SDX_Con_ClearScreen					; ASCII 125 - resyncs the driver, redraws cursor
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
; SDX_Con_ClearScreen - PUT one byte, ATASCII 125 (Clear Screen), to IOCB #0.
; A real 1-byte buffer, not the zero-length-outputs-A quirk, so it works the
; same through the soft console's handler as through the ROM editor.
;-----------------------------------------------------------------------------
SDX_Con_ClearScreen
	ldx #SDX_CON_IOCB
	lda #$0B								; PUT BYTES
	sta ICCOM,x
	lda #<SDX_Con_ClrChar
	sta ICBAL,x
	lda #>SDX_Con_ClrChar
	sta ICBAH,x
	lda #$01
	sta ICBLL,x
	lda #$00
	sta ICBLH,x
	jmp CIOV

SDX_Con_ClrChar
	dta $7D									; ATASCII clear screen
SDX_Con_EDev
	dta c"E:",$9B

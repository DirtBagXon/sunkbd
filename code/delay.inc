;; -*-asm-*-
;; $Id: delay.inc,v 1.8 2007/11/10 10:52:42 az Exp $
;; 1ms, 10ms and Xms delay routines
;; work on any pic processor, incl. 12x5

;; variables expected/required:	one named scratch

;; w++ until zero, 5 cycles per loop, 1280c for full run
;; w is not initialised in here; if we start with w=0, then we
;; get a full loop.
loopw5	macro
	subwf PCL,W		; magic that adds 1 to w, 
	subwf PCL,W		; which the 12x can't do directly
	btfss STATUS,Z
	goto $-3
	nop
	endm

;; this delays in multiples of five us
;; but macro and as such not overly nice
_delayX5us macro fivers
	movlw	(.256-fivers)
	loopw5
	endm

;; delays in multiples of 5us, at least 10us (for args 0,1,2)
;; max:	 1275c for w=255
;; arg in w is destroyed
delayX5us:
	nop			; 3c entry and pad
	sublw	0xff		; 4
	addlw	3		; 5, runs=256-(w+2)
	btfsc	STATUS,C	; 6 if overflow, 7 normal
	goto	__delaxx5us_done		; 8 if overflow
	nop			; 8c
	loopw5
__delaxx5us_done:	retlw 0 ;2c exit
	

;; delays 1ms/10/100ms, compensated for call+return
;; variables: scratch, but nukes W!
delay100ms:			; 14c entry/exit overhead
	movlw .78		; 3c with call, 99840c plus overhead=100083
				; which would be 83c too long 
	movwf scratch		; 1c
	movlw .17		; 1c shorter first cycle (-85c)
	goto $+1		; plus 2c padding
	goto _d1loopy		; 2c
delay1ms:			; 15c entry and exit overhead
	movlw	1		; 1 loopw5, 3c with call
	movwf	scratch		; 1c
	movlw	.59		; reduced by 59x5=295c, 1c
	nop			; 3c padding
	goto	$+1
	goto	_d1loopy	; 2c
delay10ms:			; 14c entry/exit overhead, 
	movlw 8			; 3c with call
	movwf scratch		; 1c
	movlw .55		; 1c, first run must be 55x5 cycles shorter
	goto	$+1		; 4c padding
	goto	$+1
_d1loopy:	loopw5			; 5c/loop, 1280c for full run
				; (3c per loopyrun-1)
	decfsz scratch,F	; 1c inside, 2 leaving
	goto _d1loopy		; 2c inside
	nop			; 1 leaving
	retlw 0			; 2c leaving


;; 16 ops, only a single scratch variable :-))
;; expects number of ms as arg in W
delayXms:
	movwf scratch		; 3c with call
_dxloopy:
	movlw .59		; 1c
	decfsz scratch,F	; 2c last, 1 non-last
	movlw .58		; 1c nonlast
	loopw5			; 990c normal, 985c last
	goto $+1		; 3c padding
	nop
	movf scratch,f		; 1c, sets status
	btfss STATUS,Z		; 1 inside, 2 leaving
	goto _dxloopy		; 2 inside
	nop			; 1 leaving
	retlw 0			; 2c leaving	
	
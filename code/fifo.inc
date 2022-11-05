;; -*-asm-*-
;; $Id: fifo.inc,v 1.2 2010/03/03 13:41:56 az Exp $
;; fifo routines
;; requires one temp variable:  rbe

; each fifo datastructure must be:	
; readp, buffer...., writep
;
; readp points to next FULL byte, writep is next EMPTY byte
; empty is signalled: readp=writep
; full:	writep points to writep, must be undone on read!

; as rp and wp are *everywhere* in the functions, i've decided to make
; macros that generate appropriate functions. macro-only put and gets are
; too ugly for my liking.

; initializes a fifo:
; rp=wp=&(rp+1)
FINIT	macro	RP,WP
	movlw	RP
	addlw	1
	movwf	RP
	movwf	WP
	endm

; empty fifo test
; destroys w, sets z if empty
FEMPTY	macro	RP,WP
	movfw	RP		; *rp==*wp?
	subwf	WP,W
	endm

; full fifo test
; destroys w, sets z if full
FFULL	macro	RP,WP
	movlw	WP
	subwf	WP,W
	endm

; return top element in w but don't remove it (yet)
; w = zero if empty
FPEEK	macro	RP,WP
	FEMPTY	RP,WP	; z if empty
	btfsc	STATUS,Z
	goto	$+4
	movfw	RP	; setup reading then
	movwf	FSR	
	movfw	INDF
	endm	
	

; makes put function for this fifo.
; puts w into fifo. does nothing if fifo full.
; needs temporary variable rbe
FPUTW	macro	RP,WP
	movwf	rbe		; save the value
	FFULL	RP,WP
	btfsc	STATUS,Z	; skip if !z, ie nonfull
	return
	movfw	WP		; save the stuff
	movwf	FSR
	movfw	rbe
	movwf	INDF
	incf	WP,F
	movlw	WP		; at end? then wrap to buffer start
	subwf	WP,W		; z if wp points to wp
	btfss	STATUS,Z	; skip if z
	goto	$+4
	movlw	RP		; wrap around to rp+1
	addlw	1
	movwf	WP
	FEMPTY	RP,WP		; are we really full now (which looks like empty)?
	btfss	STATUS,Z	
	return
	movlw	WP		; record full: wp=&wp
	movwf	WP
	return
	endm

; makes get function for this fifo.		
; gets next elem from fifo in w. does nothing if fifo empty.
FGETW	macro	RP,WP	
	FEMPTY	RP,WP		; z if empty
	btfsc	STATUS,Z
	retlw	0
	; was it full? then restore WP to RP
	FFULL	RP,WP
	btfss	STATUS,Z	; skip if z, ie. full
	goto	$+3	
	movfw	RP		 
	movwf	WP
	; setup next rp
	movfw	RP
	movwf	FSR
	incf	RP,F
	movlw	WP
	subwf	RP,W		; rp points to wp, ie. end? z if so
	btfss	STATUS,Z	; skip if z
	goto	$+4
	movlw	RP		; rp to buffer start
	movwf	RP
	incf	RP,F
	; get data
	movfw	INDF
	return
	endm



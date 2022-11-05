; sun type 4/5 keyboard to ps/2 host converter

; copyright (c) 2010 Alexander Zangerl <az@snafu.priv.at>
;
; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation (version 2 of the License).
;
; $Id: sunkbd.asm,v 1.8 2012/10/23 07:15:21 az Exp $

; this makes a 16f628(a) act as a host to a sun type 4/5 keyboard, and presents
; the translated info as a ps/2 keyboard to a computer.
; typematic repeat, leds etc. are all modelled.
		
; limitations/omissions:
; * only scan code set 2 is supported, but all modern os's default to that anyway.
; * only one typematic rate (250ms/30cps, the fastest one) is supported.
; * alt+prtscreen (84/f0 84) and auto-shift for prtscreen unmodelled. 
;   we always send the "shifted" codes (e0 7c/e0 f0 7c) but normal os's do this for us.
; * numlock doesn't change key scancodes, but again the os helps out.
; * unknown sun codes represented as f13-15 (front, open and find)
; * sun stop sends "audio stop" because there's no stop code in scan set 2
; * the compose led is unknown to ps2, and my code uses bit3 in the "set led" argument for it.
;   if you can't make your os send that the led stays dark.
	
ERRORLEVEL -302			; no bank warns
	
processor p16f628a
#include "p16f628a.inc"
	RADIX hex		

; for debugging and easier in-circuit programming you might want to change
; the _CONFIG to _MCLRE_ON - but then don't forget to tie pin 4 (MCLR) to pin 14 (Vdd,5V),
; via a 10k to 33k resistor when your programming header isn't connected.
; if you plan to wire the pullup permanently, then a diode will be required to isolate 
; Vdd from MCLR: programming involves +13V on MCLR, and you do not want to fry 
; your sun keyboard or your pc's PS/2 port...

	__CONFIG  _INTRC_OSC_NOCLKOUT & _BODEN_OFF & _CP_OFF & _MCLRE_OFF & _DATA_CP_OFF & _WDT_OFF & _LVP_OFF

; rb0 clock rb3 data
CLKPIN	equ 0
DATAPIN	equ 3

#define	DONERESET	kstatus,0	; first byte in sun reset sequence seen?
#define DONERESET2	kstatus,1	; second startup byte seen?
#define	WAITLEDS	kstatus,2	; waiting for led argument byte?
#define ISMAKE		kstatus,3	; current key is make (1) or break(0)
#define WANTREPEAT	kstatus,4	; key should be repeated asap

	cblock 0x20

	kstatus			; keyboard status: resets and the like
	current			; current sunkey code for repeats
	fromhost		; last command byte from host
	
	foo			; scratch vars
	bar
	baz
	fum
	scratch			; for delay
	rbe			; temp var for fifo routines

	sunin:9,suninc		; 8-byte sun input fifo (overkill with single byte inputs but BSTS)
	ps2out:17,ps2outc	; 16-byte ps2 output fifo (remember pause and the damn 3-byte break seqs)
	endc

	cblock	0x70		; bank-shared vars
	w_save			; interrupt context
	fsr_save
	status_save
	endc

BANK1	macro
	bsf	STATUS,RP0	; bank1
	endm
BANK0	macro
	bcf	STATUS,RP0	; bank0
	endm	

	org 0			; power-on or reset
	goto init
	org 0x4
	movwf	w_save		; save context
	swapf	STATUS,W
	BANK0
	movwf	status_save
	movfw	FSR
	movwf	fsr_save
	
	call	inthandler

	movfw	fsr_save	
	movwf	FSR
	swapf	status_save,W
	movwf	STATUS
	swapf	w_save,F
	swapf	w_save,W
	retfie
	
#include "fifo.inc"
#include "delay.inc"

; turn tmr1 off, interrupt ditto. ends in bank0.
TMROFF	macro
	BANK0
	bcf	T1CON,TMR1ON	; stop timer
	bcf	PIR1,TMR1IF	; ack/clear int bit
	BANK1
	bcf	PIE1,TMR1IE	; int off
	BANK0
	endm

init:	clrf	PORTA		; default: all inputs, datasheet 
				; says "cleanup recommended"
	clrf	PORTB
	movlw	7
	movwf	CMCON		; comparators were on by default

	bsf	T1CON,T1CKPS1	; 10b: 1:4 prescaler, range 1..256ms
	bcf	T1CON,T1CKPS0	

	clrf	current
	clrf	kstatus		; clean slate
		
	FINIT	sunin,suninc
	FINIT	ps2out,ps2outc

	; stdtable and exttable are the only high objects
	; and also sole computed-goto users
	movlw	HIGH stdtable	
	movwf	PCLATH
	nop

	BANK1
	bcf	OPTION_REG,NOT_RBPU ; portb pullups on
	
	; usart: 1200, 8n1
	bcf	TXSTA,SYNC	; make sure async
	bcf	TXSTA,BRGH	; lowspeed
	movlw	.51		; 1200bd
	movwf	SPBRG
	bsf	TXSTA,TXEN	; transmitter on
	bsf	PIE1,RCIE	; receive interrupt on
	BANK0

	movlw	(1<<CREN|1<<SPEN)
	movwf	RCSTA		; enable serial receiver and the port overall
	movfw	RCREG		; clear any rcif indications
	

	; finally enable interrupts globally
	bsf	INTCON,PEIE	; peripheral ints on for serial
	bsf	INTCON,GIE	; global ints on

mainloop:
	; check bus: inhibited?
	btfss	PORTB,CLKPIN	; skip if clock hi
	goto	handlepending	; can't send or receive, check pending then

	; bus in rts state?
	btfss	PORTB,DATAPIN	; skip if data hi
	goto	receive
	
	; bus idle, do we need it? check if we want to send something
	FEMPTY	ps2out,ps2outc		; sets Z if empty
	btfss	STATUS,Z	; skip if z = empty
	goto	send

	; nothing to send, not receiving from host: let's check 
	; pending serial stuff then
	; also handle key repetition here
handlepending:
	btfss	WANTREPEAT	; a repeat indicated?
	goto	checksun	; nope, check the fifo then

	movfw	current		; is the last make code available?
	btfss	STATUS,Z	; skipped if zero. zero shouldn't happen: timer expired but no key to repeat.
	goto	past_reset	; byte to repeat is in z, past_reset does xlat

checksun:	
	FEMPTY	sunin,suninc	; blanks Z if empty
	btfsc	STATUS,Z	; skips if !z, non-empty
	goto	mainloop	; nothing to to at all.

	; handle sun inputs
	call	sunget		; pops into W
	iorlw	0		; input is zero? is not a valid keycode
	btfsc	STATUS,Z	; skipped if not zero
	goto	mainloop	; zero is not valid, ignore.

	btfsc	DONERESET2	; second (hence both) reset bytes seen?
	goto	past_reset

	btfsc	DONERESET	; first reset seq byte seen?
	goto	waitforsec

	; wait until 0xff shows up
	sublw	0xff
	btfsc	STATUS,Z	; skip if non-zero, non-equal
	bsf	DONERESET	; equal! reset is upon us
	goto	mainloop

waitforsec:	
	; second reset byte, wait until 0x04 shows up
	sublw	0x04
	btfss	STATUS,Z	; skip if zero, equal
	goto	mainloop
	
	bsf	DONERESET2	; reset is complete now.
	movlw	0xAA		; send "hello, reset done" on ps2
	call	ps2put

	goto	mainloop
	
past_reset:
	; sun byte in w, WANTREPEAT still set if repeat
	; xlatkey cleans up WANTREPEAT
	call	xlatkey
	goto	mainloop

send:	; handle pending outputs:	 peek byte to send, send it, if ok pop.
	FPEEK	ps2out,ps2outc
	call	sendtohost
	iorlw	0		; zero=ok response?
	btfsc	STATUS,Z	; skips if nonzero
	call	ps2get		; pop the sent byte
	goto	mainloop
receive:
	; read byte from host. saves in foo, returns 0 if ok
	call	rcvfromhost
	iorlw	0
	btfss	STATUS,Z	; skip if zero
	goto	mainloop	; dud reception.
	movfw	foo
	movwf	fromhost	; save command byte
	; send ack via queue
	movlw	0xfa
	call	ps2put

	; 0xff, reset cmd: forward to sun
	comf	fromhost,W
	btfsc	STATUS,Z	; skipped if not zero, not same
	goto	doreset
	
	; deal with id command:	send defined sequence
	movlw	0xf2
	subwf	fromhost,W
	btfsc	STATUS,Z	; skipped if not zero, not same
	goto	respond_id

	; 0xed, set led command: note the state for the next input
	movlw	0xed
	subwf	fromhost,W
	btfsc	STATUS,Z	; skipped if not zero, not same
	goto	nextisled

	; do we have a led command pending? then handle it, otherwise ignore and done
	btfss	WAITLEDS
	goto	fini

	movlw	0x0e		; set leds command
	call	sendsun
	; translate ps2 leds to sun
	;	8	4	2	1
	; ps2:	*note*	Caps	Num	Scroll
	; sun:	Caps	Scroll	Compose	Num
	; 
	; note:	ps2 doesn't have a definition for a compose led, so i added that as bit3.
	; of course you'll need operating system support to use that bit...
	clrw
	btfsc	fromhost,3	; my compose led bit
	iorlw	2
	btfsc	fromhost,2	; caps
	iorlw	8
	btfsc	fromhost,1	; num
	iorlw	1
	btfsc	fromhost,0	; scroll
	iorlw	4
	call	sendsun

fini:	bcf	WAITLEDS
	goto	mainloop

nextisled:			; just remember
	bsf	WAITLEDS
	goto	mainloop
	
; get id command, respond with 0xab, 0x83 on ps2 side
respond_id:
	movlw	0xab
	call	ps2put
	movlw	0x83
	call	ps2put
	goto	fini

doreset:	; deal with reset command, send to sun then reset our state
	movlw	0x01
	call	sendsun		; get it out!
	clrf	current		; current is n/a.
	TMROFF			; disable the timer and interrupt
	clrf	kstatus		; start at the beginning
	FINIT	sunin,suninc	; clear any pending commands sun-side
	FINIT	ps2out,ps2outc	; clear ps2 side (nukes the 0xfa)
	movlw	0xfa
	call	ps2put
	goto	mainloop	; should continue with sending the 0xfa, then the sun reset response.

; sends byte in W to the sun
; note:	 this busy-waits until the usart is ready for TX (possible problem for multi sequences)
; returns nothing.
sendsun:
	btfss	PIR1,TXIF	; ready to transmit? txif is 1 if free
	goto	$-1
	movwf	TXREG		; ser out
	nop
	return
	
; expects key in W, xlates and
; pushes relevant data to ps2out. also sets current to suncode
; for legit keys on make, clears current on break
; uses foo and bar
xlatkey:
	movwf	current
	bcf	ISMAKE
	; make or break?
	; sun makes are <x80, breaks are make+x80
	btfss	current,7
	bsf	ISMAKE		; skipped if >x80

	bcf	current,7		; now reduce to make
	; determine the nature of the key: one-off, extended or normal?

	; suncode 0x15, pause is special in ps/2: no break,
	; fucking long make sequence (8 bytes)
	movlw	0x15
	subwf	current,W
	btfss	STATUS,Z
	goto	_checkext	; skipped if zero, ie equal

	btfss	ISMAKE		; break? no break code exists for this key, nor is it typematic
	goto	_cleanup	
	
	movlw	0xe1		; the ugly sequence for break
	call	ps2put
	movlw	0x14
	call	ps2put
	movlw	0x77
	call	ps2put
	movlw	0xe1
	call	ps2put
	movlw	0xF0
	call	ps2put
	movlw	0x14
	call	ps2put
	movlw	0xf0
	call	ps2put
	movlw	0x77
	call	ps2put		
	; and now switch off repeats and timer for good measure
_cleanup:
	bcf	WANTREPEAT	; no-op key seen, repeats cancelled
	TMROFF			; no timer.
	return
	
_checkext:
	movfw	current
	call	stdtable	; check key translation, zero for nonkeys
	iorlw	0		; zero? then bail out, nothing to send
	btfsc	STATUS,Z
	goto	_cleanup
	movwf	foo
	
	; extended? then push e0 (even before make/break)
	btfss	foo,7
	goto	_isnormal

	btfss	foo,6		; the one special case:	 F7, 0x83 !extended
	goto	_ext		; skipped if set, ie F7 special

	movlw	0x83		; F7 is not extended!
	movwf	foo
	goto	_isnormal

_ext:	movlw	0xe0
	call	ps2put

	bcf	foo,7		; remove the special indicator
	movfw	foo		; and call the ext table to get the second byte
	call	exttable
	movwf	foo

_isnormal:
	; foo now holds the correct byte for this scancode
	; send the break indicator if required
	btfsc	ISMAKE		; skip if break code
	goto	_ismake

	clrf	current		; current is n/a when no key held down.
	TMROFF			; disable the timer
	movlw	0xf0		; send the break code
	call	ps2put
	goto	sendmake	; followed by the make code

_ismake:		
	; enable and arm the timer
	clrf	TMR1H		; blank the timer for max period, 262ms
	clrf	TMR1L

	btfss	WANTREPEAT	; skip if already repeating
	goto	_arm

	; already repeating, hence shorter 33.3ms period for next
	movlw	0xdf		; prime with 57203, leaves 8333 timer ticks (each is 4us) -> 33.3ms
	movwf	TMR1H
	movlw	0x73
	movwf	TMR1L

_arm:	bcf	WANTREPEAT	; no longer needed
	bcf	PIR1,TMR1IF	; ack/clear int bit for good measure
	BANK1
	bsf	PIE1,TMR1IE	; int on!
	BANK0
	bsf	T1CON,TMR1ON	; and now start the timer

sendmake:	
	movfw	foo		; then send make code
	call	ps2put
	return


; the ps2 output routine
; does expect the bus to be idle - must check this before op
; temp vars: scratch for the delay, foo, bar, baz
; byte to send:	in W
; response: zero if not interrupted, nonzero otherwise.
sendtohost:
	movwf	foo		; save the data
	movwf	fum		; once more for parity creation
	movlw	8
	movwf	bar		; 8 data bits
	movlw	1
	movwf	baz		; baz has return value

	movlw	2
	call	delayX5us	; 
	bcf	STATUS,C	; 0 = start bit 
	call	sendbit		; send startbit

sendloop:			
	btfss	PORTB,CLKPIN	; is the clock hi? skip if so
	goto	done		; else interrupted

	goto	$+1
	goto	$+1		; 4c delay (empirical)
	
	rrf	foo,F		; next bit
	call	sendbit		

	decfsz	bar,F		; all 8 bits done? 
	goto	sendloop	

	btfss	PORTB,CLKPIN	; is the clock hi? skip if so
	goto	done		; else interrupted
	
	; now calc parity of fum (destroys data)
	swapf	fum,W
	xorwf	fum,F
        rrf     fum,W 
        xorwf   fum,F 
        btfsc   fum,2 
        incf    fum,F 
	; bit 0 set: odd parity. ps2 wants odd parity, so we negate that
	comf	fum,F
	rrf	fum,F		
	call	sendbit
	
	; and the final stop bit = 1
	movlw	2		
	call	delayX5us
	bsf	STATUS,C
	call	sendbit
	clrf	baz		; successful completion

done:	BANK1			; cleanup: release data line (and clock, safely)
	movlw	0xff
	movwf	TRISB
	BANK0
	movfw	baz		; return appropriate status
	return

; bit to send: bit C of STATUS.
; sets up data, then waits a few us, then strobes clock.
sendbit:			; 2c entry
	clrf	PORTB		; prime the latch (does nothing until trisb-enabled)
	BANK1	
	movfw	TRISB
	andlw	~(1<<DATAPIN)	; prep for output = drive low for zero bit
	btfsc	STATUS,C	; skip if zero-bit
	iorlw	1<<DATAPIN	; prep for input = float high
	movwf	TRISB
	BANK0

	goto	$+1
	goto	$+1
	goto	$+1
	goto	$+1		; 8c extra
	
	call	strobeclk
	return

; one clock cycle: pull, wait, release. 
; 40c with call and return (32c strobe time)
; destroys w
strobeclk:			; 2c entry
	clrf	PORTB
	BANK1
	bcf	TRISB,CLKPIN	; make output, drive lo. 5c so far
	movlw	6		
	call	delayX5us	; 30c, at 36c now
	bsf	TRISB,CLKPIN	; make input, release to floating hi
	BANK0
	return			; 2c exit

; receives one byte from host. ignores parity (lazy me).
; byte is saved in foo. returns 0 if ok, nonzero if clocking problems
; does not test the bus state, that must happen outside
; expects to be in RTS-state: clock is high and data is lo with the start bit
; vars:	 foo, bar, baz
rcvfromhost:
	clrf	foo
	movlw	8	
	movwf	bar
	movlw	1
	movwf	baz		; default return value is bad

	movlw	3		; wait 15c, we don't know how soon we saw the RTS
	call	delayX5us	; startbit is now valid (we ignore it)
		
rcvloop:	
	call	strobeclk	; setup for bit N. 40c
	movlw	2
	call	delayX5us	; wait 10c, then sample

	bcf	STATUS,C
	btfsc	PORTB,DATAPIN	; skipped if data low
	bsf	STATUS,C
	rrf	foo,F		; c into highest bit, moves down to lowest.
	movlw	2
	call	delayX5us	; another 10c after the sampling
	decfsz	bar,F
	goto	rcvloop

	; setup parity, ignore it
	call	strobeclk
	movlw	6
	call	delayX5us	; 30c
	; setup for stop bit
	call	strobeclk

	movlw	2
	call	delayX5us
	btfss	PORTB,DATAPIN	; stopbit ok (=high)? skip if ok
	goto	kerplooie	; problem. no stop bit, keep strobing. 

	clrf	baz		; good exit code
	; send the ack bit which is a zero
	bcf	STATUS,C
	call	sendbit

done2:	BANK1
	movlw	0xff		; release data (and clock) safely
	movwf	TRISB
	BANK0
	movfw	baz
	return
	
keeptruckin:	
	call	strobeclk
	movlw	3
	call	delayX5us
	btfsc	PORTB,DATAPIN	; skip if data lo (= not ok)
	goto	done2		; dud result but we stop.
kerplooie:	
	movlw	3
	call	delayX5us
	goto	keeptruckin

; inthandler: two sources, serial receive and timer (for typematic repeats)
; context saving is done. we're in bank0.
; this function returns normally, calling code restores state and retfies
inthandler:
	; is it a timer overflow event?
	BANK1
	btfss	PIE1,TMR1IE	; skips if int is enabled
	goto	test_ser	; note in bank1
	BANK0
	btfss	PIR1,TMR1IF	; timer overflow? 
	goto	test_ser
	TMROFF			; ack interrupt and disable the timer
	bsf	WANTREPEAT	; mainloop handles repeats, we just say we want one
				; (don't want to delay here or mess with fifos)
	; now continue checking for serial reception as well.
test_ser:
	BANK1
	btfss	PIE1,RCIE	; ser receive int enabled? skip if set
	return			; lazy, returning in bank1 but context restore will fix it
	BANK0			; back in bank0 
	btfss	PIR1,RCIF	; have we received something via serial?
	return

	; serial reception: first check and clear errors where possible
	btfsc	RCSTA,FERR	; framing error clears on read (but we lose the data)
	goto	is_ferr
	btfss	RCSTA,OERR	; overflow? dis and ena, then read
	goto	is_fine
	; overflow: disable/reenable the receiver, then continue reading
	bcf	RCSTA,CREN
	bsf	RCSTA,CREN

is_fine:	; receive fine, work on it
	movfw	RCREG
	call	sunput		; in inthandler, nothing can interrupt us here
	btfss	PIR1,RCIF	; another char a/v? (rcreg is two-deep fifo)
	return			; no, thanks, done.
	goto	is_fine		; yes, so try again
	
is_ferr:			; cleared on read, next byte will make it good
	movfw	RCREG
	return

; the fifo routines
sunput:	FPUTW sunin,suninc
sunget:	FGETW sunin,suninc

ps2put:	FPUTW ps2out,ps2outc
ps2get:	FGETW ps2out,ps2outc

; 16f628: has only 128 byte eeprom, not enough to hold both translation tables.
; alternative: do it as computed goto table, because we've got plenty of prog mem.
;
; the tables contain the make codes only.
; all ps2 single-byte codes but one are <0x80 (exception: F7 is 0x83)
; extendeds are 0xe0,singlebyte (exception: pause)
;
; stdtable: input in W is sun MAKE code
; result has !bit7 -> send it straight (or ignore if zero)
; result has bit7 and bit6: send 0x80+bits0..5
; result has bit7 and !bit6: use bits0..5 as index into exttable
; make:	 straight x, break: f0, x
;
; note:	 must be called with PCLATH preset
; this gets uglier if the table crosses a 256byte-boundary 
; (which it doesn't, at 128byte plus the other table)
	org	0x300		; at 768
stdtable:
	addwf	PCL,F
		; response, sun make code, key
	dt	0	; 00)	unused
	dt	0x9b	; 01)	Stop
	dt	0x81	; 02)	Volume Down
	dt	0x9a	; 03)	Again
	dt	0x82	; 04)	Volume Up  
	dt	0x05	; 05)	F1
	dt	0x06	; 06)	F2
	dt	0x09	; 07)	F10
	dt	0x04	; 08)	F3
	dt	0x78	; 09)	F11
	dt	0x0c	; 0A)	F4
	dt	0x07	; 0B)	F12
	dt	0x03	; 0C)	F5
	dt	0x85	; 0D)	Alt Graph
	dt	0x0b	; 0E)	F6
	dt	0	; 0F)	unused
	dt	0xc3	; 10)	F7, special (bit 7 and bit 6)
	dt	0x0a	; 11)	F8
	dt	0x01	; 12)	F9
	dt	0x11	; 13)	Alt
	dt	0x88	; 14)	Cursor Up
	dt	0	; 15)	Pause, is very special
	dt	0x89	; 16)	Print Screen
	dt	0x7e	; 17)	Scroll Lock
	dt	0x8a	; 18)	Cursor Left            (Index 3)
	dt	0x39	; 19)	Props
	dt	0x99	; 1A)	Undo
	dt	0x8b	; 1B)	Cursor Down            (Index 4)
	dt	0x8c	; 1C)	Cursor Right           (Index 5)
	dt	0x76	; 1D)	Esc
	dt	0x16	; 1E)	1 !
	dt	0x1e	; 1F)	2 
	dt	0x26	; 20)	3 #
	dt	0x25	; 21)	4 $
	dt	0x2e	; 22)	5 %
	dt	0x36	; 23)	6 ^
	dt	0x3d	; 24)	7 &
	dt	0x3e	; 25)	8 *
	dt	0x46	; 26)	9 (
	dt	0x45	; 27)	0 )
	dt	0x4e	; 28)	- _
	dt	0x55	; 29)	= +
	dt	0x0e	; 2A)	` ~
	dt	0x66	; 2B)	BackSpace
	dt	0x8d	; 2C)	Insert
	dt	0x80	; 2D)	Volume Off
	dt	0x8e	; 2E)	/     (Numeric Keypad)
	dt	0x7c	; 2F)	*     (Numeric Keypad)
	dt	0x83	; 30)	Power
	dt	0x1f	; 31)	Front, f13
	dt	0x71	; 32)	. Del	(Numeric Keypad)
	dt	0x96	; 33)	Copy
	dt	0x8f	; 34)	Home
	dt	0x0d	; 35)	Tab
	dt	0x15	; 36)	q
	dt	0x1d	; 37)	w
	dt	0x24	; 38)	e
	dt	0x2d	; 39)	r
	dt	0x2c	; 3A)	t
	dt	0x35	; 3B)	y
	dt	0x3c	; 3C)	u
	dt	0x43	; 3D)	i
	dt	0x44	; 3E)	o
	dt	0x4d	; 3F)	p
	dt	0x54	; 40)	[ {
	dt	0x5b	; 41)	] }
	dt	0x90	; 42)	Delete
	dt	0x84	; 43)	Compose 
	dt	0x6c	; 44)	7 Home	(Numeric Keypad)
	dt	0x75	; 45)	8 Up	(Numeric Keypad)
	dt	0x7d	; 46)	9 PgUp	(Numeric Keypad)
	dt	0x7b	; 47)	-	(Numeric Keypad)
	dt	0x27	; 48)	Open, f14
	dt	0x97	; 49)	Paste
	dt	0x91	; 4A)	End
	dt	0	; 4B)	unused
	dt	0x14	; 4C)	Control
	dt	0x1c	; 4D)	a
	dt	0x1b	; 4E)	s
	dt	0x23	; 4F)	d
	dt	0x2b	; 50)	f
	dt	0x34	; 51)	g
	dt	0x33	; 52)	h
	dt	0x3b	; 53)	j
	dt	0x42	; 54)	k
	dt	0x4b	; 55)	l
	dt	0x4c	; 56)	;  :
	dt	0x52	; 57)	' 
	dt	0x5d	; 58)	\ |	
	dt	0x5a	; 59)	Return
	dt	0x92	; 5A)	Enter (Numeric Keypad)
	dt	0x6b	; 5B)	4 Left	(Numeric Keypad)
	dt	0x73	; 5C)	5	(Numeric Keypad)
	dt	0x74	; 5D)	6 Right	(Numeric Keypad)
	dt	0x70	; 5E)	0 Ins	(Numeric Keypad)
	dt	0x2f	; 5F)	Find, f15
	dt	0x93	; 60)	PageUp
	dt	0x95	; 61)	Cut
	dt	0x77	; 62)	NumLock
	dt	0x12	; 63)	Left Shift
	dt	0x1a	; 64)	z
	dt	0x22	; 65)	x
	dt	0x21	; 66)	c
	dt	0x2a	; 67)	v
	dt	0x32	; 68)	b
	dt	0x31	; 69)	n
	dt	0x3a	; 6A)	m
	dt	0x41	; 6B)	, <
	dt	0x49	; 6C)	. >
	dt	0x4a	; 6D)	/ ?
	dt	0x59	; 6E)	Right Shift
	dt	0	; 6F)	sparc spec says 'line feed' but nxkey
	dt	0x69	; 70)	1 End	(Numeric Keypad)
	dt	0x72	; 71)	2 Down	(Numeric Keypad)
	dt	0x7a	; 72)	3 PgDn	(Numeric Keypad)
	dt	0	; 73)	unused
	dt	0	; 74)	unused
	dt	0	; 75)	unused
	dt	0x98	; 76)	Help
	dt	0x58	; 77)	CapsLock
	dt	0x86	; 78)	Left Meta
	dt	0x29	; 79)	S P A C E
	dt	0x87	; 7A)	Right Meta
	dt	0x94	; 7B)	PageDown
	dt	0x61	; 7C)	us layout: unused, some intl layouts: \ |
	dt	0x79	; 7D)	+ (Numeric Keypad)
	dt	0	; 7E)	startup error
	dt	0	; 7F)	All Keys Are Up

; in main table: 0x80+offset
; these are to be sent as e0, x for make and e0, f0, x for break
exttable:
	addwf	PCL,F
	dt	0x23	; 0 mute
	dt	0x21	; 1 vol down
	dt	0x32	; 2 vol up
	dt	0x37	; 3 power
	dt	0x2f	; 4 compose, app
	dt	0x11	; 5 altgr, ralt
	dt	0x1f	; 6 leftmeta, lwin
	dt	0x27	; 7 rightmeta, rwin
	dt	0x75	; 8 Cursor Up
	dt	0x7C	; 9 Print Screen
	dt	0x6B	; a cursor Left
	dt	0x72	; b Cursor Down
	dt	0x74	; c Cursor Right
	dt	0x70	; d Insert
	dt	0x4A	; e / (Numeric)
	dt	0x6C	; f Home
	dt	0x71	; 10 Delete
	dt	0x69	; 11 End
	dt	0x5A	; 12 Enter (numeric)
	dt	0x7d	; 13 PageUp
	dt	0x7A	; 14 PageDown
	dt	0x43	; 15 cut
	dt	0x44	; 16 copy
	dt	0x46	; 17 paste
	dt	0x05	; 18 help
	dt	0x3d	; 19 undo
	dt	0x36	; 1a redo/again
	dt	0x3b	; 1b stop


ERRORLEVEL -220			; silly gpasm claims address beyond range on 628a, wrong.
	org	0x2100		; eeprom
	de	"ok $Id: sunkbd.asm,v 1.8 2012/10/23 07:15:21 az Exp $\r\n",0	

end


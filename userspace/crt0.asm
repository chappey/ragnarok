; crt0.asm — Minimal Win64 freestanding stubs for standalone Ragnarök .prg executables
bits 64
default rel

section .text
global __chkstk
__chkstk:
    ret

section .data
global _fltused
_fltused: dd 0

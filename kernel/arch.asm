; arch.asm — Minimal x86_64 Win64 ABI hardware I/O & CPU primitives for Ring-0 Ragnarök
; Win64 ABI: args in RCX, RDX, R8, R9; return in RAX

bits 64
default rel
section .text

global arch_inb
arch_inb:
    mov dx, cx
    xor eax, eax
    in al, dx
    ret

global arch_outb
arch_outb:
    mov ax, dx
    mov dx, cx
    out dx, al
    ret

global arch_outw
arch_outw:
    mov ax, dx
    mov dx, cx
    out dx, ax
    ret

global arch_cli
arch_cli:
    cli
    ret

global arch_hlt
arch_hlt:
    hlt
    ret

global arch_pause
arch_pause:
    pause
    ret

global arch_reboot
arch_reboot:
    cli
    ; Try i8042 keyboard controller CPU reset pulse
    mov dx, 0x64
    mov al, 0xFE
    out dx, al
    ; Intel PCH CF9 full reset (works on ThinkPad T480 & OptiPlex 7020)
    mov dx, 0xCF9
    mov al, 0x06
    out dx, al
.hang:
    hlt
    jmp .hang

global arch_poweroff
arch_poweroff:
    ; QEMU PIIX4 / Q35 ACPI S5 poweroff
    mov dx, 0x604
    mov ax, 0x2000
    out dx, ax
    cli
.hang:
    hlt
    jmp .hang

global __chkstk
__chkstk:
    ret

section .data
global _fltused
_fltused: dd 0

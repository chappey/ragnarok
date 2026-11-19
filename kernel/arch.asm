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

global arch_inl
arch_inl:
    mov dx, cx
    in eax, dx
    ret

global arch_outl
arch_outl:
    mov eax, edx
    mov dx, cx
    out dx, eax
    ret

global arch_cli
arch_cli:
    cli
    ret

global arch_sti
arch_sti:
    sti
    ret

global arch_rdtsc
arch_rdtsc:
    rdtsc
    shl rdx, 32
    or rax, rdx
    ret

global arch_read_cr2
arch_read_cr2:
    mov rax, cr2
    ret

global arch_load_gdt
arch_load_gdt:
    sub rsp, 16
    mov word [rsp], (gdt_end - gdt_start - 1)
    lea rax, [rel gdt_start]
    mov [rsp + 2], rax
    lgdt [rsp]
    add rsp, 16

    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    push qword 0x08
    lea rax, [rel .reload_cs]
    push rax
    retfq
.reload_cs:
    ret

global arch_load_idt
arch_load_idt:
    lidt [rcx]
    ret

global arch_int3
arch_int3:
    int3
    ret

%macro ISR_NOERR 1
align 16
isr_stub_%1:
    push qword 0
    push qword %1
    jmp isr_common
%endmacro

%macro ISR_ERR 1
align 16
isr_stub_%1:
    push qword %1
    jmp isr_common
%endmacro

align 16
ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

isr_common:
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    push rax

    cld
    mov rcx, rsp
    mov rbx, rsp
    and rsp, -16
    sub rsp, 32
    extern exception_handler
    call exception_handler
    mov rsp, rbx

    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15
    add rsp, 16
    iretq

global arch_get_isr_stub
arch_get_isr_stub:
    lea rax, [rel isr_stub_0]
    shl rcx, 4
    add rax, rcx
    ret

global arch_irq0_stub
arch_irq0_stub:
    push rax
    inc qword [rel g_pit_ticks]
    mov al, 0x20
    out 0x20, al
    pop rax
    iretq

global arch_irq_spurious_stub
arch_irq_spurious_stub:
    iretq

global arch_get_irq0_stub
arch_get_irq0_stub:
    lea rax, [rel arch_irq0_stub]
    ret

global arch_get_spurious_stub
arch_get_spurious_stub:
    lea rax, [rel arch_irq_spurious_stub]
    ret

global arch_get_pit_ticks
arch_get_pit_ticks:
    mov rax, [rel g_pit_ticks]
    ret

global arch_hlt
arch_hlt:
    hlt
    ret

global arch_pause
arch_pause:
    pause
    ret

global arch_mfence
arch_mfence:
    mfence
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
    ; QEMU / OVMF ACPI S5 poweroff across PIIX4 (0x404), Q35 (0x604), and Bochs (0xB004)
    mov ax, 0x2000
    mov dx, 0x604
    out dx, ax
    mov dx, 0x404
    out dx, ax
    mov dx, 0xB004
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

align 8
gdt_start:
    dq 0x0000000000000000 ; 0x00 Null
    dq 0x00AF9A000000FFFF ; 0x08 64-bit Ring-0 Code
    dq 0x00CF92000000FFFF ; 0x10 Ring-0 Data
gdt_end:

align 8
global g_pit_ticks
g_pit_ticks: dq 0

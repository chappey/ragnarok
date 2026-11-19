package kernel

// 64-bit Ring-0 GDT, 256-entry IDT, Exception Panic Screen (#BP resumable),
// 8259 PIC remap (IRQ0..15 -> vec 32..47), and 1000 Hz PIT Channel 0 tick.

Interrupt_Frame :: struct #packed {
	rax, rbx, rcx, rdx:       u64,
	rsi, rdi, rbp:            u64,
	r8, r9, r10, r11:         u64,
	r12, r13, r14, r15:       u64,
	vector, err_code:         u64,
	rip, cs, rflags, rsp, ss: u64,
}

IDT_Entry :: struct #packed {
	offset_lo: u16,
	selector:  u16,
	ist:       u8,
	type_attr: u8,
	offset_mid: u16,
	offset_hi: u32,
	reserved:  u32,
}

IDTR :: struct #packed {
	limit: u16,
	base:  u64,
}

g_idt:    [256]IDT_Entry
g_idtr:   IDTR
g_bp_hit: bool

g_exc_names := [32]string{
	"#DE Divide Error",
	"#DB Debug",
	"NMI Interrupt",
	"#BP Breakpoint",
	"#OF Overflow",
	"#BR BOUND Range Exceeded",
	"#UD Invalid Opcode",
	"#NM Device Not Available",
	"#DF Double Fault",
	"Coprocessor Segment Overrun",
	"#TS Invalid TSS",
	"#NP Segment Not Present",
	"#SS Stack-Segment Fault",
	"#GP General Protection",
	"#PF Page Fault",
	"Reserved",
	"#MF x87 FPU Error",
	"#AC Alignment Check",
	"#MC Machine Check",
	"#XM SIMD Floating-Point",
	"#VE Virtualization",
	"#CP Control Protection",
	"Reserved", "Reserved", "Reserved", "Reserved", "Reserved", "Reserved",
	"#HV Hypervisor Injection",
	"#VC VMM Communication",
	"#SX Security Exception",
	"Reserved",
}

idt_set_gate :: proc "contextless" (vec: u8, handler: u64) {
	g_idt[vec] = IDT_Entry{
		offset_lo  = u16(handler & 0xFFFF),
		selector   = 0x08,
		ist        = 0,
		type_attr  = 0x8E, // Present, DPL=0, 64-bit Interrupt Gate
		offset_mid = u16((handler >> 16) & 0xFFFF),
		offset_hi  = u32((handler >> 32) & 0xFFFF_FFFF),
		reserved   = 0,
	}
}

io_wait :: proc "contextless" () {
	arch_outb(0x80, 0)
}

pic_remap_and_pit_init :: proc "contextless" () {
	// ICW1: edge-triggered, cascade, ICW4 needed
	arch_outb(0x20, 0x11); io_wait()
	arch_outb(0xA0, 0x11); io_wait()
	// ICW2: Master offset 32 (0x20), Slave offset 40 (0x28)
	arch_outb(0x21, 0x20); io_wait()
	arch_outb(0xA1, 0x28); io_wait()
	// ICW3: Slave on IRQ2, Cascade identity 2
	arch_outb(0x21, 0x04); io_wait()
	arch_outb(0xA1, 0x02); io_wait()
	// ICW4: 8086/88 mode
	arch_outb(0x21, 0x01); io_wait()
	arch_outb(0xA1, 0x01); io_wait()

	// Mask all interrupts except Master IRQ0 (PIT timer)
	arch_outb(0x21, 0xFE)
	arch_outb(0xA1, 0xFF)

	// Program PIT Channel 0: Mode 3 square wave @ ~1000 Hz (divisor = 1193 = 0x04A9)
	arch_outb(0x43, 0x36)
	arch_outb(0x40, 0xA9)
	arch_outb(0x40, 0x04)
}

idt_init :: proc "contextless" () {
	arch_load_gdt()

	for i := 0; i < 32; i += 1 {
		idt_set_gate(u8(i), arch_get_isr_stub(u64(i)))
	}
	idt_set_gate(32, arch_get_irq0_stub())
	spurious := arch_get_spurious_stub()
	for i := 33; i < 256; i += 1 {
		idt_set_gate(u8(i), spurious)
	}

	g_idtr = IDTR{
		limit = u16(size_of(g_idt) - 1),
		base  = u64(uintptr(&g_idt[0])),
	}
	arch_load_idt(&g_idtr)
	pic_remap_and_pit_init()
	arch_sti()

	klog_line("INFO", "GDT/IDT loaded, PIC remapped (32..47), PIT IRQ0 active (1000 Hz)")
}

panic_fmt_hex64 :: proc "contextless" (buf: []u8, val: u64) -> string {
	hex := "0123456789ABCDEF"
	buf[0] = '0'
	buf[1] = 'x'
	for i := 0; i < 16; i += 1 {
		shift := u64((15 - i) * 4)
		buf[2 + i] = hex[(val >> shift) & 0xF]
	}
	return string(buf[:18])
}

panic_reg_row :: proc "contextless" (y: i32, lbl1: string, v1: u64, lbl2: string, v2: u64) {
	b1, b2: [18]u8
	s1 := panic_fmt_hex64(b1[:], v1)
	s2 := panic_fmt_hex64(b2[:], v2)

	serial_puts("  ")
	serial_puts(lbl1)
	serial_puts("=")
	serial_puts(s1)
	serial_puts("  ")
	serial_puts(lbl2)
	serial_puts("=")
	serial_puts(s2)
	serial_puts("\n")

	if g_fb.base != nil {
		gfx_text(16, y, lbl1, COL_LTCYAN, COL_BLACK)
		gfx_text(64, y, s1, COL_WHITE, COL_BLACK)
		gfx_text(256, y, lbl2, COL_LTCYAN, COL_BLACK)
		gfx_text(304, y, s2, COL_WHITE, COL_BLACK)
	}
}

@(export, link_name="exception_handler")
exception_handler :: proc "c" (f: ^Interrupt_Frame) {
	if f.vector == 3 { // Resumable #BP breakpoint self-test / debugger trap
		g_bp_hit = true
		klog_prefix("WARN")
		klog_puts("#BP breakpoint hit at RIP=")
		klog_put_hex(f.rip)
		klog_putc('\n')
		return
	}

	arch_cli()
	cr2 := arch_read_cr2()
	name := g_exc_names[f.vector] if f.vector < 32 else "Unknown Exception"
	rel_rip := f.rip - g_image_base if (g_image_base != 0 && f.rip >= g_image_base) else f.rip

	serial_puts("\n!!! RAGNAROK KERNEL PANIC !!!\n")
	serial_puts("Exception: ")
	serial_puts(name)
	serial_puts("  vec=")
	serial_put_u64(f.vector)
	serial_puts("  err=")
	serial_put_hex(f.err_code)
	serial_puts("\n")

	if g_fb.base != nil {
		gfx_clear(COL_BLACK)
		gfx_rect(0, 0, GFX_WIDTH, 20, COL_RED)
		gfx_text(16, 6, "=== RAGNAROK KERNEL PANIC ===", COL_WHITE, COL_RED)
		gfx_text(16, 32, name, COL_YELLOW, COL_BLACK)
	}

	panic_reg_row(56,  "RIP ", f.rip,      "OFF ", rel_rip)
	panic_reg_row(72,  "ERR ", f.err_code, "CR2 ", cr2)
	panic_reg_row(88,  "RSP ", f.rsp,      "FLG ", f.rflags)
	panic_reg_row(104, "CS  ", f.cs,       "SS  ", f.ss)
	panic_reg_row(128, "RAX ", f.rax,      "RBX ", f.rbx)
	panic_reg_row(144, "RCX ", f.rcx,      "RDX ", f.rdx)
	panic_reg_row(160, "RSI ", f.rsi,      "RDI ", f.rdi)
	panic_reg_row(176, "RBP ", f.rbp,      "R8  ", f.r8)
	panic_reg_row(192, "R9  ", f.r9,       "R10 ", f.r10)
	panic_reg_row(208, "R11 ", f.r11,      "R12 ", f.r12)
	panic_reg_row(224, "R13 ", f.r13,      "R14 ", f.r14)
	panic_reg_row(240, "R15 ", f.r15,      "BASE", g_image_base)

	if g_fb.base != nil {
		gfx_text(16, 272, "System halted cleanly (attach LLDB or inspect COM1 log).", COL_LTRED, COL_BLACK)
		gfx_present()
	}

	for {
		arch_hlt()
	}
}

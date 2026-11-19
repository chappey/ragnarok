package kernel

// Calibrated RDTSC timing + static 16 KiB kernel log ring buffer (dmesg).

KLOG_CAP :: u64(16384)

g_image_base: u64
g_image_size: u64

g_tsc_boot: u64
g_tsc_khz:  u64 = 1_000_000 // ticks per ms (calibrated via PIT Ch2 on boot)

g_klog_buf:   [KLOG_CAP]u8
g_klog_head:  u64
g_klog_count: u64

tsc_init :: proc "contextless" () {
	g_tsc_boot = arch_rdtsc()

	// Calibrate TSC over a 10 ms PIT Channel 2 window (11932 ticks @ 1.193182 MHz)
	gate := arch_inb(0x61)
	arch_outb(0x61, (gate & 0xFC) | 0x01)
	ticks :: u16(11932)
	t0 := arch_rdtsc()
	arch_outb(0x43, 0xB0)
	arch_outb(0x42, u8(ticks & 0xFF))
	arch_outb(0x42, u8((ticks >> 8) & 0xFF))
	for (arch_inb(0x61) & 0x20) == 0 {
		arch_pause()
	}
	delta := arch_rdtsc() - t0
	khz := delta / 10
	if khz < 1000 {
		khz = 1_000_000
	}
	g_tsc_khz = khz
}

tsc_us :: proc "contextless" () -> u64 {
	if g_tsc_khz == 0 {
		return 0
	}
	return ((arch_rdtsc() - g_tsc_boot) * 1000) / g_tsc_khz
}

tsc_ms :: proc "contextless" () -> u64 {
	if g_tsc_khz == 0 {
		return 0
	}
	return (arch_rdtsc() - g_tsc_boot) / g_tsc_khz
}

klog_putc :: proc "contextless" (c: u8) {
	if c == '\n' {
		serial_putc('\r')
	}
	serial_putc(c)

	g_klog_buf[g_klog_head] = c
	g_klog_head = (g_klog_head + 1) % KLOG_CAP
	if g_klog_count < KLOG_CAP {
		g_klog_count += 1
	}
}

klog_puts :: proc "contextless" (s: string) {
	for i := 0; i < len(s); i += 1 {
		klog_putc(s[i])
	}
}

klog_put_u64 :: proc "contextless" (val: u64) {
	if val == 0 {
		klog_putc('0')
		return
	}
	buf: [20]u8
	n := 0
	v := val
	for v > 0 {
		buf[n] = u8('0' + (v % 10))
		v /= 10
		n += 1
	}
	for i := n - 1; i >= 0; i -= 1 {
		klog_putc(buf[i])
	}
}

klog_put_hex :: proc "contextless" (val: u64) {
	hex := "0123456789ABCDEF"
	klog_puts("0x")
	for shift := u64(60); ; shift -= 4 {
		klog_putc(hex[(val >> shift) & 0xF])
		if shift == 0 {
			break
		}
	}
}

klog_prefix :: proc "contextless" (level: string) {
	ms := tsc_ms() if g_tsc_khz > 0 else u64(0)
	sec := ms / 1000
	rem := ms % 1000

	klog_putc('[')
	if sec < 10 {
		klog_puts("  ")
	} else if sec < 100 {
		klog_putc(' ')
	}
	klog_put_u64(sec)
	klog_putc('.')
	klog_putc(u8('0' + (rem / 100) % 10))
	klog_putc(u8('0' + (rem / 10) % 10))
	klog_putc(u8('0' + rem % 10))
	klog_puts("] [")
	klog_puts(level)
	klog_puts("] ")
}

klog_line :: proc "contextless" (level, msg: string) {
	klog_prefix(level)
	klog_puts(msg)
	klog_putc('\n')
}

klog_write :: proc "contextless" (ob: ^Out_Buf) {
	if g_klog_count < KLOG_CAP {
		for i := u64(0); i < g_klog_count; i += 1 {
			ob_putc(ob, g_klog_buf[i])
		}
		return
	}
	for i := g_klog_head; i < KLOG_CAP; i += 1 {
		ob_putc(ob, g_klog_buf[i])
	}
	for i := u64(0); i < g_klog_head; i += 1 {
		ob_putc(ob, g_klog_buf[i])
	}
}

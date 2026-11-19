package kernel

foreign {
	arch_inb      :: proc "c" (port: u16) -> u8 ---
	arch_outb     :: proc "c" (port: u16, val: u8) ---
	arch_outw     :: proc "c" (port: u16, val: u16) ---
	arch_cli      :: proc "c" () ---
	arch_hlt      :: proc "c" () ---
	arch_pause    :: proc "c" () ---
	arch_reboot   :: proc "c" () ---
	arch_poweroff :: proc "c" () ---
}

COM1 :: u16(0x3F8)

g_serial_present: bool

serial_init :: proc "contextless" () {
	arch_outb(COM1 + 1, 0x00) // Disable interrupts
	arch_outb(COM1 + 3, 0x80) // Enable DLAB
	arch_outb(COM1 + 0, 0x01) // 115200 baud (divisor 1)
	arch_outb(COM1 + 1, 0x00)
	arch_outb(COM1 + 3, 0x03) // 8N1
	arch_outb(COM1 + 2, 0xC7) // Enable FIFO

	// Loopback probe so bare-metal machines without COM1 (e.g. ThinkPad T480)
	// never hang waiting on LSR or read floating 0xFF garbage.
	arch_outb(COM1 + 4, 0x1E) // Set loopback mode
	arch_outb(COM1 + 0, 0xAE) // Send test byte
	if arch_inb(COM1 + 0) != 0xAE {
		g_serial_present = false
		return
	}

	arch_outb(COM1 + 4, 0x0B) // Normal operation: IRQs enabled, RTS/DSR set
	g_serial_present = true
}

serial_putc :: proc "contextless" (c: u8) {
	if !g_serial_present {
		return
	}
	for (arch_inb(COM1 + 5) & 0x20) == 0 {
		arch_pause()
	}
	arch_outb(COM1, c)
}

serial_puts :: proc "contextless" (s: string) {
	if !g_serial_present {
		return
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' {
			serial_putc('\r')
		}
		serial_putc(s[i])
	}
}

serial_put_u64 :: proc "contextless" (val: u64) {
	if !g_serial_present {
		return
	}
	if val == 0 {
		serial_putc('0')
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
		serial_putc(buf[i])
	}
}

serial_put_hex :: proc "contextless" (val: u64) {
	if !g_serial_present {
		return
	}
	hex := "0123456789ABCDEF"
	serial_puts("0x")
	for shift := u64(60); ; shift -= 4 {
		serial_putc(hex[(val >> shift) & 0xF])
		if shift == 0 {
			break
		}
	}
}

serial_has_data :: proc "contextless" () -> bool {
	if !g_serial_present {
		return false
	}
	return (arch_inb(COM1 + 5) & 0x01) != 0
}

serial_poll_char :: proc "contextless" () -> (u8, bool) {
	if !serial_has_data() {
		return 0, false
	}
	return arch_inb(COM1), true
}

serial_getc :: proc "contextless" () -> u8 {
	for !serial_has_data() {
		arch_pause()
	}
	return arch_inb(COM1)
}

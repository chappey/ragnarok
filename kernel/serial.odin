package kernel

foreign {
	arch_inb      :: proc "c" (port: u16) -> u8 ---
	arch_outb     :: proc "c" (port: u16, val: u8) ---
	arch_outw     :: proc "c" (port: u16, val: u16) ---
	arch_cli      :: proc "c" () ---
	arch_hlt      :: proc "c" () ---
	arch_poweroff :: proc "c" () ---
}

COM1 :: u16(0x3F8)

serial_init :: proc "contextless" () {
	arch_outb(COM1 + 1, 0x00) // Disable interrupts
	arch_outb(COM1 + 3, 0x80) // Enable DLAB
	arch_outb(COM1 + 0, 0x01) // 115200 baud (divisor 1)
	arch_outb(COM1 + 1, 0x00)
	arch_outb(COM1 + 3, 0x03) // 8N1
	arch_outb(COM1 + 2, 0xC7) // Enable FIFO
	arch_outb(COM1 + 4, 0x0B) // IRQs enabled, RTS/DSR set
}

serial_putc :: proc "contextless" (c: u8) {
	for (arch_inb(COM1 + 5) & 0x20) == 0 {}
	arch_outb(COM1, c)
}

serial_puts :: proc "contextless" (s: string) {
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' {
			serial_putc('\r')
		}
		serial_putc(s[i])
	}
}

serial_put_u64 :: proc "contextless" (val: u64) {
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
	return (arch_inb(COM1 + 5) & 0x01) != 0
}

serial_getc :: proc "contextless" () -> u8 {
	for !serial_has_data() {}
	return arch_inb(COM1)
}

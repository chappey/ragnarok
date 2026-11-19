package kernel

// 80x60 on-screen text console rendered onto the 640x480x16 logical canvas.
// Row 0 is the fixed status bar; rows 1..59 are the scrolling terminal area.

CON_COLS :: GFX_COLS        // 80
CON_ROWS :: GFX_ROWS - 1    // 59 scrolling text rows

Console_Cell :: struct {
	ch: u8,
	fg: u8,
	bg: u8,
}

g_con_cells: [CON_ROWS * CON_COLS]Console_Cell
g_con_x:     i32
g_con_y:     i32
g_con_fg:    u8
g_con_bg:    u8

con_init :: proc "contextless" () {
	g_con_fg = COL_LTGRAY
	g_con_bg = COL_BLACK
	con_clear()
}

con_set_color :: proc "contextless" (fg, bg: u8) {
	g_con_fg = fg & 15
	g_con_bg = bg & 15
}

con_clear :: proc "contextless" () {
	for i := 0; i < len(g_con_cells); i += 1 {
		g_con_cells[i] = Console_Cell{' ', g_con_fg, g_con_bg}
	}
	g_con_x = 0
	g_con_y = 0
}

con_scroll :: proc "contextless" () {
	for y := 1; y < CON_ROWS; y += 1 {
		dst := (y - 1) * CON_COLS
		src := y * CON_COLS
		for x := 0; x < CON_COLS; x += 1 {
			g_con_cells[dst + x] = g_con_cells[src + x]
		}
	}
	last := (CON_ROWS - 1) * CON_COLS
	for x := 0; x < CON_COLS; x += 1 {
		g_con_cells[last + x] = Console_Cell{' ', g_con_fg, g_con_bg}
	}
	g_con_y = CON_ROWS - 1
}

con_putc_raw :: proc "contextless" (c: u8) {
	if c == '\r' {
		g_con_x = 0
		return
	}
	if c == '\n' {
		g_con_x = 0
		g_con_y += 1
		if g_con_y >= CON_ROWS {
			con_scroll()
		}
		return
	}
	if c == '\b' {
		if g_con_x > 0 {
			g_con_x -= 1
		}
		return
	}
	if c == '\t' {
		spaces := 4 - (g_con_x & 3)
		for i := i32(0); i < spaces; i += 1 {
			con_putc_raw(' ')
		}
		return
	}

	g_con_cells[g_con_y * CON_COLS + g_con_x] = Console_Cell{c, g_con_fg, g_con_bg}
	g_con_x += 1
	if g_con_x >= CON_COLS {
		g_con_x = 0
		g_con_y += 1
		if g_con_y >= CON_ROWS {
			con_scroll()
		}
	}
}

cmos_read_reg :: proc "contextless" (reg: u8) -> u8 {
	arch_outb(0x70, reg)
	return arch_inb(0x71)
}

bcd_to_bin :: proc "contextless" (v: u8) -> u8 {
	return (v & 0x0F) + ((v >> 4) * 10)
}

fmt_2d :: proc "contextless" (buf: []u8, off: int, v: u8) {
	buf[off]     = u8('0' + (v / 10) % 10)
	buf[off + 1] = u8('0' + v % 10)
}

// Format CMOS hardware clock as "YYYY-MM-DD HH:MM:SS" (19 bytes)
rtc_format_utc :: proc "contextless" (buf: []u8) -> int {
	for (cmos_read_reg(0x0A) & 0x80) != 0 {
		arch_pause()
	}
	sec   := cmos_read_reg(0x00)
	min   := cmos_read_reg(0x02)
	hour  := cmos_read_reg(0x04)
	day   := cmos_read_reg(0x07)
	month := cmos_read_reg(0x08)
	year  := cmos_read_reg(0x09)
	reg_b := cmos_read_reg(0x0B)

	if (reg_b & 0x04) == 0 {
		sec   = bcd_to_bin(sec)
		min   = bcd_to_bin(min)
		hour  = bcd_to_bin(hour & 0x7F) | (hour & 0x80)
		day   = bcd_to_bin(day)
		month = bcd_to_bin(month)
		year  = bcd_to_bin(year)
	}
	if (reg_b & 0x02) == 0 && (hour & 0x80) != 0 {
		hour = ((hour & 0x7F) + 12) % 24
	}

	buf[0] = '2'
	buf[1] = '0'
	fmt_2d(buf, 2, year)
	buf[4] = '-'
	fmt_2d(buf, 5, month)
	buf[7] = '-'
	fmt_2d(buf, 8, day)
	buf[10] = ' '
	fmt_2d(buf, 11, hour)
	buf[13] = ':'
	fmt_2d(buf, 14, min)
	buf[16] = ':'
	fmt_2d(buf, 17, sec)
	return 19
}

con_draw_status_bar :: proc "contextless" () {
	gfx_rect(0, 0, GFX_WIDTH, 8, COL_BLUE)
	gfx_text(8, 0, "RAGNAROK v0.1", COL_YELLOW, COL_BLUE)

	clk_buf: [19]u8
	_ = rtc_format_utc(clk_buf[:])
	gfx_text((GFX_WIDTH - 19 * 8) / 2, 0, string(clk_buf[:]), COL_WHITE, COL_BLUE)

	if g_xhci.kbd_ready && g_ps2_present {
		gfx_text(GFX_WIDTH - 88, 0, "[USB+PS/2]", COL_LTGREEN, COL_BLUE)
	} else if g_xhci.kbd_ready {
		gfx_text(GFX_WIDTH - 48, 0, "[USB]", COL_LTGREEN, COL_BLUE)
	} else if g_ps2_present {
		gfx_text(GFX_WIDTH - 56, 0, "[PS/2]", COL_LTGREEN, COL_BLUE)
	} else {
		gfx_text(GFX_WIDTH - 48, 0, "[SER]", COL_LTRED, COL_BLUE)
	}
}

con_flush :: proc "contextless" () {
	con_draw_status_bar()
	for y := i32(0); y < CON_ROWS; y += 1 {
		py := (y + 1) * 8
		row := y * CON_COLS
		for x := i32(0); x < CON_COLS; x += 1 {
			cell := g_con_cells[row + x]
			gfx_char(x * 8, py, cell.ch, cell.fg, cell.bg)
		}
	}
	// Draw crisp yellow block cursor
	cx := g_con_x * 8
	cy := (g_con_y + 1) * 8
	gfx_rect(cx, cy + 6, 8, 2, COL_YELLOW)
	gfx_present()
}

// Dual output helpers: mirror to both 80x60 on-screen console and COM1 serial
out_putc :: proc "contextless" (c: u8) {
	serial_putc(c)
	con_putc_raw(c)
}

out_puts :: proc "contextless" (s: string) {
	serial_puts(s)
	for i := 0; i < len(s); i += 1 {
		con_putc_raw(s[i])
	}
	con_flush()
}

out_put_bytes :: proc "contextless" (b: []u8) {
	if len(b) == 0 {
		return
	}
	for i := 0; i < len(b); i += 1 {
		c := b[i]
		if c == '\n' {
			serial_putc('\r')
		}
		serial_putc(c)
		con_putc_raw(c)
	}
	con_flush()
}

out_put_u64 :: proc "contextless" (val: u64) {
	serial_put_u64(val)
	if val == 0 {
		con_putc_raw('0')
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
		con_putc_raw(buf[i])
	}
}

out_put_hex :: proc "contextless" (val: u64) {
	serial_put_hex(val)
	hex := "0123456789ABCDEF"
	con_putc_raw('0')
	con_putc_raw('x')
	for shift := u64(60); ; shift -= 4 {
		con_putc_raw(hex[(val >> shift) & 0xF])
		if shift == 0 {
			break
		}
	}
}

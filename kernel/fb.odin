package kernel

// Logical TempleOS-compatible 640x480 16-color indexed canvas,
// integer-scaled through a mutable 16-entry LUT onto the physical UEFI GOP framebuffer.

GFX_WIDTH  :: 640
GFX_HEIGHT :: 480
GFX_COLS   :: GFX_WIDTH / 8   // 80 columns
GFX_ROWS   :: GFX_HEIGHT / 8  // 60 rows

// Standard TempleOS / IBM VGA 16-color palette indices
COL_BLACK       :: u8(0)
COL_BLUE        :: u8(1)
COL_GREEN       :: u8(2)
COL_CYAN        :: u8(3)
COL_RED         :: u8(4)
COL_PURPLE      :: u8(5)
COL_BROWN       :: u8(6)
COL_LTGRAY      :: u8(7)
COL_DKGRAY      :: u8(8)
COL_LTBLUE      :: u8(9)
COL_LTGREEN     :: u8(10)
COL_LTCYAN      :: u8(11)
COL_LTRED       :: u8(12)
COL_LTPURPLE    :: u8(13)
COL_YELLOW      :: u8(14)
COL_WHITE       :: u8(15)
COL_TRANSPARENT :: u8(255)

// Classic TempleOS / VGA 16-color LUT (0x00RRGGBB, matches UEFI GOP BGRX8 little-endian)
PALETTE_TEMPLEOS :: [16]u32{
	0x00000000, // 0  BLACK
	0x000000AA, // 1  BLUE
	0x0000AA00, // 2  GREEN
	0x0000AAAA, // 3  CYAN
	0x00AA0000, // 4  RED
	0x00AA00AA, // 5  PURPLE
	0x00AA5500, // 6  BROWN
	0x00AAAAAA, // 7  LTGRAY
	0x00555555, // 8  DKGRAY
	0x005555FF, // 9  LTBLUE
	0x0055FF55, // 10 LTGREEN
	0x0055FFFF, // 11 LTCYAN
	0x00FF5555, // 12 LTRED
	0x00FF55FF, // 13 LTPURPLE
	0x00FFFF55, // 14 YELLOW
	0x00FFFFFF, // 15 WHITE
}

// Alternate Nordic dusk LUT (example runtime LUT swap)
PALETTE_NORSE :: [16]u32{
	0x000B0E14, // 0  deep night
	0x001B2B4B, // 1  fjord blue
	0x002B5B3E, // 2  pine green
	0x002F6F7E, // 3  glacial cyan
	0x008F1D24, // 4  blood red
	0x00582A5E, // 5  twilight purple
	0x009C5221, // 6  ember bronze
	0x009FA8B8, // 7  ash gray
	0x003B4252, // 8  slate
	0x005E81AC, // 9  frost blue
	0x0076B87A, // 10 serpent green
	0x0088C0D0, // 11 ice cyan
	0x00E04F4F, // 12 flame red
	0x00B48EAD, // 13 aurora violet
	0x00EBCB8B, // 14 solar gold
	0x00ECEFF4, // 15 snow white
}

Framebuffer :: struct {
	base:   [^]u32,
	width:  u32,
	height: u32,
	pitch:  u32, // physical pixels per scanline
	scale:  u32, // integer scale factor (>= 1)
	off_x:  u32, // horizontal centering offset in physical pixels
	off_y:  u32, // vertical centering offset in physical pixels
}

g_fb:      Framebuffer
g_canvas:  [GFX_WIDTH * GFX_HEIGHT]u8
g_palette: [16]u32

gfx_init :: proc "contextless" (base: [^]u32, width, height, pitch: u32) {
	g_fb.base   = base
	g_fb.width  = width
	g_fb.height = height
	g_fb.pitch  = pitch

	sx := width / GFX_WIDTH
	sy := height / GFX_HEIGHT
	scale := sx if sx < sy else sy
	if scale < 1 {
		scale = 1
	}
	g_fb.scale = scale

	scaled_w := GFX_WIDTH * scale
	scaled_h := GFX_HEIGHT * scale
	g_fb.off_x = (width - scaled_w) / 2 if width > scaled_w else 0
	g_fb.off_y = (height - scaled_h) / 2 if height > scaled_h else 0

	gfx_reset_palette()

	// Clear physical GOP borders to pure black once
	if g_fb.base != nil {
		for y := u32(0); y < g_fb.height; y += 1 {
			row := y * g_fb.pitch
			for x := u32(0); x < g_fb.width; x += 1 {
				g_fb.base[row + x] = 0
			}
		}
	}
	gfx_clear(COL_BLACK)
}

gfx_reset_palette :: proc "contextless" () {
	pal := PALETTE_TEMPLEOS
	for i := 0; i < 16; i += 1 {
		g_palette[i] = pal[i]
	}
}

gfx_set_palette :: proc "contextless" (pal: [16]u32) {
	for i := 0; i < 16; i += 1 {
		g_palette[i] = pal[i]
	}
}

gfx_set_color :: proc "contextless" (idx: u8, rgb: u32) {
	g_palette[idx & 15] = rgb
}

// Atomic blit of 640x480 indexed g_canvas -> physical GOP framebuffer via g_palette LUT
gfx_present :: proc "contextless" () {
	if g_fb.base == nil {
		return
	}
	scale := g_fb.scale
	pitch := g_fb.pitch
	ox    := g_fb.off_x
	oy    := g_fb.off_y

	if scale == 1 {
		max_y := u32(GFX_HEIGHT)
		if g_fb.height < max_y { max_y = g_fb.height }
		max_x := u32(GFX_WIDTH)
		if g_fb.width < max_x { max_x = g_fb.width }

		for y := u32(0); y < max_y; y += 1 {
			src_row := y * GFX_WIDTH
			dst_row := (oy + y) * pitch + ox
			for x := u32(0); x < max_x; x += 1 {
				g_fb.base[dst_row + x] = g_palette[g_canvas[src_row + x] & 15]
			}
		}
	} else if scale == 2 {
		for y := u32(0); y < GFX_HEIGHT; y += 1 {
			src_row  := y * GFX_WIDTH
			dst_row0 := (oy + y * 2) * pitch + ox
			dst_row1 := dst_row0 + pitch
			for x := u32(0); x < GFX_WIDTH; x += 1 {
				c := g_palette[g_canvas[src_row + x] & 15]
				dx := x * 2
				g_fb.base[dst_row0 + dx]     = c
				g_fb.base[dst_row0 + dx + 1] = c
				g_fb.base[dst_row1 + dx]     = c
				g_fb.base[dst_row1 + dx + 1] = c
			}
		}
	} else {
		for y := u32(0); y < GFX_HEIGHT; y += 1 {
			src_row := y * GFX_WIDTH
			for sy := u32(0); sy < scale; sy += 1 {
				dst_row := (oy + y * scale + sy) * pitch + ox
				for x := u32(0); x < GFX_WIDTH; x += 1 {
					c := g_palette[g_canvas[src_row + x] & 15]
					dx := x * scale
					for sx := u32(0); sx < scale; sx += 1 {
						g_fb.base[dst_row + dx + sx] = c
					}
				}
			}
		}
	}
}

gfx_clear :: proc "contextless" (col: u8) {
	c := col & 15
	for i := 0; i < len(g_canvas); i += 1 {
		g_canvas[i] = c
	}
}

gfx_plot :: proc "contextless" (x, y: i32, col: u8) {
	if x < 0 || x >= GFX_WIDTH || y < 0 || y >= GFX_HEIGHT {
		return
	}
	g_canvas[u32(y) * GFX_WIDTH + u32(x)] = col & 15
}

gfx_hline :: proc "contextless" (x0, x1, y: i32, col: u8) {
	if y < 0 || y >= GFX_HEIGHT {
		return
	}
	a := x0
	b := x1
	if a > b {
		a, b = b, a
	}
	if b < 0 || a >= GFX_WIDTH {
		return
	}
	if a < 0 { a = 0 }
	if b >= GFX_WIDTH { b = GFX_WIDTH - 1 }
	c := col & 15
	row := u32(y) * GFX_WIDTH
	for x := a; x <= b; x += 1 {
		g_canvas[row + u32(x)] = c
	}
}

gfx_rect :: proc "contextless" (x, y, w, h: i32, col: u8) {
	if w <= 0 || h <= 0 {
		return
	}
	x0 := x
	y0 := y
	x1 := x + w - 1
	y1 := y + h - 1
	if x1 < 0 || y1 < 0 || x0 >= GFX_WIDTH || y0 >= GFX_HEIGHT {
		return
	}
	if x0 < 0 { x0 = 0 }
	if y0 < 0 { y0 = 0 }
	if x1 >= GFX_WIDTH { x1 = GFX_WIDTH - 1 }
	if y1 >= GFX_HEIGHT { y1 = GFX_HEIGHT - 1 }
	c := col & 15
	for cy := y0; cy <= y1; cy += 1 {
		row := u32(cy) * GFX_WIDTH
		for cx := x0; cx <= x1; cx += 1 {
			g_canvas[row + u32(cx)] = c
		}
	}
}

// Integer Bresenham line
gfx_line :: proc "contextless" (x0, y0, x1, y1: i32, col: u8) {
	cx := x0
	cy := y0
	dx := x1 - x0
	if dx < 0 { dx = -dx }
	dy := y1 - y0
	if dy < 0 { dy = -dy }
	sx := i32(1) if x0 < x1 else i32(-1)
	sy := i32(1) if y0 < y1 else i32(-1)
	err := dx - dy

	for {
		gfx_plot(cx, cy, col)
		if cx == x1 && cy == y1 {
			break
		}
		e2 := err * 2
		if e2 > -dy {
			err -= dy
			cx += sx
		}
		if e2 < dx {
			err += dx
			cy += sy
		}
	}
}

// Integer midpoint filled circle (zero floating-point)
gfx_disc :: proc "contextless" (cx, cy, r: i32, col: u8) {
	if r <= 0 {
		gfx_plot(cx, cy, col)
		return
	}
	x := r
	y := i32(0)
	err := 1 - r
	for x >= y {
		gfx_hline(cx - x, cx + x, cy + y, col)
		gfx_hline(cx - x, cx + x, cy - y, col)
		gfx_hline(cx - y, cx + y, cy + x, col)
		gfx_hline(cx - y, cx + y, cy - x, col)
		y += 1
		if err < 0 {
			err += 2 * y + 1
		} else {
			x -= 1
			err += 2 * (y - x) + 1
		}
	}
}

// Draw a single 8x8 ASCII glyph. Pass bg = COL_TRANSPARENT for transparent background.
gfx_char :: proc "contextless" (x, y: i32, ch: u8, fg, bg: u8) {
	if ch < FONT_8X8_FIRST || ch > FONT_8X8_LAST {
		if bg != COL_TRANSPARENT {
			gfx_rect(x, y, 8, 8, bg)
		}
		return
	}
	glyph := g_font8x8[ch - FONT_8X8_FIRST]
	for row := i32(0); row < 8; row += 1 {
		bits := glyph[row]
		for col := i32(0); col < 8; col += 1 {
			if (bits >> u32(col)) & 1 != 0 {
				gfx_plot(x + col, y + row, fg)
			} else if bg != COL_TRANSPARENT {
				gfx_plot(x + col, y + row, bg)
			}
		}
	}
}

gfx_text :: proc "contextless" (x, y: i32, s: string, fg, bg: u8) {
	cx := x
	for i := 0; i < len(s); i += 1 {
		gfx_char(cx, y, s[i], fg, bg)
		cx += 8
	}
}

// Boot splash showcasing the 640x480 16-color Bayer-dithered twilight sky,
// Blood Eclipse, chiseled RAGNARÖK title, and live 16-color palette bar.
g_rag_title_font := [8 * 5]u8{
	0x1E, 0x11, 0x1E, 0x14, 0x12, // R
	0x0E, 0x11, 0x1F, 0x11, 0x11, // A
	0x0E, 0x10, 0x17, 0x11, 0x0E, // G
	0x11, 0x19, 0x15, 0x13, 0x11, // N
	0x0E, 0x11, 0x1F, 0x11, 0x11, // A
	0x1E, 0x11, 0x1E, 0x14, 0x12, // R
	0x0E, 0x11, 0x11, 0x11, 0x0E, // O
	0x11, 0x12, 0x1C, 0x12, 0x11, // K
}

gfx_draw_splash :: proc "contextless" () {
	// 1. 2x2 Bayer-dithered twilight sky
	for y := i32(0); y < GFX_HEIGHT; y += 1 {
		for x := i32(0); x < GFX_WIDTH; x += 1 {
			phase := ((y & 1) << 1) | (x & 1)
			c := COL_BLACK
			if y < 96 {
				c = COL_BLACK
			} else if y < 164 {
				c = COL_BLUE if ((y - 96) * 4 / 68 > phase) else COL_BLACK
			} else if y < 236 {
				c = COL_PURPLE if ((y - 164) * 4 / 72 > phase) else COL_BLUE
			} else if y < 312 {
				c = COL_RED if ((y - 236) * 4 / 76 > phase) else COL_PURPLE
			} else if y < 392 {
				c = COL_BROWN if ((y - 312) * 4 / 80 > phase) else COL_RED
			} else {
				c = COL_BLUE
			}
			g_canvas[u32(y) * GFX_WIDTH + u32(x)] = c
		}
	}

	// 2. Blood Eclipse
	gfx_disc(320, 224, 56, COL_RED)
	gfx_disc(320, 224, 48, COL_LTRED)
	gfx_disc(320, 224, 42, COL_YELLOW)
	gfx_disc(320, 224, 37, COL_BLACK)

	// 3. Chiseled RAGNARÖK title + TWILIGHT OF THE GODS
	scale := i32(6)
	total_w := 8 * 6 * scale - scale
	cx := i32(320)
	cy := i32(28)
	for ch := i32(0); ch < 8; ch += 1 {
		for row := i32(0); row < 5; row += 1 {
			bits := g_rag_title_font[ch * 5 + row]
			for bit := i32(0); bit < 5; bit += 1 {
				if (bits & (1 << u32(4 - bit))) != 0 {
					bx := cx - total_w / 2 + (ch * 6 + bit) * scale
					by := cy + row * scale
					gfx_rect(bx + 2, by + 2, scale, scale, COL_BLACK)
					col := COL_LTRED
					if row == 0 {
						col = COL_WHITE
					} else if row <= 2 {
						col = COL_YELLOW
					}
					gfx_rect(bx, by, scale, scale, col)
				}
			}
		}
		// Umlaut over O
		if ch == 6 {
			bx := cx - total_w / 2 + (ch * 6 + 1) * scale
			by := cy - scale - 3
			gfx_rect(bx + 2, by + 2, scale - 1, scale - 2, COL_BLACK)
			gfx_rect(bx + 2 * scale + 2, by + 2, scale - 1, scale - 2, COL_BLACK)
			gfx_rect(bx, by, scale - 1, scale - 2, COL_WHITE)
			gfx_rect(bx + 2 * scale, by, scale - 1, scale - 2, COL_WHITE)
		}
	}

	by := cy + 5 * scale + 10
	gfx_hline(cx - 188, cx - 96, by + 3, COL_YELLOW)
	gfx_hline(cx + 96, cx + 188, by + 3, COL_YELLOW)
	gfx_text(cx - 80 + 1, by + 1, "TWILIGHT OF THE GODS", COL_BLACK, COL_TRANSPARENT)
	gfx_text(cx - 80, by, "TWILIGHT OF THE GODS", COL_WHITE, COL_TRANSPARENT)

	// 4. Sea horizon foam line
	gfx_hline(0, GFX_WIDTH - 1, 392, COL_LTCYAN)

	// 5. 16-color palette bar + status footer
	gfx_rect(0, 424, GFX_WIDTH, 56, COL_BLACK)
	gfx_hline(0, GFX_WIDTH - 1, 424, COL_DKGRAY)
	for i := i32(0); i < 16; i += 1 {
		gfx_rect(16 + i * 38, 434, 34, 16, u8(i))
	}
	gfx_text(16, 458, "RAGNAROK OS | 640x480x16 LOGICAL CANVAS | ODIN RING-0 UEFI", COL_YELLOW, COL_TRANSPARENT)
	gfx_present()
}

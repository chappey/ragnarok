package kernel

// Full live port of Ragnarok.HC (Twilight of the Gods — Thor vs. Jormungandr)
// Pure integer / fixed-point (Q8) freestanding Odin on our 640x480x16 logical canvas.
// Uses PIT Channel 2 (1.193182 MHz) for exact 30 FPS frame pacing on QEMU & bare metal.

SPLASH_SNOW   :: 135
SPLASH_EMBERS :: 55

g_sky_buf:  [GFX_WIDTH * GFX_HEIGHT]u8
g_sky_init: bool
g_rng:      u32 = 0x9E3779B9

// 64-entry quarter-wave sine table (0..90 deg, scaled 0..256) -> full 256-step sin/cos
g_sin_q := [65]i32{
	0,   6,   13,  19,  25,  31,  38,  44,  50,  56,  62,  68,  74,  80,  86,  92,
	98,  104, 109, 115, 121, 126, 132, 137, 142, 147, 152, 157, 162, 167, 172, 177,
	181, 185, 190, 194, 198, 202, 206, 209, 213, 216, 220, 223, 226, 229, 231, 234,
	237, 239, 241, 243, 245, 247, 248, 250, 251, 252, 253, 254, 255, 255, 256, 256,
	256,
}

// Fixed-point sine: angle in 0..255 (full circle = 256), returns -256..+256
isin :: proc "contextless" (angle: i32) -> i32 {
	a := angle & 255
	if a < 64 {
		return g_sin_q[a]
	} else if a < 128 {
		return g_sin_q[128 - a]
	} else if a < 192 {
		return -g_sin_q[a - 128]
	}
	return -g_sin_q[256 - a]
}

icos :: proc "contextless" (angle: i32) -> i32 {
	return isin(angle + 64)
}

rng_next :: proc "contextless" () -> u32 {
	x := g_rng
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	g_rng = x
	return x
}

// Wait up to `ms` milliseconds using PIT Channel 2 (1.193182 MHz),
// returning early if any PS/2 or COM1 key is pressed.
pit_wait_ms_or_key :: proc "contextless" (ms: u32) -> bool {
	rem := ms
	for rem > 0 {
		chunk := rem if rem < 40 else 40
		rem -= chunk
		ticks := u16(chunk * 1193)

		// Enable PIT Ch2 gate (bit 0), keep speaker off (bit 1 = 0)
		gate := arch_inb(0x61)
		arch_outb(0x61, (gate & 0xFC) | 0x01)
		// Channel 2, lobyte/hibyte, mode 0 (interrupt on terminal count)
		arch_outb(0x43, 0xB0)
		arch_outb(0x42, u8(ticks & 0xFF))
		arch_outb(0x42, u8((ticks >> 8) & 0xFF))

		for (arch_inb(0x61) & 0x20) == 0 {
			if _, ok := xhci_poll_char(); ok {
				return true
			}
			if _, ok := ps2_poll_char(); ok {
				return true
			}
			if _, ok := serial_poll_char(); ok {
				return true
			}
			arch_pause()
		}
	}
	return false
}

splash_build_sky :: proc "contextless" () {
	for y := i32(0); y < GFX_HEIGHT; y += 1 {
		for x := i32(0); x < GFX_WIDTH; x += 1 {
			phase := ((y & 1) << 1) | (x & 1)
			c := COL_BLACK
			if y < 88 {
				c = COL_BLACK
			} else if y < 150 {
				c = COL_BLUE if ((y - 88) * 4 / 62 > phase) else COL_BLACK
			} else if y < 215 {
				c = COL_PURPLE if ((y - 150) * 4 / 65 > phase) else COL_BLUE
			} else if y < 285 {
				c = COL_RED if ((y - 215) * 4 / 70 > phase) else COL_PURPLE
			} else if y < 365 {
				c = COL_BROWN if ((y - 285) * 4 / 80 > phase) else COL_RED
			} else {
				c = COL_BROWN
			}
			g_sky_buf[u32(y) * GFX_WIDTH + u32(x)] = c
		}
	}
	g_sky_init = true
}

splash_thick_line :: proc "contextless" (x1, y1, x2, y2, r: i32, col: u8) {
	for dy := -r; dy <= r; dy += 1 {
		for dx := -r; dx <= r; dx += 1 {
			if dx * dx + dy * dy <= r * r {
				gfx_line(x1 + dx, y1 + dy, x2 + dx, y2 + dy, col)
			}
		}
	}
}

splash_taper_line :: proc "contextless" (x1, y1, x2, y2, r1, r2, steps: i32, col: u8) {
	for i := i32(0); i <= steps; i += 1 {
		x := x1 + (x2 - x1) * i / steps
		y := y1 + (y2 - y1) * i / steps
		r := r1 + (r2 - r1) * i / steps
		if r < 1 { r = 1 }
		gfx_disc(x, y, r, col)
	}
}

splash_lightning :: proc "contextless" (x0, y0, x1, y1, seed: i32) {
	lx := x0
	ly := y0
	steps := i32(8)
	for i := i32(1); i <= steps; i += 1 {
		nx := x0 + (x1 - x0) * i / steps
		ny := y0 + (y1 - y0) * i / steps
		if i < steps {
			j := ((seed * 41 + i * 83) % 36) - 18
			nx += j
		}
		gfx_line(lx - 1, ly, nx - 1, ny, COL_LTCYAN)
		gfx_line(lx + 1, ly, nx + 1, ny, COL_LTCYAN)
		gfx_line(lx, ly, nx, ny, COL_WHITE)
		lx = nx
		ly = ny
	}
}

splash_raven :: proc "contextless" (x, y, flap: i32) {
	wy := (isin(flap) * 9) >> 8
	gfx_line(x, y - 1, x - 12, y - wy - 1, COL_LTCYAN)
	gfx_line(x - 12, y - wy - 1, x - 20, y - wy / 2 - 1, COL_LTCYAN)
	gfx_line(x, y - 1, x + 12, y - wy - 1, COL_LTCYAN)
	gfx_line(x + 12, y - wy - 1, x + 20, y - wy / 2 - 1, COL_LTCYAN)

	gfx_line(x, y, x - 12, y - wy, COL_BLACK)
	gfx_line(x - 12, y - wy, x - 20, y - wy / 2, COL_BLACK)
	gfx_line(x, y, x + 12, y - wy, COL_BLACK)
	gfx_line(x + 12, y - wy, x + 20, y - wy / 2, COL_BLACK)
	gfx_line(x, y + 1, x - 12, y - wy + 1, COL_BLACK)
	gfx_line(x, y + 1, x + 12, y - wy + 1, COL_BLACK)
}

splash_thor :: proc "contextless" (tick: i32, struck: bool) {
	// Craggy mountain cliff on left
	for x := i32(0); x < 245; x += 1 {
		y := i32(0)
		if x < 140 {
			y = 338 + ((isin(x * 2) * 12) >> 8)
		} else {
			y = 338 + (x - 140) * 142 / 105
		}
		if y < GFX_HEIGHT {
			gfx_line(x, y, x, GFX_HEIGHT - 1, COL_BLACK)
			gfx_plot(x, y, COL_DKGRAY)
			gfx_plot(x, y + 1, COL_DKGRAY)
		}
	}

	// Billowing crimson war-cape anchored to shoulders
	cape := (isin(tick * 8) * 9) >> 8
	for i := i32(0); i <= 14; i += 1 {
		cx1 := i32(109)
		cy1 := 281 + i / 3
		cx2 := 44 + i
		cy2 := 304 + i * 3 + cape
		col := COL_LTRED if i < 4 else COL_RED
		gfx_line(cx1, cy1, cx2, cy2, col)
		gfx_line(cx1, cy1 + 1, cx2, cy2 + 1, col)
	}

	// Legs & boots
	splash_thick_line(108, 312, 93, 344, 4, COL_BLACK)
	splash_thick_line(120, 312, 134, 344, 4, COL_BLACK)
	gfx_rect(89, 332, 9, 12, COL_BROWN)
	gfx_rect(129, 332, 9, 12, COL_BROWN)

	// Armored torso + Megingjord belt
	splash_thick_line(114, 281, 114, 312, 9, COL_BLACK)
	gfx_rect(106, 282, 16, 24, COL_DKGRAY)
	gfx_rect(105, 304, 18, 4, COL_YELLOW)

	// Left arm braced forward
	splash_thick_line(122, 285, 140, 294, 3, COL_BLACK)
	gfx_rect(137, 291, 5, 5, COL_YELLOW)

	// Winged steel helm + Norse beard
	gfx_disc(114, 267, 8, COL_LTGRAY)
	gfx_rect(107, 267, 15, 3, COL_DKGRAY)
	gfx_rect(110, 271, 9, 7, COL_BROWN)
	gfx_rect(112, 272, 5, 4, COL_YELLOW)
	gfx_line(106, 264, 94, 250, COL_WHITE)
	gfx_line(106, 266, 95, 254, COL_WHITE)
	gfx_line(122, 264, 134, 250, COL_WHITE)
	gfx_line(122, 266, 133, 254, COL_WHITE)
	gfx_line(106, 265, 96, 253, COL_YELLOW)
	gfx_line(122, 265, 132, 253, COL_YELLOW)

	// Raised right arm holding Mjolnir
	hx := 148 + ((isin(tick * 3) * 4) >> 8)
	hy := 235 + ((icos(tick * 3) * 4) >> 8)
	splash_thick_line(120, 283, 138, 258, 4, COL_BLACK)
	splash_thick_line(138, 258, hx, hy, 2, COL_BROWN)

	if struck {
		gfx_rect(hx - 14, hy - 12, 28, 18, COL_WHITE)
		gfx_rect(hx - 12, hy - 10, 24, 14, COL_LTCYAN)
	} else {
		gfx_rect(hx - 13, hy - 11, 26, 16, COL_LTGRAY)
		gfx_rect(hx - 11, hy - 9, 22, 12, COL_DKGRAY)
		gfx_hline(hx - 12, hx + 11, hy - 10, COL_WHITE)
	}
}

splash_serpent :: proc "contextless" (tick: i32) {
	sway := (isin(tick * 4) * 12) >> 8

	// Secondary huge coil arching out of the sea (far right)
	for i := i32(0); i <= 28; i += 1 {
		x := 485 + i * 145 / 28
		y := 420 - ((isin(i * 128 / 28) * 85) >> 8) + ((icos(tick * 3 + i * 4) * 8) >> 8)
		r := i32(16)
		gfx_disc(x, y, r, COL_GREEN)
		gfx_disc(x, y + 4, r - 5, COL_YELLOW)
		gfx_disc(x, y - 3, r - 6, COL_LTGREEN)
	}

	// Main massive S-coiled neck rising toward Thor
	for i := i32(0); i <= 50; i += 1 {
		x := 540 - i * 182 / 50 + ((isin(i * 4 + tick * 3) * 32) >> 8)
		y := 445 - i * 232 / 50 + ((icos(i * 3 - tick * 3) * 18) >> 8)
		r := 19 - i * 6 / 50
		gfx_disc(x, y, r, COL_GREEN)
		gfx_disc(x - 4, y + 3, r - 5, COL_YELLOW)
		gfx_disc(x + 2, y - 2, r - 6, COL_LTGREEN)
		if (i & 3) == 0 {
			gfx_line(x + r - 2, y - r / 2, x + r + 9, y - r / 2 - 7, COL_YELLOW)
		}
	}

	// Ferocious tapered dragon/serpent head facing Thor
	hx := 362 + sway / 2
	hy := 212 + ((icos(tick * 4) * 7) >> 8)
	jaw := 16 + ((isin(tick * 5) * 4) >> 8)

	gfx_disc(hx + 6, hy, 15, COL_GREEN)
	splash_taper_line(hx + 8, hy - 10, hx + 28, hy - 26, 4, 1, 8, COL_YELLOW)
	splash_taper_line(hx + 12, hy - 2, hx + 30, hy - 12, 3, 1, 8, COL_LTGREEN)

	// Crimson inner mouth
	for i := i32(0); i < 8; i += 1 {
		gfx_line(hx - 2, hy - 4 + i, hx - 28, hy - 10 + i * 3, COL_RED)
	}

	// Tapered upper snout & lower jaw
	splash_taper_line(hx + 2, hy - 6, hx - 42, hy - 18, 9, 3, 12, COL_GREEN)
	splash_taper_line(hx + 2, hy - 10, hx - 38, hy - 21, 4, 1, 10, COL_LTGREEN)
	splash_taper_line(hx + 2, hy + 6, hx - 34, hy + jaw, 7, 3, 10, COL_GREEN)
	splash_taper_line(hx, hy + 9, hx - 32, hy + jaw + 2, 3, 1, 10, COL_YELLOW)

	// Razor white fangs
	gfx_line(hx - 38, hy - 15, hx - 36, hy - 5, COL_WHITE)
	gfx_line(hx - 37, hy - 15, hx - 35, hy - 5, COL_WHITE)
	gfx_line(hx - 28, hy - 12, hx - 26, hy - 4, COL_WHITE)
	gfx_line(hx - 18, hy - 9, hx - 16, hy - 3, COL_WHITE)
	gfx_line(hx - 29, hy + jaw - 2, hx - 27, hy + jaw - 11, COL_WHITE)
	gfx_line(hx - 19, hy + jaw - 4, hx - 17, hy + jaw - 11, COL_WHITE)

	// Forked crimson tongue
	tx := hx - 54
	ty := hy - 2 + ((isin(tick * 13) * 5) >> 8)
	gfx_line(hx - 20, hy + 1, tx, ty, COL_LTRED)
	gfx_line(hx - 20, hy + 2, tx, ty + 1, COL_LTRED)
	gfx_line(tx, ty, tx - 11, ty - 7, COL_LTRED)
	gfx_line(tx, ty, tx - 11, ty + 6, COL_LTRED)

	// Glowing eye
	gfx_rect(hx - 9, hy - 13, 8, 7, COL_BLACK)
	gfx_rect(hx - 8, hy - 12, 6, 5, COL_LTRED)
	gfx_rect(hx - 7, hy - 11, 3, 3, COL_YELLOW)
}

splash_sea :: proc "contextless" (tick: i32) {
	for x := i32(0); x < GFX_WIDTH; x += 2 {
		y := 396 + ((isin(tick * 5 + x) * 9) >> 8) + ((icos(tick * 3 - x * 2) * 4) >> 8)
		gfx_line(x, y, x, GFX_HEIGHT - 1, COL_BLUE)
		gfx_line(x + 1, y, x + 1, GFX_HEIGHT - 1, COL_BLUE)
		gfx_plot(x, y, COL_LTCYAN)
		gfx_plot(x + 1, y, COL_LTCYAN)
		if (x & 7) == 0 {
			gfx_plot(x, y - 1, COL_WHITE)
		}
	}
}

splash_title :: proc "contextless" (cx, cy, scale: i32) {
	total_w := 8 * 6 * scale - scale
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
	gfx_rect(cx - 96, by + 2, 3, 3, COL_WHITE)
	gfx_rect(cx + 94, by + 2, 3, 3, COL_WHITE)
	gfx_text(cx - 80 + 1, by + 1, "TWILIGHT OF THE GODS", COL_BLACK, COL_TRANSPARENT)
	gfx_text(cx - 80, by, "TWILIGHT OF THE GODS", COL_WHITE, COL_TRANSPARENT)
}

// Run live 30 FPS Ragnarok animation until any key is pressed (PS/2 or COM1).
run_ragnarok_splash :: proc "contextless" () {
	if !g_sky_init {
		splash_build_sky()
	}

	// Fixed-point Q4 particle positions (pixel * 16)
	sx, sy, svx, svy: [SPLASH_SNOW]i32
	ex, ey, evy:      [SPLASH_EMBERS]i32

	for i := 0; i < SPLASH_SNOW; i += 1 {
		sx[i]  = i32(rng_next() % GFX_WIDTH) << 4
		sy[i]  = i32(rng_next() % GFX_HEIGHT) << 4
		svy[i] = 24 + i32(rng_next() % 44) // 1.5 .. 4.25 px/frame
		svx[i] = 12 + i32(rng_next() % 28) // 0.75 .. 2.5 px/frame
	}
	for i := 0; i < SPLASH_EMBERS; i += 1 {
		ex[i]  = i32(rng_next() % GFX_WIDTH) << 4
		ey[i]  = (200 + i32(rng_next() % 220)) << 4
		evy[i] = 22 + i32(rng_next() % 34)
	}

	tick := i32(0)
	for {
		struck := (tick % 32) < 5

		// 1. Sky backdrop (brief lightning flash on strike onset)
		if (tick % 32) == 0 {
			gfx_clear(COL_DKGRAY)
		} else {
			for i := 0; i < len(g_canvas); i += 1 {
				g_canvas[i] = g_sky_buf[i]
			}
		}

		// 2. Blood Eclipse
		gfx_disc(265, 165, 52, COL_RED)
		gfx_disc(265, 165, 44, COL_LTRED)
		gfx_disc(265, 165, 38, COL_YELLOW)
		gfx_disc(265 + ((isin(tick) * 2) >> 8), 165, 34, COL_BLACK)

		// 3. Huginn & Muninn
		r1x := (tick * 4) % 720 - 40
		r2x := 680 - ((tick * 3 + 220) % 720)
		splash_raven(r1x, 122 + ((isin(tick * 4) * 10) >> 8), tick * 12)
		splash_raven(r2x, 150 + ((icos(tick * 3) * 12) >> 8), tick * 11 + 64)

		// 4. Jormungandr + Raging Sea + Thor on Cliff
		splash_serpent(tick)
		splash_sea(tick)
		splash_thor(tick, struck)

		// 5. Thor's lightning striking Mjolnir & arcing toward Jormungandr
		if struck {
			hx := 148 + ((isin(tick * 3) * 4) >> 8)
			hy := 235 + ((icos(tick * 3) * 4) >> 8)
			splash_lightning(hx - 20, 0, hx, hy - 8, tick)
			splash_lightning(hx + 12, hy - 4, 325, 212, tick + 11)
		}

		// 6. Rising Muspelheim embers
		for i := 0; i < SPLASH_EMBERS; i += 1 {
			ey[i] -= evy[i]
			ex[i] += (isin(tick * 3 + i32(i) * 17) * 14) >> 8
			if ey[i] < (110 << 4) {
				ey[i] = 410 << 4
				ex[i] = i32(rng_next() % GFX_WIDTH) << 4
			}
			col := COL_YELLOW if ey[i] > (300 << 4) else COL_LTRED
			gfx_rect(ex[i] >> 4, ey[i] >> 4, 2, 2, col)
		}

		// 7. Heavy Fimbulwinter snow
		for i := 0; i < SPLASH_SNOW; i += 1 {
			sy[i] += svy[i]
			sx[i] += svx[i] + ((isin(tick * 3 + i32(i) * 13) * 10) >> 8)
			if sy[i] >= (GFX_HEIGHT << 4) {
				sy[i] = 0
				sx[i] = i32(rng_next() % GFX_WIDTH) << 4
			}
			if sx[i] >= (GFX_WIDTH << 4) {
				sx[i] -= GFX_WIDTH << 4
			}
			if sx[i] < 0 {
				sx[i] += GFX_WIDTH << 4
			}
			px := sx[i] >> 4
			py := sy[i] >> 4
			if svy[i] > 50 {
				gfx_rect(px, py, 3, 3, COL_WHITE)
			} else if svy[i] > 35 {
				gfx_rect(px, py, 2, 2, COL_WHITE)
			} else {
				gfx_plot(px, py, COL_LTCYAN)
			}
		}

		// 8. Chiseled RAGNARÖK title + subtle prompt at bottom
		splash_title(320, 22, 6)
		if ((tick / 18) & 1) == 0 {
			gfx_text(224 + 1, 464 + 1, "PRESS ANY KEY FOR SHELL", COL_BLACK, COL_TRANSPARENT)
			gfx_text(224, 464, "PRESS ANY KEY FOR SHELL", COL_WHITE, COL_TRANSPARENT)
		}

		gfx_present()

		// Pace at ~30 FPS (33ms); exit immediately on any keypress
		if pit_wait_ms_or_key(33) {
			break
		}
		tick += 1
	}
}

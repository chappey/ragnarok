package userspace

import "../kernel/syscalls"

// Ported TempleOS HolyC graphics demos running through the Ring-0 syscalls.Table
// and backed by the shell's per-command 64 KiB PMM Arena (context.allocator).

g_apps := [4]syscalls.App_Info{
	{
		name    = "matrix",
		summary = "Matrix digital rain (ported from Matrix.HC)",
		usage   = "matrix",
		run     = app_matrix,
	},
	{
		name    = "starfield",
		summary = "3D warp starfield with tinted streaks (Starfield2.HC)",
		usage   = "starfield",
		run     = app_starfield,
	},
	{
		name    = "spiro",
		summary = "Sacred geometry spirograph (ported from Spiro.HC)",
		usage   = "spiro",
		run     = app_spiro,
	},
	{
		name    = "c64",
		summary = "C64 demoscene intro: raster bars + 3D cube + scroller",
		usage   = "c64",
		run     = app_c64,
	},
}

wait_exit :: proc "contextless" (sys: ^syscalls.Table, ms: u32) -> bool {
	k, ok := sys.wait_ms_or_key(ms)
	if !ok {
		return false
	}
	return k == 0x1B || k == 'q' || k == 'Q' || k == '\r' || k == '\n' || k == 0x03
}

// ---------------------------------------------------------------------------
// 1. Matrix.HC — Digital Rain (80x60 grid)
// ---------------------------------------------------------------------------

app_matrix :: proc(sys: ^syscalls.Table, args: []string) -> int {
	cols :: syscalls.GFX_WIDTH / 8
	rows :: syscalls.GFX_HEIGHT / 8

	drops  := make([]i32, cols)
	speeds := make([]i32, cols)
	for i := 0; i < cols; i += 1 {
		drops[i]  = i32(sys.rng_next() % rows)
		speeds[i] = 1 + i32(sys.rng_next() % 2)
	}

	sys.clear(syscalls.COL_BLACK)
	for {
		// Fade trails by blacking out random 8x8 cells
		for i := 0; i < 160; i += 1 {
			rx := i32(sys.rng_next() % cols) * 8
			ry := i32(sys.rng_next() % rows) * 8
			sys.rect(rx, ry, 8, 8, syscalls.COL_BLACK)
		}

		for i := 0; i < cols; i += 1 {
			x := i32(i) * 8
			y := drops[i] * 8
			if drops[i] > 0 {
				ch := u8(33 + (sys.rng_next() % 93))
				sys.char(x, y - 8, ch, syscalls.COL_GREEN, syscalls.COL_BLACK)
			}
			head_ch := u8(33 + (sys.rng_next() % 93))
			sys.char(x, y, head_ch, syscalls.COL_LTGREEN, syscalls.COL_BLACK)

			drops[i] += speeds[i]
			if drops[i] >= rows || (sys.rng_next() % 40) == 0 {
				drops[i]  = 0
				speeds[i] = 1 + i32(sys.rng_next() % 2)
			}
		}

		sys.present()
		if wait_exit(sys, 33) {
			break
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// 2. Starfield2.HC — 260-star 3D warp starfield (Q8 fixed-point)
// ---------------------------------------------------------------------------

Star :: struct {
	x, y, z:    i32, // Q8 (-256..+256 for x/y, 12..256 for z)
	bright_col: u8,
	dim_col:    u8,
}

spawn_star :: proc "contextless" (sys: ^syscalls.Table, s: ^Star, z: i32) {
	s.x = i32(sys.rng_next() % 513) - 256
	s.y = i32(sys.rng_next() % 513) - 256
	s.z = z
	pick := sys.rng_next() % 8
	if pick < 3 {
		s.bright_col = syscalls.COL_WHITE
		s.dim_col    = syscalls.COL_DKGRAY
	} else if pick < 5 {
		s.bright_col = syscalls.COL_LTCYAN
		s.dim_col    = syscalls.COL_BLUE
	} else if pick < 7 {
		s.bright_col = syscalls.COL_YELLOW
		s.dim_col    = syscalls.COL_BROWN
	} else {
		s.bright_col = syscalls.COL_LTPURPLE
		s.dim_col    = syscalls.COL_PURPLE
	}
}

app_starfield :: proc(sys: ^syscalls.Table, args: []string) -> int {
	NUM_STARS :: 260
	NEAR_Z    :: i32(12)
	SPREAD    :: i32(180)

	stars := make([]Star, NUM_STARS)
	for i := 0; i < NUM_STARS; i += 1 {
		spawn_star(sys, &stars[i], NEAR_Z + i32(sys.rng_next() % 244))
	}

	cx :: i32(syscalls.GFX_WIDTH / 2)
	cy :: i32(syscalls.GFX_HEIGHT / 2)

	for {
		sys.clear(syscalls.COL_BLACK)
		for i := 0; i < NUM_STARS; i += 1 {
			s := &stars[i]
			s.z -= 3
			if s.z < NEAR_Z {
				spawn_star(sys, s, 256)
			}

			hx := cx + (s.x * SPREAD) / s.z
			hy := cy + (s.y * SPREAD) / s.z
			if hx < -2 || hy < -2 || hx > syscalls.GFX_WIDTH + 2 || hy > syscalls.GFX_HEIGHT + 2 {
				spawn_star(sys, s, 256)
				continue
			}

			tz := s.z + 18
			if tz > 280 { tz = 280 }
			tx := cx + (s.x * SPREAD) / tz
			ty := cy + (s.y * SPREAD) / tz

			mx := (tx + hx) / 2
			my := (ty + hy) / 2
			near := 256 - s.z

			sys.line(tx, ty, mx, my, s.dim_col)
			sys.line(mx, my, hx, hy, s.bright_col if near > 70 else s.dim_col)

			dot_col := s.dim_col
			if near > 95 {
				dot_col = s.bright_col
			} else if near > 45 {
				dot_col = syscalls.COL_LTGRAY
			}
			if near > 170 {
				sys.rect(hx - 1, hy - 1, 3, 3, dot_col)
			} else if near > 110 {
				sys.rect(hx, hy, 2, 2, dot_col)
			} else {
				sys.plot(hx, hy, dot_col)
			}
		}

		sys.present()
		if wait_exit(sys, 25) {
			break
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// 3. Spiro.HC — Sacred Geometry Spirograph
// ---------------------------------------------------------------------------

app_spiro :: proc(sys: ^syscalls.Table, args: []string) -> int {
	sys.clear(syscalls.COL_BLACK)

	cx :: i32(syscalls.GFX_WIDTH / 2)
	cy :: i32(syscalls.GFX_HEIGHT / 2)
	// R=140, r=52, d=95 -> R-r = 88, k = (140-52)/52 ~ 1.692 (Q8: 433)
	a1 := i32(0)
	x1 := cx + 88 + 95
	y1 := cy

	step := i32(0)
	for {
		a1 += 2
		ka := (a1 * 433) >> 8
		x2 := cx + ((88 * sys.icos(a1)) >> 8) + ((95 * sys.icos(ka)) >> 8)
		y2 := cy + ((88 * sys.isin(a1)) >> 8) - ((95 * sys.isin(ka)) >> 8)

		col := u8(1 + ((step / 12) % 14))
		sys.line(x1, y1, x2, y2, col)
		x1 = x2
		y1 = y2
		step += 1

		if (step & 1) == 0 {
			sys.present()
		}
		if wait_exit(sys, 12) {
			break
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// 4. C64Demo.HC — Raster Bars + 3D Wireframe Cube + Sine Scroller
// ---------------------------------------------------------------------------

g_c64_bar1 := [7]u8{
	syscalls.COL_BLUE, syscalls.COL_LTBLUE, syscalls.COL_LTCYAN, syscalls.COL_WHITE,
	syscalls.COL_LTCYAN, syscalls.COL_LTBLUE, syscalls.COL_BLUE,
}
g_c64_bar2 := [7]u8{
	syscalls.COL_RED, syscalls.COL_LTRED, syscalls.COL_YELLOW, syscalls.COL_WHITE,
	syscalls.COL_YELLOW, syscalls.COL_LTRED, syscalls.COL_RED,
}

g_cube_vx := [8]i32{-256, 256, 256, -256, -256, 256, 256, -256}
g_cube_vy := [8]i32{-256, -256, 256, 256, -256, -256, 256, 256}
g_cube_vz := [8]i32{-256, -256, -256, -256, 256, 256, 256, 256}
g_cube_e0 := [12]int{0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3}
g_cube_e1 := [12]int{1, 2, 3, 0, 5, 6, 7, 4, 4, 5, 6, 7}

app_c64 :: proc(sys: ^syscalls.Table, args: []string) -> int {
	NUM_STARS :: 64
	msg := "*** RAGNAROK C64 DEMO --- 640x480 16-COLOR RING-0 DEMOSCENE --- RASTER BARS + 3D WIREFRAME + SINE SCROLLER ***     "

	sx  := make([]i32, NUM_STARS)
	sy  := make([]i32, NUM_STARS)
	ssp := make([]i32, NUM_STARS)
	for i := 0; i < NUM_STARS; i += 1 {
		sx[i]  = i32(sys.rng_next() % syscalls.GFX_WIDTH)
		sy[i]  = i32(sys.rng_next() % syscalls.GFX_HEIGHT)
		ssp[i] = 1 + i32(sys.rng_next() % 3)
	}

	px, py: [8]i32
	tick := i32(0)
	scroll_px := i32(0)

	for {
		sys.clear(syscalls.COL_BLACK)

		// 1. Parallax background stars
		for i := 0; i < NUM_STARS; i += 1 {
			sx[i] -= ssp[i] * 2
			if sx[i] < 0 {
				sx[i] = syscalls.GFX_WIDTH - 1
				sy[i] = i32(sys.rng_next() % syscalls.GFX_HEIGHT)
			}
			col := syscalls.COL_DKGRAY
			if ssp[i] == 3 {
				col = syscalls.COL_WHITE
			} else if ssp[i] == 2 {
				col = syscalls.COL_LTGRAY
			}
			sys.plot(sx[i], sy[i], col)
		}

		// 2. Bouncing VIC-II style raster bars
		bar_y1 := 110 + ((65 * sys.isin(tick * 3)) >> 8)
		bar_y2 := 110 + ((65 * sys.isin(tick * 3 + 73)) >> 8)
		for i := i32(0); i < 7; i += 1 {
			sys.rect(0, bar_y1 + i * 5, syscalls.GFX_WIDTH, 5, g_c64_bar1[i])
		}
		for i := i32(0); i < 7; i += 1 {
			sys.rect(0, bar_y2 + i * 5, syscalls.GFX_WIDTH, 5, g_c64_bar2[i])
		}

		// 3. Rotating 3D wireframe cube (Q8 fixed-point)
		ax := tick * 2
		ay := tick * 3
		cax := sys.icos(ax)
		sax := sys.isin(ax)
		cay := sys.icos(ay)
		say := sys.isin(ay)

		for i := 0; i < 8; i += 1 {
			x := g_cube_vx[i]
			y := g_cube_vy[i]
			z := g_cube_vz[i]

			y1 := (y * cax - z * sax) >> 8
			z1 := (y * sax + z * cax) >> 8
			x2 := (x * cay + z1 * say) >> 8
			z2 := (-x * say + z1 * cay) >> 8

			denom := z2 + 870 // ~3.4 * 256
			if denom < 64 { denom = 64 }
			px[i] = syscalls.GFX_WIDTH / 2 + (x2 * 170) / denom
			py[i] = 195 + (y1 * 170) / denom
		}

		for i := 0; i < 12; i += 1 {
			sys.line(px[g_cube_e0[i]], py[g_cube_e0[i]], px[g_cube_e1[i]], py[g_cube_e1[i]], syscalls.COL_YELLOW)
		}
		for i := 0; i < 8; i += 1 {
			sys.rect(px[i] - 2, py[i] - 2, 5, 5, syscalls.COL_WHITE)
		}

		// 4. Sine-wave text scroller
		for i := i32(0); i < 82; i += 1 {
			char_idx := (int(scroll_px / 8) + int(i)) % len(msg)
			char_x   := i * 8 - (scroll_px % 8)
			char_y   := 405 + ((28 * sys.isin(tick * 6 + i * 7)) >> 8)
			c_idx    := (int(i) + int(tick / 2)) % 7
			sys.char(char_x, char_y, msg[char_idx], g_c64_bar1[c_idx], syscalls.COL_TRANSPARENT)
		}

		sys.present()
		if wait_exit(sys, 25) {
			break
		}
		tick += 1
		scroll_px += 3
	}
	return 0
}

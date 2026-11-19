package main

import "../../prg"
import "../../../kernel/syscalls"

// Standalone C64Demo.HC — Raster Bars + 3D Wireframe Cube + Sine Scroller

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

app_main :: proc(sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> int {
	if prg.want_help(ctx) {
		sys.print("Usage: c64\n  C64 demoscene intro: raster bars + 3D cube + scroller (ESC / q / Enter to exit)\n")
		return 0
	}

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
		if prg.wait_exit(sys, 25) {
			break
		}
		tick += 1
		scroll_px += 3
	}
	return 0
}

@(export, link_name="prg_main")
prg_main :: proc "c" (sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> i32 {
	return prg.run(sys, ctx, app_main)
}

package main

import "../../prg"
import "../../../kernel/syscalls"

// Standalone Starfield2.HC — 260-star 3D warp starfield (Q8 fixed-point)

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

app_main :: proc(sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> int {
	if prg.want_help(ctx) {
		sys.print("Usage: starfield\n  3D warp starfield with tinted streaks (ESC / q / Enter to exit)\n")
		return 0
	}

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
		if prg.wait_exit(sys, 25) {
			break
		}
	}
	return 0
}

@(export, link_name="prg_main")
prg_main :: proc "c" (sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> i32 {
	return prg.run(sys, ctx, app_main)
}

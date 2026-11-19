package main

import "../../prg"
import "../../../kernel/syscalls"

// Standalone Spiro.HC — Sacred Geometry Spirograph

app_main :: proc(sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> int {
	if prg.want_help(ctx) {
		sys.print("Usage: spiro\n  Sacred geometry spirograph (ESC / q / Enter to exit)\n")
		return 0
	}

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
		if prg.wait_exit(sys, 12) {
			break
		}
	}
	return 0
}

@(export, link_name="prg_main")
prg_main :: proc "c" (sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> i32 {
	return prg.run(sys, ctx, app_main)
}

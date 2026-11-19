package main

import "../../prg"
import "../../../kernel/syscalls"

// Standalone Matrix.HC — Digital Rain (80x60 grid)

app_main :: proc(sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> int {
	if prg.want_help(ctx) {
		sys.print("Usage: matrix\n  Matrix digital rain (ESC / q / Enter to exit)\n")
		return 0
	}

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
		if prg.wait_exit(sys, 33) {
			break
		}
	}
	return 0
}

@(export, link_name="prg_main")
prg_main :: proc "c" (sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> i32 {
	return prg.run(sys, ctx, app_main)
}

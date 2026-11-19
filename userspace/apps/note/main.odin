package main

import "../../prg"
import "../../../kernel/syscalls"

// Standalone note helper: read or append lines to a FAT32 file from args or piped input.

append_and_save :: proc(sys: ^syscalls.Table, file: string, existing: []u8, extra: []u8, append_nl: bool) -> int {
	add_len := len(extra) + (1 if append_nl else 0)
	combined := make([]u8, len(existing) + add_len)
	pos := 0
	for i := 0; i < len(existing); i += 1 {
		combined[pos] = existing[i]
		pos += 1
	}
	for i := 0; i < len(extra); i += 1 {
		combined[pos] = extra[i]
		pos += 1
	}
	if append_nl {
		combined[pos] = '\n'
	}

	if !sys.write_file(file, combined) {
		sys.print("note: write failed\n")
		return 1
	}

	sys.print("Appended ")
	prg.print_u64(sys, u64(add_len))
	sys.print(" B -> ")
	sys.print(file)
	sys.print("\n")
	return 0
}

app_main :: proc(sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> int {
	if prg.want_help(ctx) {
		sys.print("Usage: note <file> [text...]\n  Read or append text (args or pipe) to a FAT32 file\n")
		return 0
	}
	if ctx == nil || len(ctx.args) < 2 {
		sys.print("Usage: note <file> [text...]\n")
		return 1
	}

	file := ctx.args[1]
	existing, exists := sys.read_file(file)

	if len(ctx.args) >= 3 {
		payload_len := 0
		for i := 2; i < len(ctx.args); i += 1 {
			if i > 2 {
				payload_len += 1
			}
			payload_len += len(ctx.args[i])
		}
		extra := make([]u8, payload_len)
		pos := 0
		for i := 2; i < len(ctx.args); i += 1 {
			if i > 2 {
				extra[pos] = ' '
				pos += 1
			}
			s := ctx.args[i]
			for j := 0; j < len(s); j += 1 {
				extra[pos] = s[j]
				pos += 1
			}
		}
		return append_and_save(sys, file, existing, extra, true)
	}

	if len(ctx.in_buf) > 0 {
		need_nl := ctx.in_buf[len(ctx.in_buf) - 1] != '\n'
		return append_and_save(sys, file, existing, ctx.in_buf, need_nl)
	}

	if !exists {
		sys.print("note: file not found\n")
		return 1
	}
	sys.print_bytes(existing)
	if len(existing) == 0 || existing[len(existing) - 1] != '\n' {
		sys.print("\n")
	}
	return 0
}

@(export, link_name="prg_main")
prg_main :: proc "c" (sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> i32 {
	return prg.run(sys, ctx, app_main)
}

package main

import "../../prg"
import "../../../kernel/syscalls"

// Standalone recursive directory tree viewer backed by FAT32 list_dir syscall.

MAX_TREE_DEPTH :: 8

is_dot_dir :: proc "contextless" (name: string) -> bool {
	return name == "." || name == ".."
}

join_child_path :: proc(parent, child: string) -> string {
	if len(parent) == 0 {
		return child
	}
	need_slash := parent[len(parent) - 1] != '/'
	total := len(parent) + (1 if need_slash else 0) + len(child)
	buf := make([]u8, total)
	pos := 0
	for i := 0; i < len(parent); i += 1 {
		buf[pos] = parent[i]
		pos += 1
	}
	if need_slash {
		buf[pos] = '/'
		pos += 1
	}
	for i := 0; i < len(child); i += 1 {
		buf[pos] = child[i]
		pos += 1
	}
	return string(buf)
}

walk_dir :: proc(sys: ^syscalls.Table, path: string, depth: int) -> bool {
	entries, ok := sys.list_dir(path)
	if !ok {
		if depth == 0 {
			sys.print("tree: directory not found\n")
			return false
		}
		return true
	}
	if depth == 0 {
		sys.print(path)
		sys.print("\n")
	}
	for i := 0; i < len(entries); i += 1 {
		e := &entries[i]
		name := string(e.name[:e.name_len])
		if is_dot_dir(name) {
			continue
		}
		for d := 0; d < depth + 1; d += 1 {
			sys.print("  ")
		}
		if e.is_dir {
			sys.print("[DIR] ")
			sys.print(name)
			sys.print("/\n")
			if depth + 1 < MAX_TREE_DEPTH {
				child := join_child_path(path, name)
				walk_dir(sys, child, depth + 1)
			}
		} else {
			sys.print(name)
			sys.print(" (")
			prg.print_u64(sys, u64(e.size))
			sys.print(" B)\n")
		}
	}
	return true
}

app_main :: proc(sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> int {
	if prg.want_help(ctx) {
		sys.print("Usage: tree [path]\n  Recursively list directories and files on FAT32\n")
		return 0
	}

	target := "."
	if ctx != nil && len(ctx.args) >= 2 {
		target = ctx.args[1]
	}
	if !walk_dir(sys, target, 0) {
		return 1
	}
	return 0
}

@(export, link_name="prg_main")
prg_main :: proc "c" (sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> i32 {
	return prg.run(sys, ctx, app_main)
}

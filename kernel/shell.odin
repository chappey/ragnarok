package kernel

import "base:runtime"

// Unified command interface + pipe-capable shell ('rsh') backed by per-stage PMM Arenas.
// Syntax: cmd arg1 "quoted arg" --flag | cmd2 # comment

SHELL_MAX_LINE   :: 256
SHELL_MAX_STAGES :: 8
SHELL_MAX_ARGS   :: 32
SHELL_MAX_HIST   :: 32
HEX_DUMP_LIMIT   :: 4096

Cmd_Context :: struct {
	args:   []string,
	in_buf: []u8,
	out:    ^Out_Buf,
	arena:  ^Arena,
}

Cmd_Proc :: #type proc(ctx: ^Cmd_Context) -> int

Command :: struct {
	name:    string,
	summary: string,
	usage:   string,
	run:     Cmd_Proc,
}

g_commands := [37]Command{
	{
		name    = "help",
		summary = "List commands or show usage for one command",
		usage   = "help [cmd]",
		run     = cmd_help,
	},
	{
		name    = "history",
		summary = "Show recent command history",
		usage   = "history",
		run     = cmd_history,
	},
	{
		name    = "sys",
		summary = "Show OS, display, input, RAM, and bus summary",
		usage   = "sys",
		run     = cmd_sys,
	},
	{
		name    = "rtc",
		summary = "Read hardware CMOS Real-Time Clock (UTC)",
		usage   = "rtc",
		run     = cmd_rtc,
	},
	{
		name    = "dmesg",
		summary = "Print kernel boot and driver log ring buffer",
		usage   = "dmesg",
		run     = cmd_dmesg,
	},
	{
		name    = "uptime",
		summary = "Show time since boot and calibrated TSC frequency",
		usage   = "uptime",
		run     = cmd_uptime,
	},
	{
		name    = "time",
		summary = "Benchmark a command or pipeline using RDTSC",
		usage   = "time <command...>",
		run     = cmd_time,
	},
	{
		name    = "selftest",
		summary = "Run IDT #BP trap and 1000 Hz PIT IRQ0 tick self-test",
		usage   = "selftest",
		run     = cmd_selftest,
	},
	{
		name    = "clear",
		summary = "Clear the on-screen console (shortcut: Ctrl+L)",
		usage   = "clear",
		run     = cmd_clear,
	},
	{
		name    = "echo",
		summary = "Print arguments separated by spaces",
		usage   = "echo [text...]",
		run     = cmd_echo,
	},
	{
		name    = "ls",
		summary = "List files in current or given FAT32 directory",
		usage   = "ls [path]",
		run     = cmd_ls,
	},
	{
		name    = "cd",
		summary = "Change current FAT32 directory",
		usage   = "cd [path]",
		run     = cmd_cd,
	},
	{
		name    = "pwd",
		summary = "Print current FAT32 working directory",
		usage   = "pwd",
		run     = cmd_pwd,
	},
	{
		name    = "mkdir",
		summary = "Create a FAT32 directory",
		usage   = "mkdir <dir>",
		run     = cmd_mkdir,
	},
	{
		name    = "rmdir",
		summary = "Remove an empty FAT32 directory",
		usage   = "rmdir <dir>",
		run     = cmd_rmdir,
	},
	{
		name    = "read",
		summary = "Print contents of a file from FAT32",
		usage   = "read <file>",
		run     = cmd_read,
	},
	{
		name    = "write",
		summary = "Write text or piped input to a FAT32 8.3 file",
		usage   = "write <file> [text...]",
		run     = cmd_write,
	},
	{
		name    = "copy",
		summary = "Copy a file on FAT32",
		usage   = "copy <src> <dst>",
		run     = cmd_copy,
	},
	{
		name    = "move",
		summary = "Move or rename a file on FAT32",
		usage   = "move <src> <dst>",
		run     = cmd_move,
	},
	{
		name    = "del",
		summary = "Delete a file from FAT32",
		usage   = "del <file>",
		run     = cmd_del,
	},
	{
		name    = "df",
		summary = "Show mounted FAT32 capacity and free space",
		usage   = "df",
		run     = cmd_df,
	},
	{
		name    = "mount",
		summary = "Show current disk or mount FAT32 on block device index",
		usage   = "mount [blk_idx]",
		run     = cmd_mount,
	},
	{
		name    = "exec",
		summary = "Load and execute a standalone .prg binary from FAT32",
		usage   = "exec <file.prg> [args...]",
		run     = cmd_exec,
	},
	{
		name    = "find",
		summary = "Case-insensitive line filter on file or piped input",
		usage   = "find <pattern> [file]",
		run     = cmd_find,
	},
	{
		name    = "head",
		summary = "Print first N lines (default 10) of file or pipe",
		usage   = "head [n] [file]",
		run     = cmd_head,
	},
	{
		name    = "tail",
		summary = "Print last N lines (default 10) of file or pipe",
		usage   = "tail [n] [file]",
		run     = cmd_tail,
	},
	{
		name    = "sort",
		summary = "Sort lines case-insensitively from file or pipe",
		usage   = "sort [file]",
		run     = cmd_sort,
	},
	{
		name    = "count",
		summary = "Count lines, words, and bytes from file or pipe",
		usage   = "count [file]",
		run     = cmd_count,
	},
	{
		name    = "hex",
		summary = "Hex + ASCII dump of a file or piped input",
		usage   = "hex [file]",
		run     = cmd_hex,
	},
	{
		name    = "mem",
		summary = "Show PMM stats and run Arena + DMA self-tests",
		usage   = "mem",
		run     = cmd_mem,
	},
	{
		name    = "pci",
		summary = "List discovered PCI devices",
		usage   = "pci",
		run     = cmd_pci,
	},
	{
		name    = "disks",
		summary = "List AHCI / NVMe block devices",
		usage   = "disks",
		run     = cmd_disks,
	},
	{
		name    = "peek",
		summary = "Hex dump raw physical memory at hex address",
		usage   = "peek <hex_addr> [bytes]",
		run     = cmd_peek,
	},
	{
		name    = "splash",
		summary = "Run animated Ragnarok twilight screen",
		usage   = "splash",
		run     = cmd_splash,
	},
	{
		name    = "theme",
		summary = "Switch 16-color LUT (norse or templeos)",
		usage   = "theme <norse|templeos>",
		run     = cmd_theme,
	},
	{
		name    = "reboot",
		summary = "Reboot machine via i8042 / PCH 0xCF9",
		usage   = "reboot",
		run     = cmd_reboot,
	},
	{
		name    = "halt",
		summary = "Power off (QEMU ACPI) or halt CPU",
		usage   = "halt",
		run     = cmd_halt,
	},
}

// ---------------------------------------------------------------------------
// Shared formatting / parsing helpers
// ---------------------------------------------------------------------------

shell_find_cmd :: proc "contextless" (name: string) -> ^Command {
	for i := 0; i < len(g_commands); i += 1 {
		if g_commands[i].name == name {
			return &g_commands[i]
		}
	}
	return nil
}

ascii_contains_ci :: proc "contextless" (haystack, needle: []u8) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(haystack) < len(needle) {
		return false
	}
	limit := len(haystack) - len(needle)
	for i := 0; i <= limit; i += 1 {
		match := true
		for j := 0; j < len(needle); j += 1 {
			if ascii_upper(haystack[i + j]) != ascii_upper(needle[j]) {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

parse_hex_u64 :: proc "contextless" (s: string) -> (u64, bool) {
	b := transmute([]u8)s
	if len(b) == 0 {
		return 0, false
	}
	i := 0
	if len(b) >= 2 && b[0] == '0' && (b[1] == 'x' || b[1] == 'X') {
		i = 2
	}
	if i >= len(b) {
		return 0, false
	}
	val := u64(0)
	for i < len(b) {
		c := b[i]
		digit: u64
		if c >= '0' && c <= '9' {
			digit = u64(c - '0')
		} else if c >= 'a' && c <= 'f' {
			digit = u64(c - 'a' + 10)
		} else if c >= 'A' && c <= 'F' {
			digit = u64(c - 'A' + 10)
		} else {
			return 0, false
		}
		val = (val << 4) | digit
		i += 1
	}
	return val, true
}

parse_dec_u64 :: proc "contextless" (s: string) -> (u64, bool) {
	b := transmute([]u8)s
	if len(b) == 0 {
		return 0, false
	}
	val := u64(0)
	for i := 0; i < len(b); i += 1 {
		c := b[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		val = val * 10 + u64(c - '0')
	}
	return val, true
}

write_hex32 :: proc "contextless" (ob: ^Out_Buf, val: u32) {
	ob_put_hex16(ob, u16(val >> 16))
	ob_put_hex16(ob, u16(val & 0xFFFF))
}

write_hex_dump :: proc "contextless" (ob: ^Out_Buf, data: []u8, base_addr: u64) {
	if len(data) == 0 {
		return
	}
	wide_addr := (base_addr + u64(len(data)) - 1) > 0xFFFF_FFFF
	for off := 0; off < len(data); off += 16 {
		addr := base_addr + u64(off)
		if wide_addr {
			write_hex32(ob, u32(addr >> 32))
		}
		write_hex32(ob, u32(addr & 0xFFFF_FFFF))
		ob_puts(ob, ": ")

		row_len := len(data) - off
		if row_len > 16 {
			row_len = 16
		}
		for i := 0; i < 16; i += 1 {
			if i < row_len {
				ob_put_hex8(ob, data[off + i])
				ob_putc(ob, ' ')
			} else {
				ob_puts(ob, "   ")
			}
		}

		ob_putc(ob, '|')
		for i := 0; i < row_len; i += 1 {
			c := data[off + i]
			ob_putc(ob, c if (c >= 0x20 && c <= 0x7E) else '.')
		}
		ob_puts(ob, "|\n")
	}
}

// ---------------------------------------------------------------------------
// 17 Unified Shell Commands
// ---------------------------------------------------------------------------

cmd_help :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) >= 2 {
		if c := shell_find_cmd(ctx.args[1]); c != nil {
			ob_puts(ctx.out, "Usage: ")
			ob_puts(ctx.out, c.usage)
			ob_puts(ctx.out, "\n  ")
			ob_puts(ctx.out, c.summary)
			ob_puts(ctx.out, "\n")
			return 0
		}
		if prg_path, ok := prg_resolve_path(ctx.args[1], ctx.arena); ok {
			help_args := [2]string{ctx.args[1], "--help"}
			sub_ctx := Cmd_Context{
				args  = help_args[:],
				out   = ctx.out,
				arena = ctx.arena,
			}
			return prg_exec_file(prg_path, &sub_ctx)
		}
		ob_puts(ctx.out, "help: unknown command '")
		ob_puts(ctx.out, ctx.args[1])
		ob_puts(ctx.out, "'\n")
		return 1
	}

	ob_puts(ctx.out, "Ragnarok commands (pass --help to any command, use | to pipe):\n")
	for i := 0; i < len(g_commands); i += 1 {
		c := &g_commands[i]
		ob_puts(ctx.out, "  ")
		ob_puts(ctx.out, c.name)
		for pad := len(c.name); pad < 10; pad += 1 {
			ob_putc(ctx.out, ' ')
		}
		ob_puts(ctx.out, c.summary)
		ob_putc(ctx.out, '\n')
	}

	if entries, ok := fat32_list_dir(transmute([]u8)string("/BIN"), ctx.arena); ok {
		printed_hdr := false
		for i := 0; i < len(entries); i += 1 {
			e := &entries[i]
			if e.is_dir {
				continue
			}
			name := string(e.name[:e.name_len])
			if !prg_has_ext(name) {
				continue
			}
			if !printed_hdr {
				ob_puts(ctx.out, "Programs in /BIN (run by name or 'exec <path>'):\n")
				printed_hdr = true
			}
			ob_puts(ctx.out, "  ")
			ob_puts(ctx.out, name)
			ob_putc(ctx.out, '\n')
		}
	}
	return 0
}

cmd_history :: proc(ctx: ^Cmd_Context) -> int {
	for i := 0; i < g_hist_count; i += 1 {
		ob_puts(ctx.out, "  ")
		ob_put_u64(ctx.out, u64(i + 1))
		ob_puts(ctx.out, "  ")
		ob_put_bytes(ctx.out, g_history[i][:g_hist_lens[i]])
		ob_putc(ctx.out, '\n')
	}
	return 0
}

cmd_sys :: proc(ctx: ^Cmd_Context) -> int {
	ob_puts(ctx.out, "Ragnarok OS v0.1 | x86_64 Ring-0 | 640x480x16 Logical Canvas\n")
	ob_puts(ctx.out, "GOP:   ")
	ob_put_u64(ctx.out, u64(g_fb.width))
	ob_putc(ctx.out, 'x')
	ob_put_u64(ctx.out, u64(g_fb.height))
	ob_puts(ctx.out, "  (scale=")
	ob_put_u64(ctx.out, u64(g_fb.scale))
	ob_puts(ctx.out, "x, off=")
	ob_put_u64(ctx.out, u64(g_fb.off_x))
	ob_putc(ctx.out, ',')
	ob_put_u64(ctx.out, u64(g_fb.off_y))
	ob_puts(ctx.out, ")\n")

	ob_puts(ctx.out, "Input: USB=")
	if g_xhci.kbd_ready {
		ob_puts(ctx.out, "kbd")
	} else if g_xhci.present {
		ob_puts(ctx.out, "xhci")
	} else {
		ob_puts(ctx.out, "no")
	}
	ob_puts(ctx.out, "  PS/2=")
	ob_puts(ctx.out, "yes" if g_ps2_present else "no")
	ob_puts(ctx.out, "  COM1=")
	ob_puts(ctx.out, "yes" if g_serial_present else "no")
	ob_putc(ctx.out, '\n')

	ob_puts(ctx.out, "HW:    RAM=")
	ob_put_u64(ctx.out, (g_pmm_total_pages * PAGE_SIZE) / (1024 * 1024))
	ob_puts(ctx.out, " MiB (")
	ob_put_u64(ctx.out, (g_pmm_free_pages * PAGE_SIZE) / (1024 * 1024))
	ob_puts(ctx.out, " MiB free)  PCI=")
	ob_put_u64(ctx.out, u64(g_pci_count))
	ob_puts(ctx.out, "  BLK=")
	ob_put_u64(ctx.out, u64(g_block_count))
	ob_putc(ctx.out, '\n')
	return 0
}

cmd_rtc :: proc(ctx: ^Cmd_Context) -> int {
	buf: [19]u8
	n := rtc_format_utc(buf[:])
	ob_put_bytes(ctx.out, buf[:n])
	ob_puts(ctx.out, " UTC\n")
	return 0
}

cmd_dmesg :: proc(ctx: ^Cmd_Context) -> int {
	klog_write(ctx.out)
	return 0
}

cmd_uptime :: proc(ctx: ^Cmd_Context) -> int {
	ms := tsc_ms()
	sec := ms / 1000
	rem := ms % 1000
	ob_puts(ctx.out, "up ")
	ob_put_u64(ctx.out, sec)
	ob_putc(ctx.out, '.')
	ob_putc(ctx.out, u8('0' + (rem / 100) % 10))
	ob_putc(ctx.out, u8('0' + (rem / 10) % 10))
	ob_putc(ctx.out, u8('0' + rem % 10))
	ob_puts(ctx.out, "s | tsc=")
	ob_put_u64(ctx.out, g_tsc_khz / 1000)
	ob_puts(ctx.out, " MHz | pit_ticks=")
	ob_put_u64(ctx.out, arch_get_pit_ticks())
	ob_puts(ctx.out, " (1000 Hz)\n")
	return 0
}

cmd_time :: proc(ctx: ^Cmd_Context) -> int {
	ob_puts(ctx.out, "Usage: time <command...>\n")
	return 1
}

cmd_selftest :: proc(ctx: ^Cmd_Context) -> int {
	g_bp_hit = false
	arch_int3()
	ob_puts(ctx.out, "IDT #BP test: ")
	ob_puts(ctx.out, "PASS\n" if g_bp_hit else "FAIL\n")

	t0 := arch_get_pit_ticks()
	end_us := tsc_us() + 5000
	for tsc_us() < end_us {
		arch_pause()
	}
	t1 := arch_get_pit_ticks()
	ob_puts(ctx.out, "PIT IRQ0 ticks: ")
	ob_put_u64(ctx.out, t1)
	ob_puts(ctx.out, " -> ")
	ob_puts(ctx.out, "PASS\n" if t1 > t0 && t0 > 0 else "FAIL\n")
	return 0 if (g_bp_hit && t1 > t0 && t0 > 0) else 1
}

cmd_clear :: proc(ctx: ^Cmd_Context) -> int {
	con_clear()
	con_flush()
	return 0
}

cmd_echo :: proc(ctx: ^Cmd_Context) -> int {
	for i := 1; i < len(ctx.args); i += 1 {
		if i > 1 {
			ob_putc(ctx.out, ' ')
		}
		ob_puts(ctx.out, ctx.args[i])
	}
	ob_putc(ctx.out, '\n')
	return 0
}

cmd_ls :: proc(ctx: ^Cmd_Context) -> int {
	path: []u8 = nil
	if len(ctx.args) >= 2 {
		path = transmute([]u8)ctx.args[1]
	}
	return 0 if fat32_ls_path(path, ctx.out) else 1
}

cmd_cd :: proc(ctx: ^Cmd_Context) -> int {
	path: []u8 = nil
	if len(ctx.args) >= 2 {
		path = transmute([]u8)ctx.args[1]
	}
	if !fat32_cd(path) {
		ob_puts(ctx.out, "cd: directory not found\n")
		return 1
	}
	return 0
}

cmd_pwd :: proc(ctx: ^Cmd_Context) -> int {
	ob_puts(ctx.out, fat32_pwd())
	ob_putc(ctx.out, '\n')
	return 0
}

cmd_mkdir :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: mkdir <dir>\n")
		return 1
	}
	if !fat32_mkdir(transmute([]u8)ctx.args[1]) {
		ob_puts(ctx.out, "mkdir: failed (exists or invalid 8.3 name)\n")
		return 1
	}
	return 0
}

cmd_rmdir :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: rmdir <dir>\n")
		return 1
	}
	if !fat32_rmdir(transmute([]u8)ctx.args[1]) {
		ob_puts(ctx.out, "rmdir: failed (not empty or not found)\n")
		return 1
	}
	return 0
}

cmd_copy :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 3 {
		ob_puts(ctx.out, "Usage: copy <src> <dst>\n")
		return 1
	}
	data, ok := fat32_read_file(transmute([]u8)ctx.args[1], ctx.arena)
	if !ok {
		ob_puts(ctx.out, "copy: source not found\n")
		return 1
	}
	if !fat32_write_file(transmute([]u8)ctx.args[2], data) {
		ob_puts(ctx.out, "copy: failed writing destination\n")
		return 1
	}
	return 0
}

cmd_move :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 3 {
		ob_puts(ctx.out, "Usage: move <src> <dst>\n")
		return 1
	}
	if ctx.args[1] == ctx.args[2] {
		return 0
	}
	data, ok := fat32_read_file(transmute([]u8)ctx.args[1], ctx.arena)
	if !ok {
		ob_puts(ctx.out, "move: source not found\n")
		return 1
	}
	if !fat32_write_file(transmute([]u8)ctx.args[2], data) {
		ob_puts(ctx.out, "move: failed writing destination\n")
		return 1
	}
	_ = fat32_del_file(transmute([]u8)ctx.args[1])
	return 0
}

cmd_df :: proc(ctx: ^Cmd_Context) -> int {
	fat32_df(ctx.out)
	return 0
}

cmd_mount :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		if !g_fat32.mounted {
			ob_puts(ctx.out, "No FAT32 volume mounted.\n")
			return 0
		}
		ob_puts(ctx.out, "Mounted: [")
		ob_put_u64(ctx.out, u64(g_fat32_dev_idx))
		ob_puts(ctx.out, "] ")
		ob_puts(ctx.out, g_fat32.dev.name)
		ob_puts(ctx.out, " (part_lba=")
		ob_put_u64(ctx.out, g_fat32.part_lba)
		ob_puts(ctx.out, ")\n")
		return 0
	}
	idx, ok := parse_dec_u64(ctx.args[1])
	if !ok || int(idx) >= g_block_count {
		ob_puts(ctx.out, "mount: invalid block device index\n")
		return 1
	}
	if !fat32_mount_dev(int(idx)) {
		ob_puts(ctx.out, "mount: no valid FAT32 volume on device\n")
		return 1
	}
	ob_puts(ctx.out, "Mounted [")
	ob_put_u64(ctx.out, idx)
	ob_puts(ctx.out, "] ")
	ob_puts(ctx.out, g_fat32.dev.name)
	ob_putc(ctx.out, '\n')
	return 0
}

cmd_exec :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: exec <file.prg> [args...]\n")
		return 1
	}
	resolved, ok := prg_resolve_path(ctx.args[1], ctx.arena)
	if !ok {
		ob_puts(ctx.out, "exec: program not found: ")
		ob_puts(ctx.out, ctx.args[1])
		ob_putc(ctx.out, '\n')
		return 1
	}
	sub_ctx := Cmd_Context{
		args   = ctx.args[1:],
		in_buf = ctx.in_buf,
		out    = ctx.out,
		arena  = ctx.arena,
	}
	return prg_exec_file(resolved, &sub_ctx)
}

cmd_read :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: read <file>\n")
		return 1
	}
	data, ok := fat32_read_file(transmute([]u8)ctx.args[1], ctx.arena)
	if !ok {
		ob_puts(ctx.out, "read: file not found\n")
		return 1
	}
	ob_put_bytes(ctx.out, data)
	if len(data) == 0 || data[len(data) - 1] != '\n' {
		ob_putc(ctx.out, '\n')
	}
	return 0
}

cmd_write :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: write <file> [text...]\n")
		return 1
	}
	payload: []u8
	if len(ctx.args) >= 3 {
		tmp: Out_Buf
		ob_init(&tmp, ctx.arena)
		for i := 2; i < len(ctx.args); i += 1 {
			if i > 2 {
				ob_putc(&tmp, ' ')
			}
			ob_puts(&tmp, ctx.args[i])
		}
		ob_putc(&tmp, '\n')
		payload = ob_bytes(&tmp)
	} else {
		payload = ctx.in_buf
	}
	if !fat32_write_file(transmute([]u8)ctx.args[1], payload) {
		ob_puts(ctx.out, "write: failed (use 8.3 name, e.g. NOTE.TXT)\n")
		return 1
	}
	ob_puts(ctx.out, "Wrote ")
	ob_put_u64(ctx.out, u64(len(payload)))
	ob_puts(ctx.out, " B -> ")
	ob_puts(ctx.out, ctx.args[1])
	ob_putc(ctx.out, '\n')
	return 0
}

cmd_del :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: del <file>\n")
		return 1
	}
	if !fat32_del_file(transmute([]u8)ctx.args[1]) {
		ob_puts(ctx.out, "del: file not found\n")
		return 1
	}
	ob_puts(ctx.out, "Deleted ")
	ob_puts(ctx.out, ctx.args[1])
	ob_putc(ctx.out, '\n')
	return 0
}

split_lines_arena :: proc(src: []u8) -> [dynamic][]u8 {
	lines := make([dynamic][]u8)
	start := 0
	for i := 0; i <= len(src); i += 1 {
		if i == len(src) || src[i] == '\n' {
			end := i
			if end > start && src[end - 1] == '\r' {
				end -= 1
			}
			if !(i == len(src) && start == len(src)) {
				append(&lines, src[start:end])
			}
			start = i + 1
		}
	}
	return lines
}

line_cmp_ci :: proc "contextless" (a, b: []u8) -> int {
	n := len(a) if len(a) < len(b) else len(b)
	for i := 0; i < n; i += 1 {
		ca := ascii_upper(a[i])
		cb := ascii_upper(b[i])
		if ca < cb { return -1 }
		if ca > cb { return 1 }
	}
	if len(a) < len(b) { return -1 }
	if len(a) > len(b) { return 1 }
	return 0
}

cmd_head :: proc(ctx: ^Cmd_Context) -> int {
	n := u64(10)
	src := ctx.in_buf
	arg_idx := 1
	if len(ctx.args) >= 2 {
		if parsed, ok := parse_dec_u64(ctx.args[1]); ok {
			n = parsed
			arg_idx = 2
		}
	}
	if arg_idx < len(ctx.args) {
		data, ok := fat32_read_file(transmute([]u8)ctx.args[arg_idx], ctx.arena)
		if !ok {
			ob_puts(ctx.out, "head: file not found\n")
			return 1
		}
		src = data
	}
	lines := split_lines_arena(src)
	limit := int(n)
	if limit > len(lines) { limit = len(lines) }
	for i := 0; i < limit; i += 1 {
		ob_put_bytes(ctx.out, lines[i])
		ob_putc(ctx.out, '\n')
	}
	return 0
}

cmd_tail :: proc(ctx: ^Cmd_Context) -> int {
	n := u64(10)
	src := ctx.in_buf
	arg_idx := 1
	if len(ctx.args) >= 2 {
		if parsed, ok := parse_dec_u64(ctx.args[1]); ok {
			n = parsed
			arg_idx = 2
		}
	}
	if arg_idx < len(ctx.args) {
		data, ok := fat32_read_file(transmute([]u8)ctx.args[arg_idx], ctx.arena)
		if !ok {
			ob_puts(ctx.out, "tail: file not found\n")
			return 1
		}
		src = data
	}
	lines := split_lines_arena(src)
	start := 0
	if len(lines) > int(n) {
		start = len(lines) - int(n)
	}
	for i := start; i < len(lines); i += 1 {
		ob_put_bytes(ctx.out, lines[i])
		ob_putc(ctx.out, '\n')
	}
	return 0
}

cmd_sort :: proc(ctx: ^Cmd_Context) -> int {
	src := ctx.in_buf
	if len(ctx.args) >= 2 {
		data, ok := fat32_read_file(transmute([]u8)ctx.args[1], ctx.arena)
		if !ok {
			ob_puts(ctx.out, "sort: file not found\n")
			return 1
		}
		src = data
	}
	lines := split_lines_arena(src)
	for i := 1; i < len(lines); i += 1 {
		key := lines[i]
		j := i - 1
		for j >= 0 && line_cmp_ci(lines[j], key) > 0 {
			lines[j + 1] = lines[j]
			j -= 1
		}
		lines[j + 1] = key
	}
	for i := 0; i < len(lines); i += 1 {
		ob_put_bytes(ctx.out, lines[i])
		ob_putc(ctx.out, '\n')
	}
	return 0
}

cmd_find :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: find <pattern> [file]\n")
		return 1
	}
	src := ctx.in_buf
	if len(ctx.args) >= 3 {
		data, ok := fat32_read_file(transmute([]u8)ctx.args[2], ctx.arena)
		if !ok {
			ob_puts(ctx.out, "find: file not found\n")
			return 1
		}
		src = data
	}

	pat := transmute([]u8)ctx.args[1]
	start := 0
	for i := 0; i <= len(src); i += 1 {
		if i == len(src) || src[i] == '\n' {
			end := i
			if end > start && src[end - 1] == '\r' {
				end -= 1
			}
			// Do not invent a blank trailing match after a final '\n'
			if !(i == len(src) && start == len(src)) {
				line := src[start:end]
				if ascii_contains_ci(line, pat) {
					ob_put_bytes(ctx.out, line)
					ob_putc(ctx.out, '\n')
				}
			}
			start = i + 1
		}
	}
	return 0
}

cmd_count :: proc(ctx: ^Cmd_Context) -> int {
	src := ctx.in_buf
	if len(ctx.args) >= 2 {
		data, ok := fat32_read_file(transmute([]u8)ctx.args[1], ctx.arena)
		if !ok {
			ob_puts(ctx.out, "count: file not found\n")
			return 1
		}
		src = data
	}

	lines := u64(0)
	words := u64(0)
	in_word := false
	for i := 0; i < len(src); i += 1 {
		c := src[i]
		if c == '\n' {
			lines += 1
		}
		is_ws := (c == ' ' || c == '\t' || c == '\n' || c == '\r')
		if is_ws {
			in_word = false
		} else if !in_word {
			in_word = true
			words += 1
		}
	}
	if len(src) > 0 && src[len(src) - 1] != '\n' {
		lines += 1
	}

	ob_puts(ctx.out, "lines=")
	ob_put_u64(ctx.out, lines)
	ob_puts(ctx.out, " words=")
	ob_put_u64(ctx.out, words)
	ob_puts(ctx.out, " bytes=")
	ob_put_u64(ctx.out, u64(len(src)))
	ob_putc(ctx.out, '\n')
	return 0
}

cmd_hex :: proc(ctx: ^Cmd_Context) -> int {
	src := ctx.in_buf
	if len(ctx.args) >= 2 {
		data, ok := fat32_read_file(transmute([]u8)ctx.args[1], ctx.arena)
		if !ok {
			ob_puts(ctx.out, "hex: file not found\n")
			return 1
		}
		src = data
	}
	view := src
	truncated := false
	if len(view) > HEX_DUMP_LIMIT {
		view = view[:HEX_DUMP_LIMIT]
		truncated = true
	}
	write_hex_dump(ctx.out, view, 0)
	if truncated {
		ob_puts(ctx.out, "... (truncated to 4096 bytes)\n")
	}
	return 0
}

cmd_mem :: proc(ctx: ^Cmd_Context) -> int {
	used := g_pmm_total_pages - g_pmm_free_pages
	ob_puts(ctx.out, "PMM: total=")
	ob_put_u64(ctx.out, (g_pmm_total_pages * PAGE_SIZE) / (1024 * 1024))
	ob_puts(ctx.out, " MiB (")
	ob_put_u64(ctx.out, g_pmm_total_pages)
	ob_puts(ctx.out, " pages), free=")
	ob_put_u64(ctx.out, (g_pmm_free_pages * PAGE_SIZE) / (1024 * 1024))
	ob_puts(ctx.out, " MiB, used=")
	ob_put_u64(ctx.out, used)
	ob_puts(ctx.out, " pages\n")

	// Exercise standard Odin context.allocator (make + append resize) backed by cmd_arena
	slice_data := make([]u64, 128)
	dyn_data := make([dynamic]u64, 0, 8)
	for i := 0; i < 128; i += 1 {
		slice_data[i] = u64(i * 3 + 7)
	}
	for i := 0; i < 32; i += 1 {
		append(&dyn_data, u64(i * 11 + 5))
	}
	arena_ok := len(slice_data) == 128 && slice_data[127] == 127 * 3 + 7 &&
		len(dyn_data) == 32 && dyn_data[31] == 31 * 11 + 5

	ob_puts(ctx.out, "Arena test: ")
	ob_puts(ctx.out, "PASS" if arena_ok else "FAIL")
	ob_puts(ctx.out, " (")
	ob_put_u64(ctx.out, ctx.arena.total_pages)
	ob_puts(ctx.out, " pages, ")
	ob_put_u64(ctx.out, ctx.arena.total_used)
	ob_puts(ctx.out, " B used)\n")

	// Contiguous 4-page DMA alloc/write/free test
	phys := pmm_alloc_contiguous(4)
	if phys != 0 {
		ptr := ([^]u64)(uintptr(phys))
		ptr[0] = 0xDEAD_BEEF_CAFE_BABE
		dma_ok := ptr[0] == 0xDEAD_BEEF_CAFE_BABE
		pmm_free_pages(phys, 4)
		ob_puts(ctx.out, "DMA test (4x4KiB): ")
		ob_put_hex64(ctx.out, phys)
		ob_puts(ctx.out, " -> ")
		ob_puts(ctx.out, "PASS\n" if dma_ok else "FAIL\n")
	} else {
		ob_puts(ctx.out, "DMA test: OOM\n")
	}
	return 0
}

cmd_pci :: proc(ctx: ^Cmd_Context) -> int {
	pci_write_devices(ctx.out)
	return 0
}

cmd_disks :: proc(ctx: ^Cmd_Context) -> int {
	block_write_devices(ctx.out)
	return 0
}

cmd_peek :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: peek <hex_addr> [bytes]\n")
		return 1
	}
	addr, ok := parse_hex_u64(ctx.args[1])
	if !ok || addr == 0 {
		ob_puts(ctx.out, "peek: invalid hex address\n")
		return 1
	}
	n := u64(64)
	if len(ctx.args) >= 3 {
		parsed, dok := parse_dec_u64(ctx.args[2])
		if !dok {
			ob_puts(ctx.out, "peek: invalid byte count\n")
			return 1
		}
		n = parsed
		if n < 1 { n = 1 }
		if n > 512 { n = 512 }
	}
	data := ([^]u8)(uintptr(addr))[:int(n)]
	write_hex_dump(ctx.out, data, addr)
	return 0
}

cmd_splash :: proc(ctx: ^Cmd_Context) -> int {
	run_ragnarok_splash()
	con_flush()
	return 0
}

cmd_theme :: proc(ctx: ^Cmd_Context) -> int {
	if len(ctx.args) < 2 {
		ob_puts(ctx.out, "Usage: theme <norse|templeos>\n")
		return 1
	}
	if ctx.args[1] == "norse" {
		gfx_set_palette(PALETTE_NORSE)
		con_flush()
		ob_puts(ctx.out, "Palette swapped -> Norse dusk LUT.\n")
		return 0
	}
	if ctx.args[1] == "templeos" {
		gfx_set_palette(PALETTE_TEMPLEOS)
		con_flush()
		ob_puts(ctx.out, "Palette swapped -> classic TempleOS 16-color LUT.\n")
		return 0
	}
	ob_puts(ctx.out, "theme: expected 'norse' or 'templeos'\n")
	return 1
}

cmd_reboot :: proc(ctx: ^Cmd_Context) -> int {
	out_puts("Rebooting...\n")
	arch_reboot()
	return 0
}

cmd_halt :: proc(ctx: ^Cmd_Context) -> int {
	out_puts("Powering off...\n")
	acpi_poweroff()
	return 0
}

// ---------------------------------------------------------------------------
// Pipeline parser & execution engine
// ---------------------------------------------------------------------------

shell_dispatch :: proc "contextless" (cmd: ^Command, ctx: ^Cmd_Context) -> int {
	rt_ctx: runtime.Context
	rt_ctx.allocator      = arena_allocator(ctx.arena)
	rt_ctx.temp_allocator = arena_allocator(ctx.arena)
	context = rt_ctx
	return cmd.run(ctx)
}

shell_trim_ws :: proc "contextless" (s: []u8) -> []u8 {
	a := 0
	b := len(s)
	for a < b && (s[a] == ' ' || s[a] == '\t') {
		a += 1
	}
	for b > a && (s[b - 1] == ' ' || s[b - 1] == '\t') {
		b -= 1
	}
	return s[a:b]
}

shell_tokenize :: proc "contextless" (seg: []u8, a: ^Arena, out_args: []string) -> (int, bool) {
	argc := 0
	tok_buf: [SHELL_MAX_LINE]u8
	i := 0
	for i < len(seg) {
		for i < len(seg) && (seg[i] == ' ' || seg[i] == '\t') {
			i += 1
		}
		if i >= len(seg) {
			break
		}
		if argc >= len(out_args) {
			return 0, false
		}
		tlen := 0
		in_quote := false
		for i < len(seg) {
			c := seg[i]
			if !in_quote && (c == ' ' || c == '\t') {
				break
			}
			if c == '"' {
				in_quote = !in_quote
				i += 1
				continue
			}
			if tlen < len(tok_buf) {
				tok_buf[tlen] = c
				tlen += 1
			}
			i += 1
		}
		if in_quote {
			return 0, false
		}
		if tlen == 0 {
			out_args[argc] = ""
		} else {
			mem := ([^]u8)(arena_alloc(a, u64(tlen), 1))
			if mem == nil {
				return 0, false
			}
			for k := 0; k < tlen; k += 1 {
				mem[k] = tok_buf[k]
			}
			out_args[argc] = string(mem[:tlen])
		}
		argc += 1
	}
	return argc, true
}

shell_exec_line :: proc "contextless" (raw_line: []u8) {
	// 1. Strip '#' comments outside double quotes
	eff_len := len(raw_line)
	in_q := false
	for i := 0; i < len(raw_line); i += 1 {
		c := raw_line[i]
		if c == '"' {
			in_q = !in_q
		} else if !in_q && c == '#' {
			eff_len = i
			break
		}
	}
	line := shell_trim_ws(raw_line[:eff_len])
	if len(line) == 0 {
		return
	}

	// Benchmark wrapper: "time <command | pipeline>"
	if len(line) > 5 && line[0] == 't' && line[1] == 'i' && line[2] == 'm' && line[3] == 'e' &&
	   (line[4] == ' ' || line[4] == '\t') {
		rest := shell_trim_ws(line[5:])
		if len(rest) > 0 && !(len(rest) >= 6 && rest[0] == '-' && rest[1] == '-') {
			t0 := arch_rdtsc()
			shell_exec_line(rest)
			dt := arch_rdtsc() - t0
			us := (dt * 1000) / g_tsc_khz if g_tsc_khz > 0 else u64(0)
			con_set_color(COL_LTCYAN, COL_BLACK)
			out_puts("[time] ")
			out_put_u64(us)
			out_puts(" us (")
			out_put_u64(dt)
			out_puts(" cycles)\n")
			con_set_color(COL_LTGRAY, COL_BLACK)
			return
		}
	}

	// 2. Split into pipe stages on '|' outside double quotes
	stages: [SHELL_MAX_STAGES][]u8
	num_stages := 0
	seg_start := 0
	in_q = false
	for i := 0; i <= len(line); i += 1 {
		if i == len(line) || (!in_q && line[i] == '|') {
			seg := shell_trim_ws(line[seg_start:i])
			if len(seg) == 0 {
				con_set_color(COL_LTRED, COL_BLACK)
				out_puts("Syntax error: empty pipe stage\n")
				return
			}
			if num_stages >= SHELL_MAX_STAGES {
				con_set_color(COL_LTRED, COL_BLACK)
				out_puts("Syntax error: too many pipe stages (max 8)\n")
				return
			}
			stages[num_stages] = seg
			num_stages += 1
			seg_start = i + 1
		} else if line[i] == '"' {
			in_q = !in_q
		}
	}
	if in_q {
		con_set_color(COL_LTRED, COL_BLACK)
		out_puts("Syntax error: unclosed quote\n")
		return
	}

	// 3. Execute pipeline stages, each with its own 64 KiB PMM Arena
	prev_arena: Arena
	prev_out: Out_Buf
	has_prev := false

	for s := 0; s < num_stages; s += 1 {
		cur_arena: Arena
		if !arena_init(&cur_arena) {
			if has_prev {
				arena_destroy(&prev_arena)
			}
			con_set_color(COL_LTRED, COL_BLACK)
			out_puts("Out of memory allocating command arena.\n")
			return
		}
		cur_out: Out_Buf
		ob_init(&cur_out, &cur_arena)

		args_buf: [SHELL_MAX_ARGS]string
		argc, tok_ok := shell_tokenize(stages[s], &cur_arena, args_buf[:])
		if !tok_ok || argc == 0 {
			arena_destroy(&cur_arena)
			if has_prev {
				arena_destroy(&prev_arena)
			}
			con_set_color(COL_LTRED, COL_BLACK)
			out_puts("Syntax error.\n")
			return
		}

		cmd := shell_find_cmd(args_buf[0])
		prg_path := ""
		prg_ok   := false
		if cmd == nil {
			prg_path, prg_ok = prg_resolve_path(args_buf[0], &cur_arena)
		}
		if cmd == nil && !prg_ok {
			con_set_color(COL_LTRED, COL_BLACK)
			out_puts("Unknown command: ")
			out_puts(args_buf[0])
			out_puts(" (type 'help')\n")
			arena_destroy(&cur_arena)
			if has_prev {
				arena_destroy(&prev_arena)
			}
			return
		}

		want_help := false
		if cmd != nil && (cmd.name != "exec" || (argc >= 2 && args_buf[1] == "--help")) {
			for i := 1; i < argc; i += 1 {
				if args_buf[i] == "--help" {
					want_help = true
					break
				}
			}
		}

		rc := 0
		if want_help {
			ob_puts(&cur_out, "Usage: ")
			ob_puts(&cur_out, cmd.usage)
			ob_puts(&cur_out, "\n  ")
			ob_puts(&cur_out, cmd.summary)
			ob_putc(&cur_out, '\n')
		} else {
			in_slice: []u8 = nil
			if has_prev {
				in_slice = ob_bytes(&prev_out)
			}
			cmd_ctx := Cmd_Context{
				args   = args_buf[:argc],
				in_buf = in_slice,
				out    = &cur_out,
				arena  = &cur_arena,
			}
			if cmd != nil {
				rc = shell_dispatch(cmd, &cmd_ctx)
			} else {
				rc = prg_exec_file(prg_path, &cmd_ctx)
			}
		}

		if has_prev {
			arena_destroy(&prev_arena)
		}
		prev_arena = cur_arena
		prev_out   = cur_out
		has_prev   = true

		if rc != 0 {
			break
		}
	}

	if has_prev {
		out_put_bytes(ob_bytes(&prev_out))
		arena_destroy(&prev_arena)
	}
}

g_history:    [SHELL_MAX_HIST][SHELL_MAX_LINE]u8
g_hist_lens:  [SHELL_MAX_HIST]int
g_hist_count: int

history_push :: proc "contextless" (line: []u8) {
	if len(line) == 0 {
		return
	}
	if g_hist_count > 0 {
		last_len := g_hist_lens[g_hist_count - 1]
		if last_len == len(line) {
			same := true
			for i := 0; i < last_len; i += 1 {
				if g_history[g_hist_count - 1][i] != line[i] {
					same = false
					break
				}
			}
			if same {
				return
			}
		}
	}
	if g_hist_count == SHELL_MAX_HIST {
		for i := 1; i < SHELL_MAX_HIST; i += 1 {
			g_hist_lens[i - 1] = g_hist_lens[i]
			for j := 0; j < g_hist_lens[i]; j += 1 {
				g_history[i - 1][j] = g_history[i][j]
			}
		}
		g_hist_count -= 1
	}
	idx := g_hist_count
	g_hist_lens[idx] = len(line)
	for i := 0; i < len(line); i += 1 {
		g_history[idx][i] = line[i]
	}
	g_hist_count += 1
}

shell_redraw_line :: proc "contextless" (
	line: []u8,
	n: int,
	cursor: int,
	prev_n: int,
	start_x: i32,
	start_y: ^i32,
	redraw_serial: bool,
) {
	// 1. Update 80x60 on-screen console cleanly without cursor-wrap artifacts
	total := n if n > prev_n else prev_n
	cur_x := start_x
	cur_y := start_y^
	target_x := start_x
	target_y := start_y^

	for i := 0; i <= total; i += 1 {
		if i == cursor {
			target_x = cur_x
			target_y = cur_y
		}
		if i == total {
			break
		}
		ch := line[i] if i < n else u8(' ')
		g_con_cells[cur_y * CON_COLS + cur_x] = Console_Cell{ch, COL_WHITE, COL_BLACK}
		cur_x += 1
		if cur_x >= CON_COLS {
			cur_x = 0
			cur_y += 1
			if cur_y >= CON_ROWS {
				con_scroll()
				start_y^ -= 1
				cur_y -= 1
				if i >= cursor {
					target_y -= 1
				}
			}
		}
	}
	g_con_x = target_x
	g_con_y = target_y
	con_flush()

	// 2. Sync COM1 serial line cleanly
	if redraw_serial && g_serial_present {
		serial_putc('\r')
		serial_puts("ragnarok> ")
		for i := 0; i < n; i += 1 {
			serial_putc(line[i])
		}
		for i := n; i < prev_n; i += 1 {
			serial_putc(' ')
		}
		serial_putc('\r')
		serial_puts("ragnarok> ")
		for i := 0; i < cursor; i += 1 {
			serial_putc(line[i])
		}
	}
}

shell_loop :: proc "contextless" () {
	line:  [SHELL_MAX_LINE]u8
	draft: [SHELL_MAX_LINE]u8
	for {
		con_set_color(COL_LTGREEN, COL_BLACK)
		out_puts("ragnarok> ")
		con_set_color(COL_WHITE, COL_BLACK)
		start_x := g_con_x
		start_y := g_con_y

		n := 0
		cursor := 0
		draft_len := 0
		hist_pos := g_hist_count
		cancelled := false

		for {
			c := input_getc()
			prev_n := n

			if c == '\r' || c == '\n' {
				if cursor != n {
					shell_redraw_line(line[:], n, n, prev_n, start_x, &start_y, false)
				}
				out_puts("\n")
				break
			}

			if c == 0x03 { // Ctrl+C
				out_puts("^C\n")
				cancelled = true
				break
			}

			if c == 0x0C { // Ctrl+L (clear screen, keep current line + cursor)
				con_clear()
				con_set_color(COL_LTGREEN, COL_BLACK)
				prompt := "ragnarok> "
				for i := 0; i < len(prompt); i += 1 {
					con_putc_raw(prompt[i])
				}
				con_set_color(COL_WHITE, COL_BLACK)
				start_x = g_con_x
				start_y = g_con_y
				shell_redraw_line(line[:], n, cursor, 0, start_x, &start_y, true)
				continue
			}

			if c == KEY_LEFT || c == 0x02 { // Left / Ctrl+B
				if cursor > 0 {
					cursor -= 1
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}
			if c == KEY_RIGHT || c == 0x06 { // Right / Ctrl+F
				if cursor < n {
					cursor += 1
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}
			if c == KEY_HOME || c == 0x01 { // Home / Ctrl+A
				if cursor != 0 {
					cursor = 0
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}
			if c == KEY_END || c == 0x05 { // End / Ctrl+E
				if cursor != n {
					cursor = n
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}

			if c == KEY_UP || c == 0x10 { // Up / Ctrl+P
				if hist_pos > 0 {
					if hist_pos == g_hist_count {
						draft_len = n
						for i := 0; i < n; i += 1 {
							draft[i] = line[i]
						}
					}
					hist_pos -= 1
					n = g_hist_lens[hist_pos]
					for i := 0; i < n; i += 1 {
						line[i] = g_history[hist_pos][i]
					}
					cursor = n
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}
			if c == KEY_DOWN || c == 0x0E { // Down / Ctrl+N
				if hist_pos < g_hist_count {
					hist_pos += 1
					if hist_pos == g_hist_count {
						n = draft_len
						for i := 0; i < n; i += 1 {
							line[i] = draft[i]
						}
					} else {
						n = g_hist_lens[hist_pos]
						for i := 0; i < n; i += 1 {
							line[i] = g_history[hist_pos][i]
						}
					}
					cursor = n
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}

			if c == 0x08 || c == 0x7F { // Backspace
				if cursor > 0 {
					if cursor == n {
						n -= 1
						cursor -= 1
						shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, false)
						serial_puts("\b \b")
					} else {
						for i := cursor; i < n; i += 1 {
							line[i - 1] = line[i]
						}
						n -= 1
						cursor -= 1
						shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
					}
				}
				continue
			}

			if c == KEY_DELETE || c == 0x04 { // Delete / Ctrl+D
				if cursor < n {
					for i := cursor + 1; i < n; i += 1 {
						line[i - 1] = line[i]
					}
					n -= 1
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}

			if c == 0x0B { // Ctrl+K (kill to end)
				if cursor < n {
					n = cursor
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}

			if c == 0x15 { // Ctrl+U (kill to start)
				if cursor > 0 {
					rem := n - cursor
					for i := 0; i < rem; i += 1 {
						line[i] = line[cursor + i]
					}
					n = rem
					cursor = 0
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}

			if c == 0x17 { // Ctrl+W (kill previous word)
				if cursor > 0 {
					new_cur := cursor
					for new_cur > 0 && line[new_cur - 1] == ' ' {
						new_cur -= 1
					}
					for new_cur > 0 && line[new_cur - 1] != ' ' {
						new_cur -= 1
					}
					del := cursor - new_cur
					for i := cursor; i < n; i += 1 {
						line[i - del] = line[i]
					}
					n -= del
					cursor = new_cur
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
				continue
			}

			if c >= 0x20 && c < 0x7F && n < len(line) {
				if cursor == n {
					line[n] = c
					n += 1
					cursor += 1
					serial_putc(c)
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, false)
				} else {
					for i := n; i > cursor; i -= 1 {
						line[i] = line[i - 1]
					}
					line[cursor] = c
					n += 1
					cursor += 1
					shell_redraw_line(line[:], n, cursor, prev_n, start_x, &start_y, true)
				}
			}
		}

		if cancelled {
			continue
		}

		history_push(line[:n])
		con_set_color(COL_LTGRAY, COL_BLACK)
		shell_exec_line(line[:n])
	}
}

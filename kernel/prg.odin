package kernel

import "syscalls"

// Relocatable PE32+ (.prg) binary loader and syscall bridge for Ring-0 userspace programs.

PRG_MAX_IMAGE_SIZE :: u64(16 * 1024 * 1024)
PRG_MAX_SECTIONS   :: u64(64)

g_exec_arena:       ^Arena
g_exec_out:         ^Out_Buf
g_exec_used_gfx:    bool
g_exec_changed_pal: bool

g_prg_active_base:     u64
g_prg_active_size:     u64
g_prg_active_name:     [64]u8
g_prg_active_name_len: int

// ---------------------------------------------------------------------------
// Syscall table implementation
// ---------------------------------------------------------------------------

sys_gfx_clear :: proc "contextless" (col: u8) {
	g_exec_used_gfx = true
	gfx_clear(col)
}

sys_gfx_present :: proc "contextless" () {
	g_exec_used_gfx = true
	gfx_present()
}

sys_gfx_set_palette :: proc "contextless" (pal: [16]u32) {
	g_exec_used_gfx    = true
	g_exec_changed_pal = true
	gfx_set_palette(pal)
}

sys_gfx_reset_palette :: proc "contextless" () {
	g_exec_changed_pal = false
	gfx_reset_palette()
}

sys_ticks_ms :: proc "contextless" () -> u64 {
	return arch_get_pit_ticks()
}

sys_print :: proc "contextless" (s: string) {
	if g_exec_out != nil {
		ob_puts(g_exec_out, s)
	} else {
		out_puts(s)
	}
}

sys_print_bytes :: proc "contextless" (b: []u8) {
	if g_exec_out != nil {
		ob_put_bytes(g_exec_out, b)
	} else {
		out_put_bytes(b)
	}
}

sys_alloc :: proc "contextless" (size, align: u64) -> rawptr {
	if g_exec_arena == nil {
		return nil
	}
	return arena_alloc(g_exec_arena, size, align)
}

sys_read_file :: proc "contextless" (path: string) -> ([]u8, bool) {
	if g_exec_arena == nil {
		return nil, false
	}
	return fat32_read_file(transmute([]u8)path, g_exec_arena)
}

sys_write_file :: proc "contextless" (path: string, data: []u8) -> bool {
	return fat32_write_file(transmute([]u8)path, data)
}

sys_list_dir :: proc "contextless" (path: string) -> ([]syscalls.Dir_Entry, bool) {
	if g_exec_arena == nil {
		return nil, false
	}
	return fat32_list_dir(transmute([]u8)path, g_exec_arena)
}

sys_cwd :: proc "contextless" () -> string {
	return fat32_pwd()
}

g_syscalls := syscalls.Table{
	abi_version    = syscalls.SYSCALL_ABI_VERSION,
	clear          = sys_gfx_clear,
	plot           = gfx_plot,
	hline          = gfx_hline,
	line           = gfx_line,
	rect           = gfx_rect,
	disc           = gfx_disc,
	char           = gfx_char,
	text           = gfx_text,
	present        = sys_gfx_present,
	set_palette    = sys_gfx_set_palette,
	reset_palette  = sys_gfx_reset_palette,
	wait_ms_or_key = pit_wait_ms_or_key_char,
	getc           = input_getc,
	ticks_ms       = sys_ticks_ms,
	rng_next       = rng_next,
	isin           = isin,
	icos           = icos,
	print          = sys_print,
	print_bytes    = sys_print_bytes,
	alloc          = sys_alloc,
	read_file      = sys_read_file,
	write_file     = sys_write_file,
	list_dir       = sys_list_dir,
	cwd            = sys_cwd,
}

// ---------------------------------------------------------------------------
// Path resolution helpers
// ---------------------------------------------------------------------------

prg_has_ext :: proc "contextless" (s: string) -> bool {
	b := transmute([]u8)s
	if len(b) < 4 {
		return false
	}
	n := len(b)
	return b[n - 4] == '.' &&
		ascii_upper(b[n - 3]) == 'P' &&
		ascii_upper(b[n - 2]) == 'R' &&
		ascii_upper(b[n - 1]) == 'G'
}

prg_has_slash :: proc "contextless" (s: string) -> bool {
	b := transmute([]u8)s
	for i := 0; i < len(b); i += 1 {
		if b[i] == '/' {
			return true
		}
	}
	return false
}

prg_try_file :: proc "contextless" (path: string) -> bool {
	loc, ok := fat32_resolve_path(transmute([]u8)path)
	return ok && (loc.attr & 0x10) == 0
}

prg_join_upper :: proc "contextless" (prefix, name, suffix: string, a: ^Arena) -> string {
	total := len(prefix) + len(name) + len(suffix)
	mem := ([^]u8)(arena_alloc(a, u64(total), 1))
	if mem == nil {
		return ""
	}
	pos := 0
	for i := 0; i < len(prefix); i += 1 {
		mem[pos] = prefix[i]
		pos += 1
	}
	for i := 0; i < len(name); i += 1 {
		mem[pos] = ascii_upper(name[i])
		pos += 1
	}
	for i := 0; i < len(suffix); i += 1 {
		mem[pos] = suffix[i]
		pos += 1
	}
	return string(mem[:total])
}

prg_resolve_path :: proc "contextless" (cmd_name: string, a: ^Arena) -> (string, bool) {
	if !g_fat32.mounted || len(cmd_name) == 0 || a == nil {
		return "", false
	}
	if prg_has_slash(cmd_name) || prg_has_ext(cmd_name) {
		if prg_try_file(cmd_name) {
			return cmd_name, true
		}
		if !prg_has_ext(cmd_name) {
			with_ext := prg_join_upper("", cmd_name, ".PRG", a)
			if len(with_ext) > 0 && prg_try_file(with_ext) {
				return with_ext, true
			}
		}
		return "", false
	}

	in_bin := prg_join_upper("/BIN/", cmd_name, ".PRG", a)
	if len(in_bin) > 0 && prg_try_file(in_bin) {
		return in_bin, true
	}
	in_cwd := prg_join_upper("", cmd_name, ".PRG", a)
	if len(in_cwd) > 0 && prg_try_file(in_cwd) {
		return in_cwd, true
	}
	return "", false
}

// ---------------------------------------------------------------------------
// PE32+ parser, mapper, and base-relocation engine
// ---------------------------------------------------------------------------

pe_u16 :: proc "contextless" (b: []u8, off: u64) -> u16 {
	return u16(b[off]) | (u16(b[off + 1]) << 8)
}

pe_u32 :: proc "contextless" (b: []u8, off: u64) -> u32 {
	return u32(b[off]) |
		(u32(b[off + 1]) << 8) |
		(u32(b[off + 2]) << 16) |
		(u32(b[off + 3]) << 24)
}

pe_u64 :: proc "contextless" (b: []u8, off: u64) -> u64 {
	return u64(pe_u32(b, off)) | (u64(pe_u32(b, off + 4)) << 32)
}

prg_load_pe :: proc "contextless" (
	file_bytes: []u8,
	out: ^Out_Buf,
) -> (load_base, pages, entry_rva, size_of_image: u64, ok: bool) {
	flen := u64(len(file_bytes))
	if flen < 0x40 || pe_u16(file_bytes, 0) != 0x5A4D {
		ob_puts(out, "exec: invalid MZ signature\n")
		return
	}

	lfanew := u64(pe_u32(file_bytes, 0x3C))
	if lfanew + 4 + 20 + 240 > flen || pe_u32(file_bytes, lfanew) != 0x00004550 {
		ob_puts(out, "exec: invalid PE signature\n")
		return
	}

	coff := lfanew + 4
	if pe_u16(file_bytes, coff + 0) != 0x8664 {
		ob_puts(out, "exec: unsupported machine (expected AMD64)\n")
		return
	}
	num_sections := u64(pe_u16(file_bytes, coff + 2))
	opt_size     := u64(pe_u16(file_bytes, coff + 16))
	if num_sections == 0 || num_sections > PRG_MAX_SECTIONS || opt_size < 240 {
		ob_puts(out, "exec: invalid PE COFF section/optional header count\n")
		return
	}

	opt := coff + 20
	if opt + opt_size + num_sections * 40 > flen {
		ob_puts(out, "exec: truncated PE section table\n")
		return
	}
	if pe_u16(file_bytes, opt + 0) != 0x020B {
		ob_puts(out, "exec: expected PE32+ optional header\n")
		return
	}

	entry_rva       = u64(pe_u32(file_bytes, opt + 16))
	preferred_base := pe_u64(file_bytes, opt + 24)
	size_of_image   = u64(pe_u32(file_bytes, opt + 56))
	size_of_hdrs   := u64(pe_u32(file_bytes, opt + 60))
	num_rva        := u64(pe_u32(file_bytes, opt + 108))
	reloc_rva      := u64(pe_u32(file_bytes, opt + 152)) if num_rva > 5 else u64(0)
	reloc_size     := u64(pe_u32(file_bytes, opt + 156)) if num_rva > 5 else u64(0)

	if size_of_image < PAGE_SIZE || size_of_image > PRG_MAX_IMAGE_SIZE ||
	   entry_rva == 0 || entry_rva >= size_of_image {
		ob_puts(out, "exec: invalid PE image size or entry point\n")
		return
	}

	pages = (size_of_image + PAGE_SIZE - 1) / PAGE_SIZE
	load_base = pmm_alloc_contiguous(pages)
	if load_base == 0 {
		ob_puts(out, "exec: out of PMM memory\n")
		return
	}

	// Copy PE headers into contiguous load buffer
	hdr_copy := size_of_hdrs
	if flen < hdr_copy { hdr_copy = flen }
	if size_of_image < hdr_copy { hdr_copy = size_of_image }
	dst := ([^]u8)(uintptr(load_base))
	for i := u64(0); i < hdr_copy; i += 1 {
		dst[i] = file_bytes[i]
	}

	// Map each PE section (uninitialized tails remain zeroed from PMM)
	sec_base := opt + opt_size
	for s := u64(0); s < num_sections; s += 1 {
		sh := sec_base + s * 40
		virt_size := u64(pe_u32(file_bytes, sh + 8))
		virt_addr := u64(pe_u32(file_bytes, sh + 12))
		raw_size  := u64(pe_u32(file_bytes, sh + 16))
		raw_ptr   := u64(pe_u32(file_bytes, sh + 20))
		if raw_size == 0 || raw_ptr == 0 {
			continue
		}
		copy_len := raw_size
		if virt_size > 0 && virt_size < copy_len {
			copy_len = virt_size
		}
		if raw_ptr + copy_len > flen || virt_addr + copy_len > size_of_image {
			pmm_free_pages(load_base, pages)
			ob_puts(out, "exec: corrupt section bounds\n")
			return 0, 0, 0, 0, false
		}
		sec_dst := ([^]u8)(uintptr(load_base + virt_addr))
		for i := u64(0); i < copy_len; i += 1 {
			sec_dst[i] = file_bytes[raw_ptr + i]
		}
	}

	// Apply PE32+ base relocations using unsigned mod-2^64 delta
	delta := load_base - preferred_base
	if delta != 0 && reloc_size > 0 {
		if reloc_rva + reloc_size > size_of_image {
			pmm_free_pages(load_base, pages)
			ob_puts(out, "exec: corrupt relocation directory\n")
			return 0, 0, 0, 0, false
		}
		off := u64(0)
		for off + 8 <= reloc_size {
			blk_addr := load_base + reloc_rva + off
			page_rva := u64((^u32)(uintptr(blk_addr))^)
			blk_size := u64((^u32)(uintptr(blk_addr + 4))^)
			if blk_size < 8 || (blk_size & 1) != 0 || off + blk_size > reloc_size {
				pmm_free_pages(load_base, pages)
				ob_puts(out, "exec: malformed relocation block\n")
				return 0, 0, 0, 0, false
			}
			count := (blk_size - 8) / 2
			for k := u64(0); k < count; k += 1 {
				ent   := (^u16)(uintptr(blk_addr + 8 + k * 2))^
				rtype := ent >> 12
				roff  := u64(ent & 0x0FFF)
				if rtype == 0 {
					continue
				}
				if rtype == 10 {
					trva := page_rva + roff
					if trva + 8 > size_of_image {
						pmm_free_pages(load_base, pages)
						ob_puts(out, "exec: out-of-bounds relocation target\n")
						return 0, 0, 0, 0, false
					}
					slot := (^u64)(uintptr(load_base + trva))
					slot^ = slot^ + delta
				} else {
					pmm_free_pages(load_base, pages)
					ob_puts(out, "exec: unsupported relocation type\n")
					return 0, 0, 0, 0, false
				}
			}
			off += blk_size
		}
	}

	ok = true
	return
}

prg_exec_file :: proc "contextless" (path: string, ctx: ^Cmd_Context) -> int {
	file_bytes, read_ok := fat32_read_file(transmute([]u8)path, ctx.arena)
	if !read_ok {
		ob_puts(ctx.out, "exec: cannot read file: ")
		ob_puts(ctx.out, path)
		ob_putc(ctx.out, '\n')
		return 1
	}

	load_base, pages, entry_rva, image_size, load_ok := prg_load_pe(file_bytes, ctx.out)
	if !load_ok {
		return 1
	}

	// Preserve nested execution state (e.g., if a .prg or subshell invokes another .prg)
	prev_arena       := g_exec_arena
	prev_out         := g_exec_out
	prev_used_gfx    := g_exec_used_gfx
	prev_changed_pal := g_exec_changed_pal
	prev_base        := g_prg_active_base
	prev_size        := g_prg_active_size
	prev_name        := g_prg_active_name
	prev_name_len    := g_prg_active_name_len

	g_exec_arena       = ctx.arena
	g_exec_out         = ctx.out
	g_exec_used_gfx    = false
	g_exec_changed_pal = false
	g_prg_active_base  = load_base
	g_prg_active_size  = image_size

	n := len(path)
	if n > len(g_prg_active_name) { n = len(g_prg_active_name) }
	for i := 0; i < n; i += 1 {
		g_prg_active_name[i] = path[i]
	}
	g_prg_active_name_len = n

	prg_ctx := syscalls.Cmd_Context{
		args   = ctx.args,
		in_buf = ctx.in_buf,
	}
	entry := (syscalls.Prg_Entry)(rawptr(uintptr(load_base + entry_rva)))
	rc := int(entry(&g_syscalls, &prg_ctx))

	used_gfx    := g_exec_used_gfx
	changed_pal := g_exec_changed_pal

	g_exec_arena          = prev_arena
	g_exec_out            = prev_out
	g_exec_used_gfx       = prev_used_gfx
	g_exec_changed_pal    = prev_changed_pal
	g_prg_active_base     = prev_base
	g_prg_active_size     = prev_size
	g_prg_active_name     = prev_name
	g_prg_active_name_len = prev_name_len

	pmm_free_pages(load_base, pages)

	if changed_pal {
		gfx_reset_palette()
	}
	if used_gfx {
		con_flush()
	}
	return rc
}

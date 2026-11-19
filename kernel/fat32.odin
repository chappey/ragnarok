package kernel

// GPT / MBR / Superfloppy FAT32 reader built on top of Block_Device.
// Works seamlessly with AHCI SATA drives, NVMe SSDs, and UEFI ESP images.

FAT32_FS :: struct {
	dev:                 ^Block_Device,
	mounted:             bool,
	part_lba:            u64,
	bytes_per_sector:    u32,
	sectors_per_cluster: u32,
	num_fats:            u32,
	fat_size:            u32,
	fat_lba:             u64,
	data_lba:            u64,
	root_cluster:        u32,
}

// 3-character file extension conventions for Ragnarök
File_Kind :: enum {
	Unknown,
	Dir,
	Program, // .prg — native Ring-0 executable
	Script,  // .rsh — Ragnarök shell script
	Text,    // .txt — plain text
	Config,  // .cfg — configuration
	Palette, // .pal — 16-color LUT (64 bytes)
	Font,    // .fnt — bitmap font
	Image,   // .img — disk / sprite image
	Binary,  // .bin — raw binary blob
}

g_fat32:      FAT32_FS
g_fat_secbuf: [4096]u8

fat32_read_u16 :: proc "contextless" (b: []u8, off: int) -> u16 {
	return u16(b[off]) | (u16(b[off + 1]) << 8)
}

fat32_read_u32 :: proc "contextless" (b: []u8, off: int) -> u32 {
	return u32(b[off]) |
		(u32(b[off + 1]) << 8) |
		(u32(b[off + 2]) << 16) |
		(u32(b[off + 3]) << 24)
}

fat32_read_u64 :: proc "contextless" (b: []u8, off: int) -> u64 {
	return u64(fat32_read_u32(b, off)) | (u64(fat32_read_u32(b, off + 4)) << 32)
}

fat32_try_bpb :: proc "contextless" (dev: ^Block_Device, part_lba: u64) -> bool {
	if !block_read(dev, part_lba, 1, &g_fat_secbuf[0]) {
		return false
	}
	b := g_fat_secbuf[:512]
	if b[510] != 0x55 || b[511] != 0xAA {
		return false
	}
	bps := u32(fat32_read_u16(b, 11))
	spc := u32(b[13])
	rsv := u32(fat32_read_u16(b, 14))
	nf  := u32(b[16])
	f16 := u32(fat32_read_u16(b, 22))
	f32 := fat32_read_u32(b, 36)
	rc  := fat32_read_u32(b, 44)

	if bps != 512 || spc == 0 || rsv == 0 || nf == 0 || f16 != 0 || f32 == 0 || rc < 2 {
		return false
	}

	g_fat32 = FAT32_FS{
		dev                 = dev,
		mounted             = true,
		part_lba            = part_lba,
		bytes_per_sector    = bps,
		sectors_per_cluster = spc,
		num_fats            = nf,
		fat_size            = f32,
		fat_lba             = part_lba + u64(rsv),
		data_lba            = part_lba + u64(rsv) + u64(nf * f32),
		root_cluster        = rc,
	}
	return true
}

fat32_try_dev :: proc "contextless" (dev: ^Block_Device) -> bool {
	if dev == nil || dev.block_size != 512 {
		return false
	}

	// 1. Check GPT header at LBA 1 ("EFI PART")
	if block_read(dev, 1, 1, &g_fat_secbuf[0]) {
		b := g_fat_secbuf[:512]
		if b[0] == 'E' && b[1] == 'F' && b[2] == 'I' && b[3] == ' ' &&
		   b[4] == 'P' && b[5] == 'A' && b[6] == 'R' && b[7] == 'T' {
			part_lba_tbl := fat32_read_u64(b, 72)
			num_entries  := fat32_read_u32(b, 80)
			entry_size   := fat32_read_u32(b, 84)
			if entry_size == 128 && num_entries > 0 {
				if block_read(dev, part_lba_tbl, 1, &g_fat_secbuf[0]) {
					max_e := num_entries if num_entries < 4 else 4
					for e := u32(0); e < max_e; e += 1 {
						off := int(e * 128)
						first_lba := fat32_read_u64(g_fat_secbuf[:512], off + 32)
						if first_lba != 0 && fat32_try_bpb(dev, first_lba) {
							return true
						}
					}
				}
			}
		}
	}

	// 2. Check MBR partition table at LBA 0
	if block_read(dev, 0, 1, &g_fat_secbuf[0]) {
		b := g_fat_secbuf[:512]
		if b[510] == 0x55 && b[511] == 0xAA {
			for p := 0; p < 4; p += 1 {
				off := 446 + p * 16
				ptype := b[off + 4]
				start := u64(fat32_read_u32(b, off + 8))
				if ptype != 0 && ptype != 0xEE && start != 0 {
					if fat32_try_bpb(dev, start) {
						return true
					}
				}
			}
		}
	}

	// 3. Superfloppy (unpartitioned FAT32 starting at LBA 0)
	return fat32_try_bpb(dev, 0)
}

fat32_mount_first :: proc "contextless" () -> bool {
	g_fat32.mounted = false
	for i := 0; i < g_block_count; i += 1 {
		if fat32_try_dev(&g_block_devs[i]) {
			return true
		}
	}
	return false
}

fat32_cluster_to_lba :: proc "contextless" (cluster: u32) -> u64 {
	return g_fat32.data_lba + u64(cluster - 2) * u64(g_fat32.sectors_per_cluster)
}

fat32_next_cluster :: proc "contextless" (cluster: u32) -> u32 {
	fat_off := u64(cluster) * 4
	fat_sec := g_fat32.fat_lba + fat_off / 512
	ent_off := int(fat_off % 512)
	if !block_read(g_fat32.dev, fat_sec, 1, &g_fat_secbuf[0]) {
		return 0x0FFF_FFFF
	}
	return fat32_read_u32(g_fat_secbuf[:512], ent_off) & 0x0FFF_FFFF
}

fat32_format_83 :: proc "contextless" (raw: []u8, out: []u8) -> int {
	n := 0
	for i := 0; i < 8; i += 1 {
		if raw[i] != ' ' {
			out[n] = raw[i]
			n += 1
		}
	}
	has_ext := false
	for i := 8; i < 11; i += 1 {
		if raw[i] != ' ' {
			has_ext = true
			break
		}
	}
	if has_ext {
		out[n] = '.'
		n += 1
		for i := 8; i < 11; i += 1 {
			if raw[i] != ' ' {
				out[n] = raw[i]
				n += 1
			}
		}
	}
	return n
}

ascii_upper :: proc "contextless" (c: u8) -> u8 {
	if c >= 'a' && c <= 'z' {
		return c - 32
	}
	return c
}

fat32_name_eq :: proc "contextless" (a: []u8, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		if ascii_upper(a[i]) != ascii_upper(b[i]) {
			return false
		}
	}
	return true
}

fat32_write_u16 :: proc "contextless" (b: []u8, off: int, v: u16) {
	b[off]     = u8(v & 0xFF)
	b[off + 1] = u8((v >> 8) & 0xFF)
}

fat32_write_u32 :: proc "contextless" (b: []u8, off: int, v: u32) {
	b[off]     = u8(v & 0xFF)
	b[off + 1] = u8((v >> 8) & 0xFF)
	b[off + 2] = u8((v >> 16) & 0xFF)
	b[off + 3] = u8((v >> 24) & 0xFF)
}

fat32_ext_kind :: proc "contextless" (raw83: []u8, attr: u8) -> (File_Kind, string) {
	if (attr & 0x10) != 0 {
		return .Dir, "[DIR]"
	}
	e0 := ascii_upper(raw83[8])
	e1 := ascii_upper(raw83[9])
	e2 := ascii_upper(raw83[10])
	if e0 == 'P' && e1 == 'R' && e2 == 'G' { return .Program, "[PRG]" }
	if e0 == 'R' && e1 == 'S' && e2 == 'H' { return .Script,  "[RSH]" }
	if e0 == 'T' && e1 == 'X' && e2 == 'T' { return .Text,    "[TXT]" }
	if e0 == 'C' && e1 == 'F' && e2 == 'G' { return .Config,  "[CFG]" }
	if e0 == 'P' && e1 == 'A' && e2 == 'L' { return .Palette, "[PAL]" }
	if e0 == 'F' && e1 == 'N' && e2 == 'T' { return .Font,    "[FNT]" }
	if e0 == 'I' && e1 == 'M' && e2 == 'G' { return .Image,   "[IMG]" }
	if e0 == 'B' && e1 == 'I' && e2 == 'N' { return .Binary,  "[BIN]" }
	return .Unknown, "     "
}

fat32_ls_buf :: proc "contextless" (ob: ^Out_Buf) {
	if !g_fat32.mounted {
		ob_puts(ob, "No FAT32 volume mounted.\n")
		return
	}
	ob_puts(ob, "FAT32 / (dev=")
	ob_puts(ob, g_fat32.dev.name)
	ob_puts(ob, " part_lba=")
	ob_put_u64(ob, g_fat32.part_lba)
	ob_puts(ob, "):\n")

	cl := g_fat32.root_cluster
	name_buf: [16]u8
	for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					return
				}
				if ent[0] == 0xE5 {
					continue
				}
				attr := ent[11]
				if attr == 0x0F || (attr & 0x08) != 0 { // LFN or Volume ID
					continue
				}
				nlen := fat32_format_83(ent[:11], name_buf[:])
				_, tag := fat32_ext_kind(ent[:11], attr)
				ob_puts(ob, "  ")
				ob_puts(ob, tag)
				ob_putc(ob, ' ')
				ob_put_bytes(ob, name_buf[:nlen])
				for k := nlen; k < 15; k += 1 {
					ob_putc(ob, ' ')
				}
				if (attr & 0x10) != 0 {
					ob_puts(ob, "<DIR>\n")
				} else {
					sz := fat32_read_u32(ent, 28)
					ob_put_u64(ob, u64(sz))
					ob_puts(ob, " B\n")
				}
			}
		}
		cl = fat32_next_cluster(cl)
	}
}

fat32_read_file :: proc "contextless" (target: []u8, a: ^Arena) -> ([]u8, bool) {
	if !g_fat32.mounted {
		return nil, false
	}

	cl := g_fat32.root_cluster
	file_cl := u32(0)
	file_sz := u32(0)
	found   := false
	name_buf: [16]u8

	search: for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				break search
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					break search
				}
				if ent[0] == 0xE5 || ent[11] == 0x0F || (ent[11] & 0x18) != 0 {
					continue
				}
				nlen := fat32_format_83(ent[:11], name_buf[:])
				if fat32_name_eq(name_buf[:nlen], target) {
					hi := u32(fat32_read_u16(ent, 20))
					lo := u32(fat32_read_u16(ent, 26))
					file_cl = (hi << 16) | lo
					file_sz = fat32_read_u32(ent, 28)
					found = true
					break search
				}
			}
		}
		cl = fat32_next_cluster(cl)
	}

	if !found {
		return nil, false
	}
	if file_sz == 0 {
		return nil, true
	}

	raw := arena_alloc(a, u64(file_sz), 1)
	if raw == nil {
		return nil, false
	}
	dst := ([^]u8)(raw)

	rem := file_sz
	cur := file_cl
	off := u32(0)
	for rem > 0 && cur >= 2 && cur < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cur)
		for s := u32(0); s < g_fat32.sectors_per_cluster && rem > 0; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return nil, false
			}
			n := rem if rem < 512 else 512
			for i := u32(0); i < n; i += 1 {
				dst[off + i] = g_fat_secbuf[i]
			}
			off += n
			rem -= n
		}
		cur = fat32_next_cluster(cur)
	}
	return dst[:off], true
}

fat32_ls :: proc "contextless" () {
	if !g_fat32.mounted {
		out_puts("No FAT32 volume mounted.\n")
		return
	}
	out_puts("FAT32 / (dev=")
	out_puts(g_fat32.dev.name)
	out_puts(" part_lba=")
	out_put_u64(g_fat32.part_lba)
	out_puts("):\n")

	cl := g_fat32.root_cluster
	name_buf: [16]u8
	for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					return
				}
				if ent[0] == 0xE5 {
					continue
				}
				attr := ent[11]
				if attr == 0x0F || (attr & 0x08) != 0 { // LFN or Volume ID
					continue
				}
				nlen := fat32_format_83(ent[:11], name_buf[:])
				out_puts("  ")
				for k := 0; k < nlen; k += 1 {
					out_putc(name_buf[k])
				}
				for k := nlen; k < 16; k += 1 {
					out_putc(' ')
				}
				if (attr & 0x10) != 0 {
					out_puts("<DIR>\n")
				} else {
					sz := fat32_read_u32(ent, 28)
					out_put_u64(u64(sz))
					out_puts(" B\n")
				}
			}
		}
		cl = fat32_next_cluster(cl)
	}
}

fat32_cat :: proc "contextless" (target: []u8) {
	if !g_fat32.mounted {
		out_puts("No FAT32 volume mounted.\n")
		return
	}

	// Find entry in root directory
	cl := g_fat32.root_cluster
	file_cl := u32(0)
	file_sz := u32(0)
	found   := false
	name_buf: [16]u8

	search: for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				break search
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					break search
				}
				if ent[0] == 0xE5 || ent[11] == 0x0F || (ent[11] & 0x18) != 0 {
					continue
				}
				nlen := fat32_format_83(ent[:11], name_buf[:])
				if fat32_name_eq(name_buf[:nlen], target) {
					hi := u32(fat32_read_u16(ent, 20))
					lo := u32(fat32_read_u16(ent, 26))
					file_cl = (hi << 16) | lo
					file_sz = fat32_read_u32(ent, 28)
					found = true
					break search
				}
			}
		}
		cl = fat32_next_cluster(cl)
	}

	if !found {
		out_puts("File not found.\n")
		return
	}

	rem := file_sz
	cur := file_cl
	for rem > 0 && cur >= 2 && cur < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cur)
		for s := u32(0); s < g_fat32.sectors_per_cluster && rem > 0; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return
			}
			n := rem if rem < 512 else 512
			for i := u32(0); i < n; i += 1 {
				out_putc(g_fat_secbuf[i])
			}
			rem -= n
		}
		cur = fat32_next_cluster(cur)
	}
	out_puts("\n")
}

fat32_parse_83 :: proc "contextless" (name: []u8, out: []u8) -> bool {
	if len(name) == 0 || len(out) < 11 {
		return false
	}
	for i := 0; i < 11; i += 1 {
		out[i] = ' '
	}
	base_len := 0
	ext_len  := 0
	in_ext   := false
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		if c == '.' {
			if in_ext || base_len == 0 {
				return false
			}
			in_ext = true
			continue
		}
		if c <= ' ' || c == '/' || c == '\\' {
			return false
		}
		uc := ascii_upper(c)
		if !in_ext {
			if base_len >= 8 { return false }
			out[base_len] = uc
			base_len += 1
		} else {
			if ext_len >= 3 { return false }
			out[8 + ext_len] = uc
			ext_len += 1
		}
	}
	return base_len > 0
}

fat32_set_cluster :: proc "contextless" (cluster: u32, val: u32) -> bool {
	fat_off := u64(cluster) * 4
	sec_idx := fat_off / 512
	ent_off := int(fat_off % 512)
	for f := u32(0); f < g_fat32.num_fats; f += 1 {
		lba := g_fat32.fat_lba + u64(f) * u64(g_fat32.fat_size) + sec_idx
		if !block_read(g_fat32.dev, lba, 1, &g_fat_secbuf[0]) {
			return false
		}
		cur := fat32_read_u32(g_fat_secbuf[:512], ent_off)
		fat32_write_u32(g_fat_secbuf[:512], ent_off, (cur & 0xF000_0000) | (val & 0x0FFF_FFFF))
		if !block_write(g_fat32.dev, lba, 1, &g_fat_secbuf[0]) {
			return false
		}
	}
	return true
}

fat32_free_chain :: proc "contextless" (start: u32) {
	cur := start
	for cur >= 2 && cur < 0x0FFF_FFF8 {
		next := fat32_next_cluster(cur)
		_ = fat32_set_cluster(cur, 0)
		cur = next
	}
}

fat32_alloc_cluster :: proc "contextless" () -> u32 {
	for s := u32(0); s < g_fat32.fat_size; s += 1 {
		if !block_read(g_fat32.dev, g_fat32.fat_lba + u64(s), 1, &g_fat_secbuf[0]) {
			return 0
		}
		for e := 0; e < 128; e += 1 {
			cl := s * 128 + u32(e)
			if cl < 2 {
				continue
			}
			val := fat32_read_u32(g_fat_secbuf[:512], e * 4) & 0x0FFF_FFFF
			if val == 0 {
				if !fat32_set_cluster(cl, 0x0FFF_FFFF) {
					return 0
				}
				return cl
			}
		}
	}
	return 0
}

fat32_write_file :: proc "contextless" (name: []u8, data: []u8) -> bool {
	if !g_fat32.mounted {
		return false
	}
	raw83: [11]u8
	if !fat32_parse_83(name, raw83[:]) {
		return false
	}

	// 1. Locate existing entry or first free root directory slot
	cl := g_fat32.root_cluster
	found_lba := u64(0)
	found_off := -1
	free_lba  := u64(0)
	free_off  := -1
	old_cl    := u32(0)
	name_buf: [16]u8

	scan: for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			lba := base_lba + u64(s)
			if !block_read(g_fat32.dev, lba, 1, &g_fat_secbuf[0]) {
				return false
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 || ent[0] == 0xE5 {
					if free_off < 0 {
						free_lba = lba
						free_off = e
					}
					if ent[0] == 0x00 {
						break scan
					}
					continue
				}
				attr := ent[11]
				if attr == 0x0F || (attr & 0x08) != 0 {
					continue
				}
				nlen := fat32_format_83(ent[:11], name_buf[:])
				if fat32_name_eq(name_buf[:nlen], name) {
					if (attr & 0x10) != 0 { // Refuse overwriting a directory
						return false
					}
					found_lba = lba
					found_off = e
					old_cl = (u32(fat32_read_u16(ent, 20)) << 16) | u32(fat32_read_u16(ent, 26))
					break scan
				}
			}
		}
		cl = fat32_next_cluster(cl)
	}

	slot_lba := found_lba if found_off >= 0 else free_lba
	slot_off := found_off if found_off >= 0 else free_off
	if slot_off < 0 {
		return false
	}

	if old_cl >= 2 {
		fat32_free_chain(old_cl)
	}

	// 2. Allocate clusters & write file payload
	first_cl := u32(0)
	prev_cl  := u32(0)
	off      := 0
	for off < len(data) {
		new_cl := fat32_alloc_cluster()
		if new_cl == 0 {
			if first_cl >= 2 {
				fat32_free_chain(first_cl)
			}
			return false
		}
		if first_cl == 0 {
			first_cl = new_cl
		} else {
			_ = fat32_set_cluster(prev_cl, new_cl)
		}
		prev_cl = new_cl

		base_lba := fat32_cluster_to_lba(new_cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			for i := 0; i < 512; i += 1 {
				g_fat_secbuf[i] = 0
			}
			rem := len(data) - off
			n := rem if rem < 512 else 512
			for i := 0; i < n; i += 1 {
				g_fat_secbuf[i] = data[off + i]
			}
			if !block_write(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return false
			}
			off += n
		}
	}

	// 3. Write 32-byte directory entry
	if !block_read(g_fat32.dev, slot_lba, 1, &g_fat_secbuf[0]) {
		return false
	}
	ent := g_fat_secbuf[slot_off : slot_off + 32]
	for i := 0; i < 32; i += 1 {
		ent[i] = 0
	}
	for i := 0; i < 11; i += 1 {
		ent[i] = raw83[i]
	}
	ent[11] = 0x20 // Archive attribute
	fat32_write_u16(ent, 20, u16((first_cl >> 16) & 0xFFFF))
	fat32_write_u16(ent, 26, u16(first_cl & 0xFFFF))
	fat32_write_u32(ent, 28, u32(len(data)))
	return block_write(g_fat32.dev, slot_lba, 1, &g_fat_secbuf[0])
}

fat32_del_file :: proc "contextless" (name: []u8) -> bool {
	if !g_fat32.mounted {
		return false
	}
	cl := g_fat32.root_cluster
	name_buf: [16]u8

	for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			lba := base_lba + u64(s)
			if !block_read(g_fat32.dev, lba, 1, &g_fat_secbuf[0]) {
				return false
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					return false
				}
				if ent[0] == 0xE5 || ent[11] == 0x0F || (ent[11] & 0x18) != 0 {
					continue
				}
				nlen := fat32_format_83(ent[:11], name_buf[:])
				if fat32_name_eq(name_buf[:nlen], name) {
					first_cl := (u32(fat32_read_u16(ent, 20)) << 16) | u32(fat32_read_u16(ent, 26))
					ent[0] = 0xE5
					if !block_write(g_fat32.dev, lba, 1, &g_fat_secbuf[0]) {
						return false
					}
					if first_cl >= 2 {
						fat32_free_chain(first_cl)
					}
					return true
				}
			}
		}
		cl = fat32_next_cluster(cl)
	}
	return false
}

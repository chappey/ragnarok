package kernel

import "syscalls"

// GPT / MBR / Superfloppy FAT32 driver built on top of Block_Device.
// Supports subdirectories, path resolution (/, ., ..), LFN + 8.3 reads,
// directory cluster growth, write/del/mkdir/rmdir/copy/move, and df.

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
	total_clusters:      u32,
	cwd_cluster:         u32,
	cwd_path:            [256]u8,
	cwd_len:             int,
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

FAT32_Entry_Loc :: struct {
	dir_cluster: u32,
	lba:         u64,
	off:         int,
	raw83:       [11]u8,
	attr:        u8,
	first_cl:    u32,
	size:        u32,
	is_root:     bool,
}

g_fat32:         FAT32_FS
g_fat32_dev_idx: int = -1
g_fat_secbuf:    [4096]u8

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

	tot16 := u32(fat32_read_u16(b, 19))
	tot_sec := tot16 if tot16 != 0 else fat32_read_u32(b, 32)
	data_start_rel := rsv + nf * f32
	tot_cl := u32(0)
	if tot_sec > data_start_rel {
		tot_cl = (tot_sec - data_start_rel) / spc
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
		data_lba            = part_lba + u64(data_start_rel),
		root_cluster        = rc,
		total_clusters      = tot_cl,
		cwd_cluster         = rc,
		cwd_len             = 1,
	}
	g_fat32.cwd_path[0] = '/'
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

fat32_mount_dev :: proc "contextless" (idx: int) -> bool {
	if idx < 0 || idx >= g_block_count {
		return false
	}
	saved := g_fat32
	if fat32_try_dev(&g_block_devs[idx]) {
		g_fat32_dev_idx = idx
		return true
	}
	g_fat32 = saved
	return false
}

fat32_mount_first :: proc "contextless" () -> bool {
	g_fat32.mounted = false
	g_fat32_dev_idx = -1
	for i := 0; i < g_block_count; i += 1 {
		if fat32_try_dev(&g_block_devs[i]) {
			g_fat32_dev_idx = i
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
	max_cl := g_fat32.total_clusters + 2
	if max_cl < 3 {
		max_cl = g_fat32.fat_size * 128
	}
	for s := u32(0); s < g_fat32.fat_size; s += 1 {
		if !block_read(g_fat32.dev, g_fat32.fat_lba + u64(s), 1, &g_fat_secbuf[0]) {
			return 0
		}
		for e := 0; e < 128; e += 1 {
			cl := s * 128 + u32(e)
			if cl < 2 { continue }
			if cl >= max_cl { return 0 }
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

fat32_zero_cluster :: proc "contextless" (cl: u32) -> bool {
	for i := 0; i < 512; i += 1 {
		g_fat_secbuf[i] = 0
	}
	base_lba := fat32_cluster_to_lba(cl)
	for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
		if !block_write(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
			return false
		}
	}
	return true
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

fat32_83_checksum :: proc "contextless" (raw83: []u8) -> u8 {
	sum := u8(0)
	for i := 0; i < 11; i += 1 {
		sum = ((sum & 1) << 7) + (sum >> 1) + raw83[i]
	}
	return sum
}

fat32_lfn_extract :: proc "contextless" (ent: []u8, lfn: []u8, lfn_len: ^int) {
	seq := int(ent[0] & 0x1F)
	if seq < 1 || seq > 20 {
		return
	}
	if (ent[0] & 0x40) != 0 {
		for i := 0; i < len(lfn); i += 1 {
			lfn[i] = 0
		}
		lfn_len^ = 0
	}
	offs := [13]int{1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30}
	base := (seq - 1) * 13
	for i := 0; i < 13; i += 1 {
		pos := base + i
		if pos >= len(lfn) { break }
		lo := ent[offs[i]]
		hi := ent[offs[i] + 1]
		if lo == 0 && hi == 0 { break }
		if lo == 0xFF && hi == 0xFF { continue }
		lfn[pos] = lo if hi == 0 else '?'
		if pos + 1 > lfn_len^ {
			lfn_len^ = pos + 1
		}
	}
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

// Find entry named `name` inside directory `dir_cl` (matches LFN or 8.3).
fat32_find_in_dir :: proc "contextless" (dir_cl: u32, name: []u8) -> (FAT32_Entry_Loc, bool) {
	cl := dir_cl
	name_buf: [16]u8
	lfn_buf:  [260]u8
	lfn_len  := 0
	lfn_csum := u8(0)
	lfn_valid := false

	for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			lba := base_lba + u64(s)
			if !block_read(g_fat32.dev, lba, 1, &g_fat_secbuf[0]) {
				return FAT32_Entry_Loc{}, false
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					return FAT32_Entry_Loc{}, false
				}
				if ent[0] == 0xE5 {
					lfn_valid = false
					continue
				}
				attr := ent[11]
				if attr == 0x0F {
					fat32_lfn_extract(ent, lfn_buf[:], &lfn_len)
					lfn_csum  = ent[13]
					lfn_valid = true
					continue
				}
				if (attr & 0x08) != 0 {
					lfn_valid = false
					continue
				}

				nlen := fat32_format_83(ent[:11], name_buf[:])
				matched := fat32_name_eq(name_buf[:nlen], name)
				if !matched && lfn_valid && lfn_len > 0 && lfn_csum == fat32_83_checksum(ent[:11]) {
					matched = fat32_name_eq(lfn_buf[:lfn_len], name)
				}
				lfn_valid = false

				if matched {
					loc := FAT32_Entry_Loc{
						dir_cluster = dir_cl,
						lba         = lba,
						off         = e,
						attr        = attr,
						first_cl    = (u32(fat32_read_u16(ent, 20)) << 16) | u32(fat32_read_u16(ent, 26)),
						size        = fat32_read_u32(ent, 28),
					}
					for k := 0; k < 11; k += 1 {
						loc.raw83[k] = ent[k]
					}
					return loc, true
				}
			}
		}
		cl = fat32_next_cluster(cl)
	}
	return FAT32_Entry_Loc{}, false
}

// Resolve a full or relative path (e.g. "/EFI/BOOT/BOOTX64.EFI", "../WELCOME.TXT").
fat32_resolve_path :: proc "contextless" (path: []u8) -> (FAT32_Entry_Loc, bool) {
	if !g_fat32.mounted {
		return FAT32_Entry_Loc{}, false
	}
	cur_cl := g_fat32.cwd_cluster
	i := 0
	if len(path) > 0 && path[0] == '/' {
		cur_cl = g_fat32.root_cluster
		i = 1
	}

	// Skip trailing slashes
	end := len(path)
	for end > i && path[end - 1] == '/' {
		end -= 1
	}
	if i >= end {
		return FAT32_Entry_Loc{
			dir_cluster = cur_cl,
			attr        = 0x10,
			first_cl    = cur_cl,
			is_root     = (cur_cl == g_fat32.root_cluster),
		}, true
	}

	last_loc: FAT32_Entry_Loc
	for i < end {
		for i < end && path[i] == '/' {
			i += 1
		}
		if i >= end {
			break
		}
		seg_start := i
		for i < end && path[i] != '/' {
			i += 1
		}
		seg := path[seg_start:i]
		is_last := (i >= end)

		if len(seg) == 1 && seg[0] == '.' {
			if is_last {
				return FAT32_Entry_Loc{
					dir_cluster = cur_cl,
					attr        = 0x10,
					first_cl    = cur_cl,
					is_root     = (cur_cl == g_fat32.root_cluster),
				}, true
			}
			continue
		}

		loc, ok := fat32_find_in_dir(cur_cl, seg)
		if !ok {
			return FAT32_Entry_Loc{}, false
		}
		if is_last {
			if (loc.attr & 0x10) != 0 && loc.first_cl == 0 {
				loc.first_cl = g_fat32.root_cluster
				loc.is_root  = true
			}
			return loc, true
		}
		if (loc.attr & 0x10) == 0 {
			return FAT32_Entry_Loc{}, false
		}
		cur_cl = loc.first_cl if loc.first_cl >= 2 else g_fat32.root_cluster
		last_loc = loc
	}
	return last_loc, true
}

// Resolve parent directory cluster + leaf filename for creation/write.
fat32_resolve_parent :: proc "contextless" (path: []u8) -> (parent_cl: u32, leaf: []u8, ok: bool) {
	if !g_fat32.mounted || len(path) == 0 {
		return 0, nil, false
	}
	last_slash := -1
	for i := 0; i < len(path); i += 1 {
		if path[i] == '/' {
			last_slash = i
		}
	}
	if last_slash < 0 {
		return g_fat32.cwd_cluster, path, true
	}
	leaf = path[last_slash + 1:]
	if len(leaf) == 0 {
		return 0, nil, false
	}
	if last_slash == 0 {
		return g_fat32.root_cluster, leaf, true
	}
	parent_loc, pok := fat32_resolve_path(path[:last_slash])
	if !pok || (parent_loc.attr & 0x10) == 0 {
		return 0, nil, false
	}
	pcl := parent_loc.first_cl if parent_loc.first_cl >= 2 else g_fat32.root_cluster
	return pcl, leaf, true
}

// Find a free 32-byte slot in `dir_cl`, extending the directory by 1 cluster if full.
fat32_alloc_dir_slot :: proc "contextless" (dir_cl: u32) -> (lba: u64, off: int, ok: bool) {
	cl := dir_cl
	last_cl := dir_cl
	for cl >= 2 && cl < 0x0FFF_FFF8 {
		last_cl = cl
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			cur_lba := base_lba + u64(s)
			if !block_read(g_fat32.dev, cur_lba, 1, &g_fat_secbuf[0]) {
				return 0, -1, false
			}
			for e := 0; e < 512; e += 32 {
				b0 := g_fat_secbuf[e]
				if b0 == 0x00 || b0 == 0xE5 {
					return cur_lba, e, true
				}
			}
		}
		cl = fat32_next_cluster(cl)
	}

	// Directory is full — allocate & link a new zeroed cluster
	new_cl := fat32_alloc_cluster()
	if new_cl == 0 || !fat32_zero_cluster(new_cl) || !fat32_set_cluster(last_cl, new_cl) {
		return 0, -1, false
	}
	return fat32_cluster_to_lba(new_cl), 0, true
}

fat32_cwd_push :: proc "contextless" (seg: []u8) {
	if len(seg) == 0 || (len(seg) == 1 && seg[0] == '.') {
		return
	}
	if len(seg) == 2 && seg[0] == '.' && seg[1] == '.' {
		if g_fat32.cwd_len <= 1 {
			return
		}
		i := g_fat32.cwd_len - 1
		for i > 0 && g_fat32.cwd_path[i] != '/' {
			i -= 1
		}
		g_fat32.cwd_len = i if i > 0 else 1
		return
	}
	need := len(seg) + (1 if g_fat32.cwd_len > 1 else 0)
	if g_fat32.cwd_len + need >= len(g_fat32.cwd_path) {
		return
	}
	if g_fat32.cwd_len > 1 {
		g_fat32.cwd_path[g_fat32.cwd_len] = '/'
		g_fat32.cwd_len += 1
	}
	for i := 0; i < len(seg); i += 1 {
		g_fat32.cwd_path[g_fat32.cwd_len] = ascii_upper(seg[i])
		g_fat32.cwd_len += 1
	}
}

fat32_pwd :: proc "contextless" () -> string {
	if !g_fat32.mounted {
		return "/"
	}
	return string(g_fat32.cwd_path[:g_fat32.cwd_len])
}

fat32_cd :: proc "contextless" (path: []u8) -> bool {
	if !g_fat32.mounted {
		return false
	}
	if len(path) == 0 {
		g_fat32.cwd_cluster = g_fat32.root_cluster
		g_fat32.cwd_path[0] = '/'
		g_fat32.cwd_len     = 1
		return true
	}
	loc, ok := fat32_resolve_path(path)
	if !ok || (loc.attr & 0x10) == 0 {
		return false
	}
	target_cl := loc.first_cl if loc.first_cl >= 2 else g_fat32.root_cluster
	g_fat32.cwd_cluster = target_cl

	// Rebuild canonical cwd_path
	i := 0
	if path[0] == '/' {
		g_fat32.cwd_path[0] = '/'
		g_fat32.cwd_len     = 1
		i = 1
	}
	for i < len(path) {
		for i < len(path) && path[i] == '/' {
			i += 1
		}
		if i >= len(path) { break }
		s := i
		for i < len(path) && path[i] != '/' {
			i += 1
		}
		fat32_cwd_push(path[s:i])
	}
	if g_fat32.cwd_cluster == g_fat32.root_cluster {
		g_fat32.cwd_path[0] = '/'
		g_fat32.cwd_len     = 1
	}
	return true
}

fat32_ls_path :: proc "contextless" (path: []u8, ob: ^Out_Buf) -> bool {
	if !g_fat32.mounted {
		ob_puts(ob, "No FAT32 volume mounted.\n")
		return false
	}
	cl := g_fat32.cwd_cluster
	if len(path) > 0 {
		loc, ok := fat32_resolve_path(path)
		if !ok {
			ob_puts(ob, "ls: path not found\n")
			return false
		}
		if (loc.attr & 0x10) == 0 {
			ob_puts(ob, "ls: not a directory\n")
			return false
		}
		cl = loc.first_cl if loc.first_cl >= 2 else g_fat32.root_cluster
	}

	ob_puts(ob, "FAT32 ")
	if len(path) > 0 {
		ob_put_bytes(ob, path)
	} else {
		ob_puts(ob, fat32_pwd())
	}
	ob_puts(ob, " (dev=")
	ob_puts(ob, g_fat32.dev.name)
	ob_puts(ob, "):\n")

	name_buf: [16]u8
	lfn_buf:  [260]u8
	lfn_len  := 0
	lfn_csum := u8(0)
	lfn_valid := false

	for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return false
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					return true
				}
				if ent[0] == 0xE5 {
					lfn_valid = false
					continue
				}
				attr := ent[11]
				if attr == 0x0F {
					fat32_lfn_extract(ent, lfn_buf[:], &lfn_len)
					lfn_csum  = ent[13]
					lfn_valid = true
					continue
				}
				if (attr & 0x08) != 0 {
					lfn_valid = false
					continue
				}

				_, tag := fat32_ext_kind(ent[:11], attr)
				disp: []u8
				if lfn_valid && lfn_len > 0 && lfn_csum == fat32_83_checksum(ent[:11]) {
					disp = lfn_buf[:lfn_len]
				} else {
					nlen := fat32_format_83(ent[:11], name_buf[:])
					disp = name_buf[:nlen]
				}
				lfn_valid = false

				ob_puts(ob, "  ")
				ob_puts(ob, tag)
				ob_putc(ob, ' ')
				ob_put_bytes(ob, disp)
				for k := len(disp); k < 16; k += 1 {
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
	return true
}

fat32_list_dir :: proc "contextless" (path: []u8, a: ^Arena) -> ([]syscalls.Dir_Entry, bool) {
	if !g_fat32.mounted || a == nil {
		return nil, false
	}
	start_cl := g_fat32.cwd_cluster
	if len(path) > 0 {
		loc, ok := fat32_resolve_path(path)
		if !ok || (loc.attr & 0x10) == 0 {
			return nil, false
		}
		start_cl = loc.first_cl if loc.first_cl >= 2 else g_fat32.root_cluster
	}

	// Pass 1: count valid directory entries
	count := 0
	cl := start_cl
	done := false
	for !done && cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); !done && s < g_fat32.sectors_per_cluster; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return nil, false
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					done = true
					break
				}
				if ent[0] == 0xE5 {
					continue
				}
				attr := ent[11]
				if attr == 0x0F || (attr & 0x08) != 0 {
					continue
				}
				count += 1
			}
		}
		if !done {
			cl = fat32_next_cluster(cl)
		}
	}

	if count == 0 {
		return nil, true
	}

	raw := arena_alloc(a, u64(count) * u64(size_of(syscalls.Dir_Entry)), align_of(syscalls.Dir_Entry))
	if raw == nil {
		return nil, false
	}
	entries := ([^]syscalls.Dir_Entry)(raw)[:count]

	// Pass 2: populate entries
	name_buf: [16]u8
	lfn_buf:  [260]u8
	lfn_len  := 0
	lfn_csum := u8(0)
	lfn_valid := false

	idx := 0
	cl = start_cl
	done = false
	for !done && cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); !done && s < g_fat32.sectors_per_cluster; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return nil, false
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					done = true
					break
				}
				if ent[0] == 0xE5 {
					lfn_valid = false
					continue
				}
				attr := ent[11]
				if attr == 0x0F {
					fat32_lfn_extract(ent, lfn_buf[:], &lfn_len)
					lfn_csum  = ent[13]
					lfn_valid = true
					continue
				}
				if (attr & 0x08) != 0 {
					lfn_valid = false
					continue
				}

				disp: []u8
				if lfn_valid && lfn_len > 0 && lfn_csum == fat32_83_checksum(ent[:11]) {
					disp = lfn_buf[:lfn_len]
				} else {
					nlen := fat32_format_83(ent[:11], name_buf[:])
					disp = name_buf[:nlen]
				}
				lfn_valid = false

				if idx < count {
					entry := syscalls.Dir_Entry{}
					n := len(disp)
					if n > len(entry.name) {
						n = len(entry.name)
					}
					for k := 0; k < n; k += 1 {
						entry.name[k] = disp[k]
					}
					entry.name_len = u32(n)
					entry.is_dir   = (attr & 0x10) != 0
					entry.size     = 0 if entry.is_dir else fat32_read_u32(ent, 28)
					entries[idx]   = entry
					idx += 1
				}
			}
		}
		if !done {
			cl = fat32_next_cluster(cl)
		}
	}

	return entries[:idx], true
}

fat32_read_file :: proc "contextless" (path: []u8, a: ^Arena) -> ([]u8, bool) {
	loc, ok := fat32_resolve_path(path)
	if !ok || (loc.attr & 0x10) != 0 {
		return nil, false
	}
	if loc.size == 0 {
		return nil, true
	}

	raw := arena_alloc(a, u64(loc.size), 1)
	if raw == nil {
		return nil, false
	}
	dst := ([^]u8)(raw)

	rem := loc.size
	cur := loc.first_cl
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

fat32_write_file :: proc "contextless" (path: []u8, data: []u8) -> bool {
	parent_cl, leaf, pok := fat32_resolve_parent(path)
	if !pok {
		return false
	}
	raw83: [11]u8
	if !fat32_parse_83(leaf, raw83[:]) {
		return false
	}

	slot_lba := u64(0)
	slot_off := -1
	old_cl   := u32(0)

	if existing, found := fat32_find_in_dir(parent_cl, leaf); found {
		if (existing.attr & 0x10) != 0 {
			return false
		}
		slot_lba = existing.lba
		slot_off = existing.off
		old_cl   = existing.first_cl
	} else {
		lba, off, sok := fat32_alloc_dir_slot(parent_cl)
		if !sok {
			return false
		}
		slot_lba = lba
		slot_off = off
	}

	if old_cl >= 2 {
		fat32_free_chain(old_cl)
	}

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
	ent[11] = 0x20
	fat32_write_u16(ent, 20, u16((first_cl >> 16) & 0xFFFF))
	fat32_write_u16(ent, 26, u16(first_cl & 0xFFFF))
	fat32_write_u32(ent, 28, u32(len(data)))
	return block_write(g_fat32.dev, slot_lba, 1, &g_fat_secbuf[0])
}

fat32_del_file :: proc "contextless" (path: []u8) -> bool {
	loc, ok := fat32_resolve_path(path)
	if !ok || (loc.attr & 0x10) != 0 {
		return false
	}
	if !block_read(g_fat32.dev, loc.lba, 1, &g_fat_secbuf[0]) {
		return false
	}
	g_fat_secbuf[loc.off] = 0xE5
	if !block_write(g_fat32.dev, loc.lba, 1, &g_fat_secbuf[0]) {
		return false
	}
	if loc.first_cl >= 2 {
		fat32_free_chain(loc.first_cl)
	}
	return true
}

fat32_mkdir :: proc "contextless" (path: []u8) -> bool {
	parent_cl, leaf, pok := fat32_resolve_parent(path)
	if !pok {
		return false
	}
	raw83: [11]u8
	if !fat32_parse_83(leaf, raw83[:]) {
		return false
	}
	if _, exists := fat32_find_in_dir(parent_cl, leaf); exists {
		return false
	}

	slot_lba, slot_off, sok := fat32_alloc_dir_slot(parent_cl)
	if !sok {
		return false
	}
	new_cl := fat32_alloc_cluster()
	if new_cl == 0 || !fat32_zero_cluster(new_cl) {
		return false
	}

	// Write "." and ".." entries in sector 0 of new directory cluster
	for i := 0; i < 512; i += 1 {
		g_fat_secbuf[i] = 0
	}
	dot := g_fat_secbuf[0:32]
	dot[0] = '.'
	for i := 1; i < 11; i += 1 { dot[i] = ' ' }
	dot[11] = 0x10
	fat32_write_u16(dot, 20, u16((new_cl >> 16) & 0xFFFF))
	fat32_write_u16(dot, 26, u16(new_cl & 0xFFFF))

	dotdot := g_fat_secbuf[32:64]
	dotdot[0] = '.'
	dotdot[1] = '.'
	for i := 2; i < 11; i += 1 { dotdot[i] = ' ' }
	dotdot[11] = 0x10
	pp := u32(0) if parent_cl == g_fat32.root_cluster else parent_cl
	fat32_write_u16(dotdot, 20, u16((pp >> 16) & 0xFFFF))
	fat32_write_u16(dotdot, 26, u16(pp & 0xFFFF))

	if !block_write(g_fat32.dev, fat32_cluster_to_lba(new_cl), 1, &g_fat_secbuf[0]) {
		return false
	}

	// Write directory entry in parent
	if !block_read(g_fat32.dev, slot_lba, 1, &g_fat_secbuf[0]) {
		return false
	}
	ent := g_fat_secbuf[slot_off : slot_off + 32]
	for i := 0; i < 32; i += 1 { ent[i] = 0 }
	for i := 0; i < 11; i += 1 { ent[i] = raw83[i] }
	ent[11] = 0x10
	fat32_write_u16(ent, 20, u16((new_cl >> 16) & 0xFFFF))
	fat32_write_u16(ent, 26, u16(new_cl & 0xFFFF))
	return block_write(g_fat32.dev, slot_lba, 1, &g_fat_secbuf[0])
}

fat32_dir_is_empty :: proc "contextless" (dir_cl: u32) -> bool {
	cl := dir_cl
	for cl >= 2 && cl < 0x0FFF_FFF8 {
		base_lba := fat32_cluster_to_lba(cl)
		for s := u32(0); s < g_fat32.sectors_per_cluster; s += 1 {
			if !block_read(g_fat32.dev, base_lba + u64(s), 1, &g_fat_secbuf[0]) {
				return false
			}
			for e := 0; e < 512; e += 32 {
				ent := g_fat_secbuf[e : e + 32]
				if ent[0] == 0x00 {
					return true
				}
				if ent[0] == 0xE5 || ent[11] == 0x0F || (ent[11] & 0x08) != 0 {
					continue
				}
				// Allow only "." and ".."
				if ent[0] == '.' && (ent[1] == ' ' || (ent[1] == '.' && ent[2] == ' ')) {
					continue
				}
				return false
			}
		}
		cl = fat32_next_cluster(cl)
	}
	return true
}

fat32_rmdir :: proc "contextless" (path: []u8) -> bool {
	loc, ok := fat32_resolve_path(path)
	if !ok || (loc.attr & 0x10) == 0 || loc.is_root || loc.first_cl == g_fat32.cwd_cluster {
		return false
	}
	if !fat32_dir_is_empty(loc.first_cl) {
		return false
	}
	if !block_read(g_fat32.dev, loc.lba, 1, &g_fat_secbuf[0]) {
		return false
	}
	g_fat_secbuf[loc.off] = 0xE5
	if !block_write(g_fat32.dev, loc.lba, 1, &g_fat_secbuf[0]) {
		return false
	}
	if loc.first_cl >= 2 {
		fat32_free_chain(loc.first_cl)
	}
	return true
}

fat32_df :: proc "contextless" (ob: ^Out_Buf) {
	if !g_fat32.mounted {
		ob_puts(ob, "No FAT32 volume mounted.\n")
		return
	}
	free_cl := u64(0)
	max_cl := g_fat32.total_clusters + 2
	for s := u32(0); s < g_fat32.fat_size; s += 1 {
		if !block_read(g_fat32.dev, g_fat32.fat_lba + u64(s), 1, &g_fat_secbuf[0]) {
			break
		}
		for e := 0; e < 128; e += 1 {
			cl := s * 128 + u32(e)
			if cl < 2 { continue }
			if cl >= max_cl { break }
			if (fat32_read_u32(g_fat_secbuf[:512], e * 4) & 0x0FFF_FFFF) == 0 {
				free_cl += 1
			}
		}
	}
	cl_bytes := u64(g_fat32.sectors_per_cluster) * 512
	tot_kib  := (u64(g_fat32.total_clusters) * cl_bytes) / 1024
	free_kib := (free_cl * cl_bytes) / 1024
	used_kib := tot_kib - free_kib

	ob_puts(ob, "FAT32 / (dev=")
	ob_puts(ob, g_fat32.dev.name)
	ob_puts(ob, " cluster=")
	ob_put_u64(ob, cl_bytes)
	ob_puts(ob, " B): total=")
	ob_put_u64(ob, tot_kib)
	ob_puts(ob, " KiB, used=")
	ob_put_u64(ob, used_kib)
	ob_puts(ob, " KiB, free=")
	ob_put_u64(ob, free_kib)
	ob_puts(ob, " KiB\n")
}

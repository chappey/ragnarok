package kernel

// GPT / MBR / Superfloppy FAT32 reader built on top of Block_Device.
// Works seamlessly with AHCI SATA drives, NVMe SSDs, and UEFI ESP images.

FAT32_FS :: struct {
	dev:                 ^Block_Device,
	mounted:             bool,
	part_lba:            u64,
	bytes_per_sector:    u32,
	sectors_per_cluster: u32,
	fat_lba:             u64,
	data_lba:            u64,
	root_cluster:        u32,
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

package kernel

g_mem_map_buf: [16384]u8

// Pick the cleanest GOP mode for our 640x480 logical canvas:
// prefer exact 2x (1280x960), then 1280x1024, 1920x1080, or native 640x480.
select_best_gop_mode :: proc "c" (gop: ^EFI_GOP) {
	if gop == nil || gop.mode == nil || gop.query_mode == nil || gop.set_mode == nil {
		return
	}
	best_mode := gop.mode.mode
	best_score := u32(0)

	for m := u32(0); m < gop.mode.max_mode; m += 1 {
		info_size: uintptr
		info: ^EFI_GOP_Mode_Info
		if gop.query_mode(gop, m, &info_size, &info) != EFI_SUCCESS || info == nil {
			continue
		}
		if info.pixel_format > 1 {
			continue
		}
		w := info.horizontal_resolution
		h := info.vertical_resolution
		score := u32(0)
		if w == 1280 && h == 960 {
			score = 100
		} else if w == 1280 && h == 1024 {
			score = 90
		} else if w == 1920 && h == 1080 {
			score = 85
		} else if w == 640 && h == 480 {
			score = 80
		} else if w >= 1280 && h >= 960 {
			score = 70
		}
		if score > best_score {
			best_score = score
			best_mode = m
		}
	}

	if best_score > 0 && best_mode != gop.mode.mode {
		gop.set_mode(gop, best_mode)
	}
}

@(export, link_name="efi_main")
efi_main :: proc "c" (image_handle: EFI_Handle, st: ^EFI_System_Table) -> EFI_Status {
	serial_init()
	serial_puts("\n=== Ragnarok OS (x86_64 Ring-0, Odin + Direct UEFI) ===\n")

	bs := st.boot_services

	// Acquire UEFI GOP framebuffer & select best integer-scale mode
	gop_guid := EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID
	gop_raw: rawptr
	fb_base: [^]u32 = nil
	fb_w, fb_h, fb_pitch: u32
	status := bs.locate_protocol(&gop_guid, nil, &gop_raw)
	if status == EFI_SUCCESS && gop_raw != nil {
		gop := (^EFI_GOP)(gop_raw)
		select_best_gop_mode(gop)
		fb_base  = ([^]u32)(uintptr(gop.mode.frame_buffer_base))
		fb_w     = gop.mode.info.horizontal_resolution
		fb_h     = gop.mode.info.vertical_resolution
		fb_pitch = gop.mode.info.pixels_per_scan_line
	}

	// ExitBootServices -> full bare-metal Ring-0 ownership
	map_size: uintptr = len(g_mem_map_buf)
	map_key: uintptr
	desc_size: uintptr
	desc_ver: u32
	status = bs.get_memory_map(&map_size, &g_mem_map_buf[0], &map_key, &desc_size, &desc_ver)
	if status != EFI_SUCCESS {
		serial_puts("ERR: GetMemoryMap failed\n")
		arch_poweroff()
	}
	status = bs.exit_boot_services(image_handle, map_key)
	if status != EFI_SUCCESS {
		map_size = len(g_mem_map_buf)
		bs.get_memory_map(&map_size, &g_mem_map_buf[0], &map_key, &desc_size, &desc_ver)
		status = bs.exit_boot_services(image_handle, map_key)
	}
	if status != EFI_SUCCESS {
		serial_puts("ERR: ExitBootServices failed\n")
		arch_poweroff()
	}

	arch_cli()
	pmm_init(&g_mem_map_buf[0], map_size, desc_size)
	pci_init()
	ahci_init()
	nvme_init()
	_ = fat32_mount_first()
	xhci_init()
	gfx_init(fb_base, fb_w, fb_h, fb_pitch)
	ps2_init()
	con_init()
	kernel_main(map_size, desc_size)
	return EFI_SUCCESS
}

input_getc :: proc "contextless" () -> u8 {
	for {
		if ch, ok := xhci_poll_char(); ok {
			return ch
		}
		if ch, ok := ps2_poll_char(); ok {
			return ch
		}
		if ch, ok := serial_poll_char(); ok {
			return ch
		}
		arch_pause()
	}
}

kernel_main :: proc "contextless" (map_size, desc_size: uintptr) {
	// Signal readiness on COM1 and boot straight into the live animated Ragnarok splash
	serial_puts("RAGNAROK_READY\n")
	run_ragnarok_splash()

	con_set_color(COL_YELLOW, COL_BLACK)
	out_puts("================================================================================\n")
	con_set_color(COL_LTRED, COL_BLACK)
	out_puts("  RAGNAROK OS v0.1  --  TWILIGHT OF THE GODS  (x86_64 Ring-0, Odin + UEFI)\n")
	con_set_color(COL_YELLOW, COL_BLACK)
	out_puts("================================================================================\n")

	con_set_color(COL_LTCYAN, COL_BLACK)
	out_puts("GOP:    ")
	out_put_u64(u64(g_fb.width))
	out_putc('x')
	out_put_u64(u64(g_fb.height))
	out_puts("  ->  640x480x16 canvas (scale=")
	out_put_u64(u64(g_fb.scale))
	out_puts("x, off=")
	out_put_u64(u64(g_fb.off_x))
	out_putc(',')
	out_put_u64(u64(g_fb.off_y))
	out_puts(")\n")

	out_puts("Input:  USB=")
	if g_xhci.kbd_ready {
		out_puts("kbd")
	} else if g_xhci.present {
		out_puts("xhci")
	} else {
		out_puts("no")
	}
	out_puts("  PS/2=")
	out_puts("yes" if g_ps2_present else "no")
	out_puts("  COM1=")
	out_puts("yes" if g_serial_present else "no")
	out_puts("  RAM=")
	out_put_u64((g_pmm_free_pages * PAGE_SIZE) / (1024 * 1024))
	out_puts("M  PCI=")
	out_put_u64(u64(g_pci_count))
	out_puts("  BLK=")
	out_put_u64(u64(g_block_count))
	out_puts("\n")

	con_set_color(COL_LTGRAY, COL_BLACK)
	out_puts("Type 'help', 'mem', 'lspci', 'lsblk', 'ls', 'cat <file>', or 'splash'.\n\n")

	shell_loop()
}

str_eq :: proc "contextless" (a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

shell_loop :: proc "contextless" () {
	line: [128]u8
	for {
		con_set_color(COL_LTGREEN, COL_BLACK)
		out_puts("ragnarok> ")
		con_set_color(COL_WHITE, COL_BLACK)
		n := 0
		for {
			c := input_getc()
			if c == 0x0C { // Ctrl+L
				con_clear()
				con_set_color(COL_LTGREEN, COL_BLACK)
				out_puts("ragnarok> ")
				con_set_color(COL_WHITE, COL_BLACK)
				for i := 0; i < n; i += 1 {
					con_putc_raw(line[i])
				}
				con_flush()
				continue
			}
			if c == '\r' || c == '\n' {
				out_puts("\n")
				break
			}
			if (c == 0x08 || c == 0x7F) && n > 0 {
				n -= 1
				out_puts("\b \b")
			} else if c >= 0x20 && c < 0x7F && n < len(line) {
				line[n] = c
				n += 1
				out_putc(c)
				con_flush()
			}
		}

		con_set_color(COL_LTGRAY, COL_BLACK)
		cmd := line[:n]
		if n == 0 {
			continue
		} else if str_eq(cmd, "help") {
			out_puts("Commands:\n")
			out_puts("  help              Show this help\n")
			out_puts("  info              System & display info\n")
			out_puts("  mem               Show physical RAM stats & run DMA page alloc test\n")
			out_puts("  lspci             List discovered PCI devices\n")
			out_puts("  lsblk             List AHCI / NVMe block devices\n")
			out_puts("  ls                List files in mounted FAT32 root directory\n")
			out_puts("  cat <file>        Print a file from the mounted FAT32 volume\n")
			out_puts("  splash            Show Ragnarok twilight splash (press any key to return)\n")
			out_puts("  palette norse     Switch LUT to Norse dusk palette (default)\n")
			out_puts("  palette templeos  Switch LUT to classic TempleOS 16-color palette\n")
			out_puts("  clear             Clear console (or Ctrl+L)\n")
			out_puts("  reboot            Reboot machine (i8042 / PCH CF9)\n")
			out_puts("  halt              Power off (QEMU ACPI) or halt CPU\n")
		} else if str_eq(cmd, "info") {
			out_puts("Ragnarok OS v0.1 | x86_64 Ring-0 | 640x480x16 Logical Canvas\n")
		} else if str_eq(cmd, "mem") {
			used := g_pmm_total_pages - g_pmm_free_pages
			out_puts("PMM: total=")
			out_put_u64((g_pmm_total_pages * PAGE_SIZE) / (1024 * 1024))
			out_puts(" MiB (")
			out_put_u64(g_pmm_total_pages)
			out_puts(" pages), free=")
			out_put_u64((g_pmm_free_pages * PAGE_SIZE) / (1024 * 1024))
			out_puts(" MiB, used=")
			out_put_u64(used)
			out_puts(" pages\n")
			// Quick contiguous 4-page DMA alloc/write/free self-test
			phys := pmm_alloc_contiguous(4)
			if phys != 0 {
				ptr := ([^]u64)(uintptr(phys))
				ptr[0] = 0xDEAD_BEEF_CAFE_BABE
				ok := (ptr[0] == 0xDEAD_BEEF_CAFE_BABE)
				pmm_free_pages(phys, 4)
				out_puts("DMA test (4x4KiB): ")
				out_put_hex(phys)
				out_puts(" -> ")
				out_puts("PASS\n" if ok else "FAIL\n")
			} else {
				out_puts("DMA test: OOM\n")
			}
		} else if str_eq(cmd, "lspci") {
			pci_print_devices()
		} else if str_eq(cmd, "lsblk") {
			block_print_devices()
		} else if str_eq(cmd, "ls") {
			fat32_ls()
		} else if len(cmd) > 4 && cmd[0] == 'c' && cmd[1] == 'a' && cmd[2] == 't' && cmd[3] == ' ' {
			fat32_cat(cmd[4:])
		} else if str_eq(cmd, "splash") {
			run_ragnarok_splash()
			con_flush()
		} else if str_eq(cmd, "palette norse") {
			gfx_set_palette(PALETTE_NORSE)
			con_flush()
			out_puts("Palette swapped -> Norse dusk LUT.\n")
		} else if str_eq(cmd, "palette templeos") {
			gfx_set_palette(PALETTE_TEMPLEOS)
			con_flush()
			out_puts("Palette swapped -> classic TempleOS 16-color LUT.\n")
		} else if str_eq(cmd, "clear") {
			con_clear()
			con_flush()
		} else if str_eq(cmd, "reboot") {
			out_puts("Rebooting...\n")
			arch_reboot()
		} else if str_eq(cmd, "halt") || str_eq(cmd, "poweroff") {
			out_puts("Powering off...\n")
			arch_poweroff()
		} else {
			con_set_color(COL_LTRED, COL_BLACK)
			out_puts("Unknown command: ")
			for i := 0; i < n; i += 1 {
				out_putc(cmd[i])
			}
			out_puts("\n")
		}
	}
}

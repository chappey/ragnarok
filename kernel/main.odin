package kernel

g_mem_map_buf: [16384]u8

// Pick the cleanest GOP mode for our 640x480 logical canvas:
// prefer exact 2x (1280x960), then 1280x1024 (2x with small letterbox), then native 640x480.
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
		// Only accept linear 32-bit BGRX/RGBX modes (pixel_format 0 or 1)
		if info.pixel_format > 1 {
			continue
		}
		w := info.horizontal_resolution
		h := info.vertical_resolution
		score := u32(0)
		if w == 1280 && h == 960 {
			score = 100 // exact 2x
		} else if w == 1280 && h == 1024 {
			score = 90  // 2x with tiny vertical letterbox
		} else if w == 1920 && h == 1080 {
			score = 85  // 2x on 1080p
		} else if w == 640 && h == 480 {
			score = 80  // exact 1x
		} else if w >= 1280 && h >= 960 {
			score = 70  // >= 2x
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
		serial_puts("GOP: ")
		serial_put_u64(u64(fb_w))
		serial_putc('x')
		serial_put_u64(u64(fb_h))
		serial_puts(" fb=")
		serial_put_hex(gop.mode.frame_buffer_base)
		serial_puts("\n")
	} else {
		serial_puts("GOP: unavailable\n")
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
		// Retry once per UEFI spec if map key changed
		map_size = len(g_mem_map_buf)
		bs.get_memory_map(&map_size, &g_mem_map_buf[0], &map_key, &desc_size, &desc_ver)
		status = bs.exit_boot_services(image_handle, map_key)
	}
	if status != EFI_SUCCESS {
		serial_puts("ERR: ExitBootServices failed\n")
		arch_poweroff()
	}

	arch_cli()
	gfx_init(fb_base, fb_w, fb_h, fb_pitch)
	kernel_main(map_size, desc_size)
	return EFI_SUCCESS
}

kernel_main :: proc "contextless" (map_size, desc_size: uintptr) {
	gfx_draw_splash()

	serial_puts("Canvas: 640x480x16 -> scale=")
	serial_put_u64(u64(g_fb.scale))
	serial_puts("x off=(")
	serial_put_u64(u64(g_fb.off_x))
	serial_putc(',')
	serial_put_u64(u64(g_fb.off_y))
	serial_puts(")\n")

	serial_puts("Ring-0 active (ExitBootServices OK, mem_descs=")
	if desc_size > 0 {
		serial_put_u64(u64(map_size / desc_size))
	} else {
		serial_putc('0')
	}
	serial_puts(")\n")
	serial_puts("RAGNAROK_READY\n")

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
		serial_puts("ragnarok> ")
		n := 0
		for {
			c := serial_getc()
			if c == '\r' || c == '\n' {
				serial_puts("\n")
				break
			}
			if (c == 0x08 || c == 0x7F) && n > 0 {
				n -= 1
				serial_puts("\b \b")
			} else if c >= 0x20 && c < 0x7F && n < len(line) {
				line[n] = c
				n += 1
				serial_putc(c)
			}
		}

		cmd := line[:n]
		if n == 0 {
			continue
		} else if str_eq(cmd, "help") {
			serial_puts("Commands: help, info, splash, palette norse, palette templeos, clear, halt\n")
		} else if str_eq(cmd, "info") {
			serial_puts("Ragnarok OS v0.1 | x86_64 Ring-0 | 640x480x16 Logical Canvas\n")
		} else if str_eq(cmd, "splash") {
			gfx_draw_splash()
			serial_puts("Splash rendered.\n")
		} else if str_eq(cmd, "palette norse") {
			gfx_set_palette(PALETTE_NORSE)
			gfx_present()
			serial_puts("Palette swapped -> Norse dusk LUT.\n")
		} else if str_eq(cmd, "palette templeos") {
			gfx_reset_palette()
			gfx_present()
			serial_puts("Palette swapped -> TempleOS 16-color default LUT.\n")
		} else if str_eq(cmd, "clear") {
			gfx_clear(COL_BLACK)
			gfx_present()
			serial_puts("Canvas cleared.\n")
		} else if str_eq(cmd, "halt") || str_eq(cmd, "poweroff") {
			serial_puts("Powering off...\n")
			arch_poweroff()
		} else {
			serial_puts("Unknown command: ")
			for i := 0; i < n; i += 1 {
				serial_putc(cmd[i])
			}
			serial_puts("\n")
		}
	}
}

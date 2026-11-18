package kernel

g_mem_map_buf: [16384]u8

@(export, link_name="efi_main")
efi_main :: proc "c" (image_handle: EFI_Handle, st: ^EFI_System_Table) -> EFI_Status {
	serial_init()
	serial_puts("\n=== Ragnarok OS (x86_64 Ring-0, Odin + Direct UEFI) ===\n")

	bs := st.boot_services

	// Acquire UEFI GOP framebuffer
	gop_guid := EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID
	gop_raw: rawptr
	status := bs.locate_protocol(&gop_guid, nil, &gop_raw)
	if status == EFI_SUCCESS && gop_raw != nil {
		gop := (^EFI_GOP)(gop_raw)
		g_fb.base   = ([^]u32)(uintptr(gop.mode.frame_buffer_base))
		g_fb.width  = gop.mode.info.horizontal_resolution
		g_fb.height = gop.mode.info.vertical_resolution
		g_fb.pitch  = gop.mode.info.pixels_per_scan_line
		serial_puts("GOP: ")
		serial_put_u64(u64(g_fb.width))
		serial_putc('x')
		serial_put_u64(u64(g_fb.height))
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
	kernel_main(map_size, desc_size)
	return EFI_SUCCESS
}

kernel_main :: proc "contextless" (map_size, desc_size: uintptr) {
	// Dark slate background + Nordic amber accent bar on GOP framebuffer
	fb_clear(0x0011141B)
	fb_fill_rect(0, 0, g_fb.width, 6, 0x00F0A500)
	fb_fill_rect(32, 32, 240, 8, 0x00E6EDF3)

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
			serial_puts("Commands: help, info, clear, halt\n")
		} else if str_eq(cmd, "info") {
			serial_puts("Ragnarok OS v0.1 | x86_64 Ring-0 | Odin + Direct UEFI\n")
		} else if str_eq(cmd, "clear") {
			fb_clear(0x0011141B)
			serial_puts("Framebuffer cleared.\n")
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

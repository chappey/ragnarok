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

	// Acquire LoadedImage protocol to record UEFI load base/size for symbolication
	if bs.handle_protocol != nil {
		li_guid := EFI_LOADED_IMAGE_PROTOCOL_GUID
		li_raw: rawptr
		if bs.handle_protocol(image_handle, &li_guid, &li_raw) == EFI_SUCCESS && li_raw != nil {
			li := (^EFI_Loaded_Image)(li_raw)
			g_image_base = li.image_base
			g_image_size = li.image_size
		}
	}

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

	// Parse ACPI RSDP/FADT/DSDT before ExitBootServices for bare-metal S5 poweroff
	acpi_init(st)

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
	tsc_init()
	idt_init()

	if g_acpi_ready {
		klog_prefix("INFO")
		klog_puts("ACPI PM1a_CNT=")
		klog_put_hex(u64(g_acpi_pm1a_cnt))
		klog_puts(" SLP_TYPa=")
		klog_put_u64(u64(g_acpi_slp_typa))
		klog_putc('\n')
	} else {
		klog_line("WARN", "ACPI FADT/S5 unavailable (using fallback poweroff ports)")
	}

	klog_prefix("INFO")
	klog_puts("ImageBase=")
	klog_put_hex(g_image_base)
	klog_puts(" size=")
	klog_put_u64(g_image_size)
	klog_puts(" tsc=")
	klog_put_u64(g_tsc_khz / 1000)
	klog_puts(" MHz\n")

	klog_prefix("INFO")
	klog_puts("GOP=")
	klog_put_u64(u64(fb_w))
	klog_putc('x')
	klog_put_u64(u64(fb_h))
	klog_puts(" fb=")
	klog_put_hex(u64(uintptr(fb_base)))
	klog_putc('\n')

	pmm_init(&g_mem_map_buf[0], map_size, desc_size)
	klog_prefix("INFO")
	klog_puts("PMM total=")
	klog_put_u64((g_pmm_total_pages * PAGE_SIZE) / (1024 * 1024))
	klog_puts(" MiB (")
	klog_put_u64(g_pmm_total_pages)
	klog_puts(" pages)\n")

	pci_init()
	klog_prefix("INFO")
	klog_puts("PCI enumerated ")
	klog_put_u64(u64(g_pci_count))
	klog_puts(" devices\n")

	ahci_init()
	nvme_init()
	klog_prefix("INFO")
	klog_puts("Storage block_devs=")
	klog_put_u64(u64(g_block_count))
	klog_putc('\n')

	if fat32_mount_first() {
		klog_prefix("INFO")
		klog_puts("FAT32 mounted dev=")
		klog_puts(g_fat32.dev.name)
		klog_puts(" part_lba=")
		klog_put_u64(g_fat32.part_lba)
		klog_putc('\n')
	} else {
		klog_line("WARN", "FAT32 no volume found")
	}

	xhci_init()
	if g_xhci.kbd_ready {
		klog_line("INFO", "xHCI USB3 + HID Boot keyboard ready")
	} else if g_xhci.present {
		klog_line("WARN", "xHCI controller active, no HID keyboard found")
	} else {
		klog_line("INFO", "xHCI controller not present")
	}

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
	out_puts("Ragnarok -- Twilight of the Gods. Type 'help' to begin.\n\n")

	shell_loop()
}

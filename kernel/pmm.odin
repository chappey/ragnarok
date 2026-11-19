package kernel

// Physical Memory Manager (PMM) — 4 KiB page-frame bitmap built from the UEFI memory map.
// Identity-mapped Ring-0: physical addresses are directly usable as pointers.
// Supports up to 8 GiB of tracked physical RAM (256 KiB bitmap) with contiguous DMA allocation.

PAGE_SIZE      :: u64(4096)
PMM_MAX_PAGES  :: u64(2 * 1024 * 1024) // 2M pages = 8 GiB
PMM_BITMAP_LEN :: PMM_MAX_PAGES / 64   // 32,768 u64 words = 256 KiB

EFI_CONVENTIONAL_MEMORY :: u32(7)

g_pmm_bitmap:      [PMM_BITMAP_LEN]u64 // 1 = used/reserved, 0 = free
g_pmm_total_pages: u64
g_pmm_free_pages:  u64
g_pmm_highest_pg:  u64

pmm_set_used :: proc "contextless" (page: u64) {
	if page >= PMM_MAX_PAGES {
		return
	}
	word := page >> 6
	bit  := u64(1) << (page & 63)
	if (g_pmm_bitmap[word] & bit) == 0 {
		g_pmm_bitmap[word] |= bit
		if g_pmm_free_pages > 0 {
			g_pmm_free_pages -= 1
		}
	}
}

pmm_set_free :: proc "contextless" (page: u64) {
	if page >= PMM_MAX_PAGES {
		return
	}
	word := page >> 6
	bit  := u64(1) << (page & 63)
	if (g_pmm_bitmap[word] & bit) != 0 {
		g_pmm_bitmap[word] &~= bit
		g_pmm_free_pages += 1
	}
}

pmm_is_used :: proc "contextless" (page: u64) -> bool {
	if page >= PMM_MAX_PAGES {
		return true
	}
	return (g_pmm_bitmap[page >> 6] & (u64(1) << (page & 63))) != 0
}

pmm_init :: proc "contextless" (mem_map: [^]u8, map_size, desc_size: uintptr) {
	// Mark all pages reserved by default
	for i := u64(0); i < PMM_BITMAP_LEN; i += 1 {
		g_pmm_bitmap[i] = ~u64(0)
	}
	g_pmm_total_pages = 0
	g_pmm_free_pages  = 0
	g_pmm_highest_pg  = 0

	if desc_size == 0 || map_size < desc_size {
		return
	}

	offset := uintptr(0)
	for offset + desc_size <= map_size {
		desc := (^EFI_Memory_Descriptor)(uintptr(mem_map) + offset)
		offset += desc_size

		if desc.type != EFI_CONVENTIONAL_MEMORY || desc.number_of_pages == 0 {
			continue
		}

		start_pg := desc.physical_start / PAGE_SIZE
		end_pg   := start_pg + desc.number_of_pages

		// Always keep low 1 MiB (first 256 pages) reserved for legacy/BIOS structures
		if end_pg <= 256 {
			continue
		}
		if start_pg < 256 {
			start_pg = 256
		}
		if start_pg >= PMM_MAX_PAGES {
			continue
		}
		if end_pg > PMM_MAX_PAGES {
			end_pg = PMM_MAX_PAGES
		}

		for pg := start_pg; pg < end_pg; pg += 1 {
			pmm_set_free(pg)
			g_pmm_total_pages += 1
		}
		if end_pg > g_pmm_highest_pg {
			g_pmm_highest_pg = end_pg
		}
	}
}

// Allocate `count` physically contiguous 4 KiB pages, zeroed and ready for DMA.
// Returns physical address (0 on OOM).
pmm_alloc_contiguous :: proc "contextless" (count: u64) -> u64 {
	if count == 0 || count > g_pmm_free_pages {
		return 0
	}

	run_start := u64(0)
	run_len   := u64(0)

	for pg := u64(256); pg < g_pmm_highest_pg; pg += 1 {
		// Fast-skip fully occupied 64-page words when not in a run
		if run_len == 0 && (pg & 63) == 0 && g_pmm_bitmap[pg >> 6] == ~u64(0) {
			pg += 63
			continue
		}
		if !pmm_is_used(pg) {
			if run_len == 0 {
				run_start = pg
			}
			run_len += 1
			if run_len == count {
				for i := u64(0); i < count; i += 1 {
					pmm_set_used(run_start + i)
				}
				phys := run_start * PAGE_SIZE
				ptr := ([^]u64)(uintptr(phys))
				qwords := (count * PAGE_SIZE) / 8
				for i := u64(0); i < qwords; i += 1 {
					ptr[i] = 0
				}
				return phys
			}
		} else {
			run_len = 0
		}
	}
	return 0
}

pmm_alloc_page :: proc "contextless" () -> u64 {
	return pmm_alloc_contiguous(1)
}

pmm_free_pages :: proc "contextless" (phys: u64, count: u64) {
	if phys == 0 || (phys & (PAGE_SIZE - 1)) != 0 {
		return
	}
	start_pg := phys / PAGE_SIZE
	for i := u64(0); i < count; i += 1 {
		pmm_set_free(start_pg + i)
	}
}

pmm_free_page :: proc "contextless" (phys: u64) {
	pmm_free_pages(phys, 1)
}

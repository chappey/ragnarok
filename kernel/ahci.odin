package kernel

// Polling SATA AHCI (Advanced Host Controller Interface) driver.
// Targets PCI class 0x01 / subclass 0x06 / progif 0x01 (Dell OptiPlex 7020, QEMU AHCI, etc.).

AHCI_MAX_PORTS :: 8

AHCI_GHC_AE    :: u32(1 << 31)
AHCI_CMD_ST    :: u32(1 << 0)
AHCI_CMD_FRE   :: u32(1 << 4)
AHCI_CMD_FR    :: u32(1 << 14)
AHCI_CMD_CR    :: u32(1 << 15)
AHCI_SIG_ATA   :: u32(0x00000101)

ATA_CMD_IDENTIFY      :: u8(0xEC)
ATA_CMD_READ_DMA_EXT  :: u8(0x25)
ATA_CMD_WRITE_DMA_EXT :: u8(0x35)

AHCI_Cmd_Header :: struct #packed {
	flags:    u16, // bits 0..4: CFL (dwords), bit 6: Write (W)
	prdtl:    u16, // PRDT entry count
	prdbc:    u32, // PRD byte count transferred
	ctba:     u32, // Command Table Base low
	ctbau:    u32, // Command Table Base high
	reserved: [4]u32,
}

AHCI_PRDT_Entry :: struct #packed {
	dba:      u32, // Data Base Address low
	dbau:     u32, // Data Base Address high
	reserved: u32,
	dbc:      u32, // bits 0..21: byte count - 1
}

AHCI_Cmd_Table :: struct #packed {
	cfis:     [64]u8,
	acmd:     [16]u8,
	reserved: [48]u8,
	prdt:     [1]AHCI_PRDT_Entry,
}

AHCI_Port_Dev :: struct {
	port_base: u64,
	clb_phys:  u64, // +0x000 CmdList, +0x400 FIS, +0x800 CmdTable[0]
	dma_phys:  u64, // 4 KiB DMA bounce buffer (8 sectors)
	sectors:   u64,
}

g_ahci_ports: [AHCI_MAX_PORTS]AHCI_Port_Dev
g_ahci_count: int

ahci_port_stop :: proc "contextless" (pb: u64) {
	cmd := mmio_read32(pb + 0x18)
	cmd &~= AHCI_CMD_ST | AHCI_CMD_FRE
	mmio_write32(pb + 0x18, cmd)
	for i := 0; i < 500_000; i += 1 {
		c := mmio_read32(pb + 0x18)
		if (c & (AHCI_CMD_FR | AHCI_CMD_CR)) == 0 {
			break
		}
		arch_pause()
	}
}

ahci_port_start :: proc "contextless" (pb: u64) {
	for i := 0; i < 500_000; i += 1 {
		if (mmio_read32(pb + 0x18) & AHCI_CMD_CR) == 0 {
			break
		}
		arch_pause()
	}
	cmd := mmio_read32(pb + 0x18)
	cmd |= AHCI_CMD_FRE
	mmio_write32(pb + 0x18, cmd)
	cmd |= AHCI_CMD_ST
	mmio_write32(pb + 0x18, cmd)
}

ahci_issue_cmd :: proc "contextless" (
	p: ^AHCI_Port_Dev,
	ata_cmd: u8,
	lba: u64,
	sector_count: u16,
	data_phys: u64,
	byte_len: u32,
	is_write: bool,
) -> bool {
	pb := p.port_base

	// Wait until drive is not BSY/DRQ
	for i := 0; i < 1_000_000; i += 1 {
		if (mmio_read32(pb + 0x20) & 0x88) == 0 {
			break
		}
		arch_pause()
	}

	// Clear pending interrupt status
	mmio_write32(pb + 0x10, 0xFFFF_FFFF)

	cmd_hdr := (^AHCI_Cmd_Header)(uintptr(p.clb_phys))
	ct_phys := p.clb_phys + 0x800
	ct      := (^AHCI_Cmd_Table)(uintptr(ct_phys))

	// Zero command table CFIS
	for i := 0; i < 64; i += 1 {
		ct.cfis[i] = 0
	}

	// H2D Register FIS (20 bytes = 5 dwords)
	ct.cfis[0]  = 0x27 // FIS_TYPE_REG_H2D
	ct.cfis[1]  = 0x80 // Command bit
	ct.cfis[2]  = ata_cmd
	ct.cfis[4]  = u8(lba & 0xFF)
	ct.cfis[5]  = u8((lba >> 8) & 0xFF)
	ct.cfis[6]  = u8((lba >> 16) & 0xFF)
	ct.cfis[7]  = 0x40 if ata_cmd != ATA_CMD_IDENTIFY else 0x00 // LBA mode
	ct.cfis[8]  = u8((lba >> 24) & 0xFF)
	ct.cfis[9]  = u8((lba >> 32) & 0xFF)
	ct.cfis[10] = u8((lba >> 40) & 0xFF)
	ct.cfis[12] = u8(sector_count & 0xFF)
	ct.cfis[13] = u8((sector_count >> 8) & 0xFF)

	// PRDT entry 0
	ct.prdt[0].dba      = u32(data_phys & 0xFFFF_FFFF)
	ct.prdt[0].dbau     = u32(data_phys >> 32)
	ct.prdt[0].reserved = 0
	ct.prdt[0].dbc      = (byte_len - 1) & 0x3F_FFFF

	// Command Header slot 0
	flags := u16(5) // 5 dwords = 20-byte H2D FIS
	if is_write {
		flags |= (1 << 6)
	}
	cmd_hdr.flags = flags
	cmd_hdr.prdtl = 1
	cmd_hdr.prdbc = 0
	cmd_hdr.ctba  = u32(ct_phys & 0xFFFF_FFFF)
	cmd_hdr.ctbau = u32(ct_phys >> 32)

	arch_mfence()
	mmio_write32(pb + 0x38, 1) // Issue slot 0

	// Poll CI bit 0 and TFD error bit
	for i := 0; i < 5_000_000; i += 1 {
		if (mmio_read32(pb + 0x38) & 1) == 0 {
			if (mmio_read32(pb + 0x20) & 0x01) != 0 {
				return false
			}
			return true
		}
		if (mmio_read32(pb + 0x10) & (1 << 30)) != 0 { // Task File Error Status
			return false
		}
		arch_pause()
	}
	return false
}

ahci_block_read :: proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr) -> bool {
	p := (^AHCI_Port_Dev)(dev.driver_data)
	dst := ([^]u8)(buf)
	rem := count
	cur_lba := lba
	off := u32(0)

	for rem > 0 {
		chunk := rem if rem <= 8 else 8 // max 8 sectors = 4 KiB bounce page
		bytes := chunk * 512
		if !ahci_issue_cmd(p, ATA_CMD_READ_DMA_EXT, cur_lba, u16(chunk), p.dma_phys, bytes, false) {
			return false
		}
		src := ([^]u8)(uintptr(p.dma_phys))
		for i := u32(0); i < bytes; i += 1 {
			dst[off + i] = src[i]
		}
		off += bytes
		cur_lba += u64(chunk)
		rem -= chunk
	}
	return true
}

ahci_block_write :: proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr) -> bool {
	p := (^AHCI_Port_Dev)(dev.driver_data)
	src := ([^]u8)(buf)
	rem := count
	cur_lba := lba
	off := u32(0)

	for rem > 0 {
		chunk := rem if rem <= 8 else 8
		bytes := chunk * 512
		dst := ([^]u8)(uintptr(p.dma_phys))
		for i := u32(0); i < bytes; i += 1 {
			dst[i] = src[off + i]
		}
		if !ahci_issue_cmd(p, ATA_CMD_WRITE_DMA_EXT, cur_lba, u16(chunk), p.dma_phys, bytes, true) {
			return false
		}
		off += bytes
		cur_lba += u64(chunk)
		rem -= chunk
	}
	return true
}

ahci_init_port :: proc "contextless" (pb: u64) {
	if g_ahci_count >= AHCI_MAX_PORTS {
		return
	}
	ssts := mmio_read32(pb + 0x28)
	det  := ssts & 0x0F
	ipm  := (ssts >> 8) & 0x0F
	if det != 3 || ipm != 1 {
		return
	}
	sig := mmio_read32(pb + 0x24)
	if sig != AHCI_SIG_ATA {
		return
	}

	clb := pmm_alloc_page()
	dma := pmm_alloc_page()
	if clb == 0 || dma == 0 {
		return
	}

	ahci_port_stop(pb)
	mmio_write32(pb + 0x00, u32(clb & 0xFFFF_FFFF))
	mmio_write32(pb + 0x04, u32(clb >> 32))
	fis := clb + 0x400
	mmio_write32(pb + 0x08, u32(fis & 0xFFFF_FFFF))
	mmio_write32(pb + 0x0C, u32(fis >> 32))
	mmio_write32(pb + 0x30, 0xFFFF_FFFF) // Clear SERR
	mmio_write32(pb + 0x10, 0xFFFF_FFFF) // Clear IS
	ahci_port_start(pb)

	idx := g_ahci_count
	g_ahci_ports[idx] = AHCI_Port_Dev{
		port_base = pb,
		clb_phys  = clb,
		dma_phys  = dma,
		sectors   = 0,
	}
	p := &g_ahci_ports[idx]

	if !ahci_issue_cmd(p, ATA_CMD_IDENTIFY, 0, 1, dma, 512, false) {
		pmm_free_page(clb)
		pmm_free_page(dma)
		return
	}

	id := ([^]u16)(uintptr(dma))
	// LBA48 sector count at words 100..103; fallback to LBA28 at words 60..61
	lba48 := u64(id[100]) | (u64(id[101]) << 16) | (u64(id[102]) << 32) | (u64(id[103]) << 48)
	if lba48 == 0 {
		lba48 = u64(id[60]) | (u64(id[61]) << 16)
	}
	p.sectors = lba48
	g_ahci_count += 1

	block_register("ahci", rawptr(p), 512, lba48, ahci_block_read, ahci_block_write)
}

ahci_init :: proc "contextless" () {
	g_ahci_count = 0
	for i := 0; i < g_pci_count; i += 1 {
		d := &g_pci_devs[i]
		if d.class != 0x01 || d.subclass != 0x06 || d.progif != 0x01 {
			continue
		}
		pci_enable_mmio_dma(d)
		abar := pci_read_mmio_bar(d, 5)
		if abar == 0 {
			continue
		}
		// Enable AHCI mode
		ghc := mmio_read32(abar + 0x04)
		mmio_write32(abar + 0x04, ghc | AHCI_GHC_AE)

		pi := mmio_read32(abar + 0x0C)
		for port := u32(0); port < 32; port += 1 {
			if (pi & (u32(1) << port)) != 0 {
				ahci_init_port(abar + 0x100 + u64(port) * 0x80)
			}
		}
	}
}

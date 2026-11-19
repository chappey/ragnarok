package kernel

// PCI Configuration Space scanner (Legacy I/O ports 0xCF8 / 0xCFC).
// Discovers xHCI (USB 3.0), AHCI (SATA), NVMe, VGA, and chipset bridges.

PCI_CONFIG_ADDR :: u16(0xCF8)
PCI_CONFIG_DATA :: u16(0xCFC)
PCI_MAX_DEVICES :: 64

PCI_Device :: struct {
	bus:       u8,
	slot:      u8,
	func:      u8,
	vendor_id: u16,
	device_id: u16,
	class:     u8,
	subclass:  u8,
	progif:    u8,
	header:    u8,
	irq_line:  u8,
}

g_pci_devs:  [PCI_MAX_DEVICES]PCI_Device
g_pci_count: int

pci_addr :: proc "contextless" (bus, slot, func, offset: u8) -> u32 {
	return (u32(1) << 31) |
		(u32(bus) << 16) |
		(u32(slot & 0x1F) << 11) |
		(u32(func & 0x07) << 8) |
		u32(offset & 0xFC)
}

pci_read32 :: proc "contextless" (bus, slot, func, offset: u8) -> u32 {
	arch_outl(PCI_CONFIG_ADDR, pci_addr(bus, slot, func, offset))
	return arch_inl(PCI_CONFIG_DATA)
}

pci_write32 :: proc "contextless" (bus, slot, func, offset: u8, val: u32) {
	arch_outl(PCI_CONFIG_ADDR, pci_addr(bus, slot, func, offset))
	arch_outl(PCI_CONFIG_DATA, val)
}

pci_read16 :: proc "contextless" (bus, slot, func, offset: u8) -> u16 {
	v := pci_read32(bus, slot, func, offset)
	return u16((v >> ((offset & 2) * 8)) & 0xFFFF)
}

pci_read8 :: proc "contextless" (bus, slot, func, offset: u8) -> u8 {
	v := pci_read32(bus, slot, func, offset)
	return u8((v >> ((offset & 3) * 8)) & 0xFF)
}

// Read 32-bit or 64-bit MMIO BAR (bar_idx = 0..5). Returns 0 for I/O or unpopulated BARs.
pci_read_mmio_bar :: proc "contextless" (dev: ^PCI_Device, bar_idx: u8) -> u64 {
	if bar_idx > 5 {
		return 0
	}
	off := u8(0x10 + bar_idx * 4)
	lo := pci_read32(dev.bus, dev.slot, dev.func, off)
	if lo == 0 || (lo & 1) != 0 { // I/O space BAR
		return 0
	}
	bar_type := (lo >> 1) & 3
	addr := u64(lo & 0xFFFF_FFF0)
	if bar_type == 2 && bar_idx < 5 { // 64-bit MMIO BAR
		hi := pci_read32(dev.bus, dev.slot, dev.func, off + 4)
		addr |= u64(hi) << 32
	}
	return addr
}

// Enable Bus Master (bit 2) and Memory Space (bit 1) in PCI Command register
pci_enable_mmio_dma :: proc "contextless" (dev: ^PCI_Device) {
	cmd := pci_read32(dev.bus, dev.slot, dev.func, 0x04)
	cmd |= (1 << 1) | (1 << 2)
	pci_write32(dev.bus, dev.slot, dev.func, 0x04, cmd)
}

pci_scan_func :: proc "contextless" (bus, slot, func: u8) {
	id := pci_read32(bus, slot, func, 0x00)
	vendor := u16(id & 0xFFFF)
	if vendor == 0xFFFF || vendor == 0x0000 {
		return
	}
	if g_pci_count >= PCI_MAX_DEVICES {
		return
	}
	cls := pci_read32(bus, slot, func, 0x08)
	hdr := pci_read8(bus, slot, func, 0x0E)
	irq := pci_read8(bus, slot, func, 0x3C)

	g_pci_devs[g_pci_count] = PCI_Device{
		bus       = bus,
		slot      = slot,
		func      = func,
		vendor_id = vendor,
		device_id = u16(id >> 16),
		progif    = u8((cls >> 8) & 0xFF),
		subclass  = u8((cls >> 16) & 0xFF),
		class     = u8((cls >> 24) & 0xFF),
		header    = hdr,
		irq_line  = irq,
	}
	g_pci_count += 1
}

pci_init :: proc "contextless" () {
	g_pci_count = 0
	for bus := u32(0); bus < 256; bus += 1 {
		for slot := u32(0); slot < 32; slot += 1 {
			vendor := pci_read16(u8(bus), u8(slot), 0, 0x00)
			if vendor == 0xFFFF || vendor == 0x0000 {
				continue
			}
			pci_scan_func(u8(bus), u8(slot), 0)
			hdr := pci_read8(u8(bus), u8(slot), 0, 0x0E)
			if (hdr & 0x80) != 0 { // Multi-function device
				for fn := u32(1); fn < 8; fn += 1 {
					pci_scan_func(u8(bus), u8(slot), u8(fn))
				}
			}
		}
	}
}

pci_find_class :: proc "contextless" (class, subclass, progif: u8) -> ^PCI_Device {
	for i := 0; i < g_pci_count; i += 1 {
		d := &g_pci_devs[i]
		if d.class == class && d.subclass == subclass && d.progif == progif {
			return d
		}
	}
	return nil
}

pci_class_name :: proc "contextless" (d: ^PCI_Device) -> string {
	if d.class == 0x01 && d.subclass == 0x01 { return "IDE Storage" }
	if d.class == 0x01 && d.subclass == 0x06 && d.progif == 0x01 { return "AHCI SATA" }
	if d.class == 0x01 && d.subclass == 0x08 && d.progif == 0x02 { return "NVMe SSD" }
	if d.class == 0x02 && d.subclass == 0x00 { return "Ethernet" }
	if d.class == 0x03 && d.subclass == 0x00 { return "VGA Display" }
	if d.class == 0x04 && d.subclass == 0x03 { return "HD Audio" }
	if d.class == 0x06 && d.subclass == 0x00 { return "Host Bridge" }
	if d.class == 0x06 && d.subclass == 0x01 { return "ISA Bridge" }
	if d.class == 0x06 && d.subclass == 0x04 { return "PCI Bridge" }
	if d.class == 0x06 && d.subclass == 0x80 { return "Bridge" }
	if d.class == 0x0C && d.subclass == 0x03 && d.progif == 0x30 { return "xHCI USB3" }
	if d.class == 0x0C && d.subclass == 0x03 && d.progif == 0x20 { return "EHCI USB2" }
	if d.class == 0x0C && d.subclass == 0x03 && d.progif == 0x00 { return "UHCI USB1" }
	if d.class == 0x0C && d.subclass == 0x05 { return "SMBus" }
	return "Device"
}

out_put_hex8 :: proc "contextless" (v: u8) {
	hex := "0123456789ABCDEF"
	out_putc(hex[(v >> 4) & 0xF])
	out_putc(hex[v & 0xF])
}

out_put_hex16 :: proc "contextless" (v: u16) {
	out_put_hex8(u8(v >> 8))
	out_put_hex8(u8(v & 0xFF))
}

pci_print_devices :: proc "contextless" () {
	out_puts("PCI devices (")
	out_put_u64(u64(g_pci_count))
	out_puts(" found):\n")
	for i := 0; i < g_pci_count; i += 1 {
		d := &g_pci_devs[i]
		out_puts("  ")
		out_put_hex8(d.bus)
		out_putc(':')
		out_put_hex8(d.slot)
		out_putc('.')
		out_putc(u8('0' + d.func))
		out_puts("  ")
		out_put_hex16(d.vendor_id)
		out_putc(':')
		out_put_hex16(d.device_id)
		out_puts("  cls=")
		out_put_hex8(d.class)
		out_putc('/')
		out_put_hex8(d.subclass)
		out_putc('/')
		out_put_hex8(d.progif)
		out_puts("  ")
		out_puts(pci_class_name(d))
		out_puts("\n")
	}
}

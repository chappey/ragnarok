package kernel

// Polling xHCI (USB 3.0) Host Controller + USB HID Boot Keyboard driver.
// Targets PCI class 0x0C / subclass 0x03 / progif 0x30.
// Supports 32-byte & 64-byte contexts (CSZ), BIOS->OS handoff (USBLEGSUP),
// Scratchpad Buffers, and Boot Protocol keyboards (QEMU, ThinkPad T480, OptiPlex 7020).

XHCI_RING_SIZE :: u32(64)

// TRB Types
TRB_NORMAL          :: u32(1)
TRB_SETUP_STAGE     :: u32(2)
TRB_DATA_STAGE      :: u32(3)
TRB_STATUS_STAGE    :: u32(4)
TRB_LINK            :: u32(6)
TRB_ENABLE_SLOT     :: u32(9)
TRB_ADDRESS_DEVICE  :: u32(11)
TRB_CONFIGURE_EP    :: u32(12)
TRB_TRANSFER_EVENT  :: u32(32)
TRB_CMD_COMPLETION  :: u32(33)

XHCI_TRB :: struct #packed {
	param:   u64,
	status:  u32,
	control: u32,
}

XHCI_ERST_Entry :: struct #packed {
	ring_base: u64,
	ring_size: u32,
	reserved:  u32,
}

XHCI_Ring :: struct {
	phys:    u64,
	enq:     u32,
	cycle:   u32,
}

XHCI_Ctrl :: struct {
	present:        bool,
	kbd_ready:      bool,
	bar0:           u64,
	op_base:        u64,
	rt_base:        u64,
	db_base:        u64,
	ctx_size:       u64, // 32 or 64 bytes (HCCPARAMS1.CSZ)
	max_slots:      u32,
	max_ports:      u32,
	dcbaa_phys:     u64,
	cmd_ring:       XHCI_Ring,
	evt_ring_phys:  u64,
	evt_deq:        u32,
	evt_cycle:      u32,
	// Active HID Boot Keyboard state
	kbd_slot:       u32,
	kbd_dci:        u32,
	kbd_mps:        u32,
	kbd_ep0_ring:   XHCI_Ring,
	kbd_int_ring:   XHCI_Ring,
	kbd_buf_phys:   u64,
	prev_keys:      [6]u8,
	key_q:          [32]u8,
	key_head:       u32,
	key_tail:       u32,
}

g_xhci: XHCI_Ctrl

// USB HID Usage ID (0x00..0x38) -> US QWERTY ASCII
g_hid_normal := [64]u8{
	0,   0,   0,   0,   'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l',
	'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '1', '2',
	'3', '4', '5', '6', '7', '8', '9', '0', '\n', 0x1B, 0x08, '\t', ' ', '-', '=', '[',
	']', '\\', 0,  ';', '\'', '`', ',', '.', '/', 0,   0,   0,   0,   0,   0,   0,
}

g_hid_shift := [64]u8{
	0,   0,   0,   0,   'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L',
	'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '!', '@',
	'#', '$', '%', '^', '&', '*', '(', ')', '\n', 0x1B, 0x08, '\t', ' ', '_', '+', '{',
	'}', '|', 0,   ':', '"',  '~', '<', '>', '?', 0,   0,   0,   0,   0,   0,   0,
}

xhci_ring_init :: proc "contextless" (r: ^XHCI_Ring, phys: u64) {
	r.phys  = phys
	r.enq   = 0
	r.cycle = 1
	// Place Link TRB at last slot (XHCI_RING_SIZE - 1) pointing back to slot 0 with TC=1
	trbs := ([^]XHCI_TRB)(uintptr(phys))
	trbs[XHCI_RING_SIZE - 1] = XHCI_TRB{
		param   = phys,
		status  = 0,
		control = (TRB_LINK << 10) | (1 << 1), // Toggle Cycle (TC)
	}
}

xhci_ring_push :: proc "contextless" (r: ^XHCI_Ring, param: u64, status: u32, ctrl_no_cycle: u32) {
	trbs := ([^]XHCI_TRB)(uintptr(r.phys))
	trbs[r.enq] = XHCI_TRB{
		param   = param,
		status  = status,
		control = ctrl_no_cycle | (r.cycle & 1),
	}
	r.enq += 1
	if r.enq == XHCI_RING_SIZE - 1 {
		// Update Link TRB cycle bit to match current cycle, then wrap and flip cycle
		trbs[XHCI_RING_SIZE - 1].control = (TRB_LINK << 10) | (1 << 1) | (r.cycle & 1)
		r.enq = 0
		r.cycle ~= 1
	}
}

xhci_ring_doorbell :: proc "contextless" (slot: u32, target: u32) {
	arch_mfence()
	mmio_write32(g_xhci.db_base + u64(slot) * 4, target)
}

xhci_evt_pop :: proc "contextless" () -> (XHCI_TRB, bool) {
	arch_mfence()
	trbs := ([^]XHCI_TRB)(uintptr(g_xhci.evt_ring_phys))
	ev := trbs[g_xhci.evt_deq]
	if (ev.control & 1) != g_xhci.evt_cycle {
		return XHCI_TRB{}, false
	}
	g_xhci.evt_deq += 1
	if g_xhci.evt_deq == XHCI_RING_SIZE {
		g_xhci.evt_deq = 0
		g_xhci.evt_cycle ~= 1
	}
	// Update Interrupter 0 ERDP (clear EHB bit 3 by writing 1 to it)
	erdp := g_xhci.evt_ring_phys + u64(g_xhci.evt_deq) * 16
	mmio_write64(g_xhci.rt_base + 0x20 + 0x18, erdp | (1 << 3))
	return ev, true
}

xhci_wait_event :: proc "contextless" (want_type: u32) -> (XHCI_TRB, bool) {
	for i := 0; i < 3_000_000; i += 1 {
		if ev, ok := xhci_evt_pop(); ok {
			t := (ev.control >> 10) & 0x3F
			if t == want_type {
				return ev, true
			}
		}
		arch_pause()
	}
	return XHCI_TRB{}, false
}

xhci_cmd :: proc "contextless" (param: u64, ctrl: u32) -> (XHCI_TRB, bool) {
	xhci_ring_push(&g_xhci.cmd_ring, param, 0, ctrl)
	xhci_ring_doorbell(0, 0)
	ev, ok := xhci_wait_event(TRB_CMD_COMPLETION)
	if !ok {
		return ev, false
	}
	cc := (ev.status >> 24) & 0xFF
	return ev, (cc == 1) // 1 = Success
}

xhci_ctrl_transfer :: proc "contextless" (
	slot_id: u32,
	ep0: ^XHCI_Ring,
	bm_req_type: u8,
	b_req: u8,
	w_val: u16,
	w_idx: u16,
	w_len: u16,
	data_phys: u64,
) -> bool {
	setup_pkt := u64(bm_req_type) |
		(u64(b_req) << 8) |
		(u64(w_val) << 16) |
		(u64(w_idx) << 32) |
		(u64(w_len) << 48)

	trt := u32(0) // No Data Stage
	if w_len > 0 {
		trt = u32(3) if (bm_req_type & 0x80) != 0 else u32(2) // 3=IN, 2=OUT
	}
	// Setup Stage TRB (IDT = bit 6)
	xhci_ring_push(ep0, setup_pkt, 8, (TRB_SETUP_STAGE << 10) | (trt << 16) | (1 << 6))

	if w_len > 0 {
		dir := u32(1 << 16) if (bm_req_type & 0x80) != 0 else u32(0)
		xhci_ring_push(ep0, data_phys, u32(w_len), (TRB_DATA_STAGE << 10) | dir)
	}

	// Status Stage TRB (DIR opposite of data; IN if no data; IOC = bit 5)
	stat_dir := u32(0)
	if w_len == 0 || (bm_req_type & 0x80) == 0 {
		stat_dir = u32(1 << 16)
	}
	xhci_ring_push(ep0, 0, 0, (TRB_STATUS_STAGE << 10) | stat_dir | (1 << 5))

	xhci_ring_doorbell(slot_id, 1) // DCI 1 = EP0
	ev, ok := xhci_wait_event(TRB_TRANSFER_EVENT)
	if !ok {
		return false
	}
	cc := (ev.status >> 24) & 0xFF
	return (cc == 1 || cc == 13) // 1 = Success, 13 = Short Packet
}

xhci_ctx_dw :: proc "contextless" (base_phys: u64, ctx_idx: u64, dw_idx: u64) -> ^u32 {
	return (^u32)(uintptr(base_phys + ctx_idx * g_xhci.ctx_size + dw_idx * 4))
}

xhci_bios_handoff :: proc "contextless" (bar0: u64, hcc1: u32) {
	xecp := u64((hcc1 >> 16) & 0xFFFF) << 2
	if xecp == 0 {
		return
	}
	off := xecp
	for guard := 0; guard < 32 && off != 0; guard += 1 {
		v := mmio_read32(bar0 + off)
		cap_id := v & 0xFF
		if cap_id == 1 { // USBLEGSUP
			mmio_write32(bar0 + off, v | (1 << 24)) // Set OS Owned
			for i := 0; i < 1_000_000; i += 1 {
				if (mmio_read32(bar0 + off) & (1 << 16)) == 0 {
					break
				}
				arch_pause()
			}
			// Disable legacy SMIs in USBLEGCTLSTS
			mmio_write32(bar0 + off + 4, 0)
			return
		}
		next := u64((v >> 8) & 0xFF) << 2
		if next == 0 {
			break
		}
		off += next
	}
}

xhci_queue_kbd_transfer :: proc "contextless" () {
	// Normal TRB for 8-byte HID boot keyboard report, IOC=1 (bit 5), ISP=1 (bit 2)
	xhci_ring_push(&g_xhci.kbd_int_ring, g_xhci.kbd_buf_phys, 8, (TRB_NORMAL << 10) | (1 << 5) | (1 << 2))
	xhci_ring_doorbell(g_xhci.kbd_slot, g_xhci.kbd_dci)
}

xhci_try_port :: proc "contextless" (port: u32) -> bool {
	portsc_addr := g_xhci.op_base + 0x400 + u64(port - 1) * 0x10
	sc := mmio_read32(portsc_addr)
	if (sc & 1) == 0 { // CCS == 0 (no device)
		return false
	}

	// Reset port if not enabled yet (preserve PP bit 9, avoid clearing RW1C bits accidentally)
	if (sc & 2) == 0 {
		mmio_write32(portsc_addr, (sc & 0x0E00_C3E0) | (1 << 4)) // PR = 1
		for i := 0; i < 2_000_000; i += 1 {
			sc = mmio_read32(portsc_addr)
			if (sc & (1 << 4)) == 0 && (sc & 2) != 0 {
				break
			}
			arch_pause()
		}
	}
	sc = mmio_read32(portsc_addr)
	if (sc & 2) == 0 { // Still not enabled
		return false
	}
	// Clear change bits (CSC/PEC/PRC)
	mmio_write32(portsc_addr, (sc & 0x0E00_C3E0) | 0x00FE_0000)

	speed := (sc >> 10) & 0x0F
	mps0 := u32(8)
	if speed == 3 {
		mps0 = 64
	} else if speed >= 4 {
		mps0 = 512
	}

	// 1. Enable Slot
	ev, ok := xhci_cmd(0, TRB_ENABLE_SLOT << 10)
	if !ok {
		return false
	}
	slot_id := (ev.control >> 24) & 0xFF
	if slot_id == 0 || slot_id > g_xhci.max_slots {
		return false
	}

	dev_ctx := pmm_alloc_page()
	in_ctx  := pmm_alloc_page()
	ep0_pg  := pmm_alloc_page()
	dma_pg  := pmm_alloc_page()
	if dev_ctx == 0 || in_ctx == 0 || ep0_pg == 0 || dma_pg == 0 {
		return false
	}

	dcbaa := ([^]u64)(uintptr(g_xhci.dcbaa_phys))
	dcbaa[slot_id] = dev_ctx

	ep0: XHCI_Ring
	xhci_ring_init(&ep0, ep0_pg)

	// 2. Build Input Context for Address Device (Add Slot + EP0)
	xhci_ctx_dw(in_ctx, 0, 1)^ = (1 << 0) | (1 << 1) // Add Context Flags
	// Slot Context (index 1)
	xhci_ctx_dw(in_ctx, 1, 0)^ = (u32(1) << 27) | (speed << 20) // Context Entries=1, Speed
	xhci_ctx_dw(in_ctx, 1, 1)^ = port << 16                     // Root Hub Port Number
	// EP0 Context (index 2)
	xhci_ctx_dw(in_ctx, 2, 1)^ = (u32(3) << 1) | (u32(4) << 3) | (mps0 << 16) // CErr=3, Control, MPS
	xhci_ctx_dw(in_ctx, 2, 2)^ = u32((ep0_pg & 0xFFFF_FFFF) | 1)              // TR Deq lo | DCS=1
	xhci_ctx_dw(in_ctx, 2, 3)^ = u32(ep0_pg >> 32)                            // TR Deq hi
	xhci_ctx_dw(in_ctx, 2, 4)^ = 8                                            // Avg TRB Len

	_, ok = xhci_cmd(in_ctx, (TRB_ADDRESS_DEVICE << 10) | (slot_id << 24))
	if !ok {
		return false
	}

	// 3. GET_DESCRIPTOR (Configuration, first 9 bytes, then full length)
	if !xhci_ctrl_transfer(slot_id, &ep0, 0x80, 6, 0x0200, 0, 9, dma_pg) {
		return false
	}
	cfg := ([^]u8)(uintptr(dma_pg))
	total_len := u16(cfg[2]) | (u16(cfg[3]) << 8)
	if total_len < 9 || total_len > 1024 {
		return false
	}
	if !xhci_ctrl_transfer(slot_id, &ep0, 0x80, 6, 0x0200, 0, total_len, dma_pg) {
		return false
	}

	// 4. Parse Configuration Descriptor for HID Boot Keyboard (class=3, sub=1, proto=1)
	cfg_val := cfg[5]
	in_kbd_iface := false
	kbd_iface := u8(0)
	kbd_ep_addr := u8(0)
	kbd_mps := u16(8)
	kbd_interval := u8(10)

	pos := u16(0)
	for pos + 2 <= total_len {
		dlen  := u16(cfg[pos])
		dtype := cfg[pos + 1]
		if dlen < 2 || pos + dlen > total_len {
			break
		}
		if dtype == 4 && dlen >= 9 { // Interface Descriptor
			if cfg[pos + 5] == 3 && cfg[pos + 6] == 1 && cfg[pos + 7] == 1 {
				in_kbd_iface = true
				kbd_iface = cfg[pos + 2]
			} else {
				in_kbd_iface = false
			}
		} else if dtype == 5 && dlen >= 7 && in_kbd_iface { // Endpoint Descriptor
			ep_addr := cfg[pos + 2]
			ep_attr := cfg[pos + 3]
			if (ep_addr & 0x80) != 0 && (ep_attr & 0x03) == 3 { // Interrupt IN
				kbd_ep_addr  = ep_addr
				kbd_mps      = u16(cfg[pos + 4]) | (u16(cfg[pos + 5]) << 8)
				kbd_interval = cfg[pos + 6]
				break
			}
		}
		pos += dlen
	}

	if kbd_ep_addr == 0 {
		return false
	}

	// 5. SET_CONFIGURATION, SET_PROTOCOL(0=Boot), SET_IDLE(0)
	_ = xhci_ctrl_transfer(slot_id, &ep0, 0x00, 9, u16(cfg_val), 0, 0, 0)
	_ = xhci_ctrl_transfer(slot_id, &ep0, 0x21, 11, 0, u16(kbd_iface), 0, 0)
	_ = xhci_ctrl_transfer(slot_id, &ep0, 0x21, 10, 0, u16(kbd_iface), 0, 0)

	// 6. Configure Interrupt IN Endpoint
	ep_num := u32(kbd_ep_addr & 0x0F)
	dci    := ep_num * 2 + 1 // IN endpoint DCI
	int_pg := pmm_alloc_page()
	if int_pg == 0 {
		return false
	}

	// Zero input context
	in_q := ([^]u64)(uintptr(in_ctx))
	for i := 0; i < 512; i += 1 {
		in_q[i] = 0
	}

	// Convert USB bInterval to xHCI Interval (2^n * 125us)
	xhci_iv := u32(6) // ~8ms default
	if speed <= 2 { // Low/Full speed: bInterval is in ms (1..255)
		ms := u32(kbd_interval)
		if ms < 1 { ms = 1 }
		// 2^(iv-3) ms -> find highest bit
		iv := u32(3)
		for (u32(1) << (iv - 3)) < ms && iv < 10 {
			iv += 1
		}
		xhci_iv = iv
	} else {
		iv := u32(kbd_interval)
		if iv >= 1 && iv <= 16 {
			xhci_iv = iv - 1
		}
	}

	xhci_ctx_dw(in_ctx, 0, 1)^ = (1 << 0) | (u32(1) << dci) // Add Slot + Interrupt IN EP
	xhci_ctx_dw(in_ctx, 1, 0)^ = (dci << 27) | (speed << 20)
	xhci_ctx_dw(in_ctx, 1, 1)^ = port << 16

	ep_ctx_idx := u64(1 + dci)
	xhci_ctx_dw(in_ctx, ep_ctx_idx, 0)^ = xhci_iv << 16
	xhci_ctx_dw(in_ctx, ep_ctx_idx, 1)^ = (u32(3) << 1) | (u32(7) << 3) | (u32(kbd_mps) << 16) // Interrupt IN
	xhci_ctx_dw(in_ctx, ep_ctx_idx, 2)^ = u32((int_pg & 0xFFFF_FFFF) | 1)
	xhci_ctx_dw(in_ctx, ep_ctx_idx, 3)^ = u32(int_pg >> 32)
	xhci_ctx_dw(in_ctx, ep_ctx_idx, 4)^ = (u32(kbd_mps) << 16) | 8 // Max ESIT Payload | Avg TRB Len

	_, ok = xhci_cmd(in_ctx, (TRB_CONFIGURE_EP << 10) | (slot_id << 24))
	if !ok {
		return false
	}

	g_xhci.kbd_ready    = true
	g_xhci.kbd_slot     = slot_id
	g_xhci.kbd_dci      = dci
	g_xhci.kbd_mps      = u32(kbd_mps)
	g_xhci.kbd_ep0_ring = ep0
	xhci_ring_init(&g_xhci.kbd_int_ring, int_pg)
	g_xhci.kbd_buf_phys = dma_pg

	xhci_queue_kbd_transfer()
	return true
}

xhci_init :: proc "contextless" () {
	g_xhci.present   = false
	g_xhci.kbd_ready = false

	dev := pci_find_class(0x0C, 0x03, 0x30)
	if dev == nil {
		return
	}
	pci_enable_mmio_dma(dev)
	bar0 := pci_read_mmio_bar(dev, 0)
	if bar0 == 0 {
		return
	}

	caplen := u64(mmio_read8(bar0 + 0x00))
	hcs1   := mmio_read32(bar0 + 0x04)
	hcs2   := mmio_read32(bar0 + 0x08)
	hcc1   := mmio_read32(bar0 + 0x10)
	dboff  := u64(mmio_read32(bar0 + 0x14) & ~u32(3))
	rtsoff := u64(mmio_read32(bar0 + 0x18) & ~u32(0x1F))

	// Claim ownership from UEFI/BIOS (essential on real ThinkPad / OptiPlex!)
	xhci_bios_handoff(bar0, hcc1)

	op_base := bar0 + caplen
	rt_base := bar0 + rtsoff
	db_base := bar0 + dboff

	// Stop controller & wait for HCH
	cmd := mmio_read32(op_base + 0x00)
	mmio_write32(op_base + 0x00, cmd & ~u32(1))
	for i := 0; i < 1_000_000; i += 1 {
		if (mmio_read32(op_base + 0x04) & 1) != 0 {
			break
		}
		arch_pause()
	}

	// Reset controller (HCRST) & wait for HCRST==0 and CNR==0
	mmio_write32(op_base + 0x00, 1 << 1)
	for i := 0; i < 2_000_000; i += 1 {
		if (mmio_read32(op_base + 0x00) & (1 << 1)) == 0 &&
		   (mmio_read32(op_base + 0x04) & (1 << 11)) == 0 {
			break
		}
		arch_pause()
	}

	max_slots := hcs1 & 0xFF
	if max_slots > 32 { max_slots = 32 }
	max_ports := (hcs1 >> 24) & 0xFF

	dcbaa_pg := pmm_alloc_page()
	cmd_pg   := pmm_alloc_page()
	evt_pg   := pmm_alloc_page()
	erst_pg  := pmm_alloc_page()
	if dcbaa_pg == 0 || cmd_pg == 0 || evt_pg == 0 || erst_pg == 0 {
		return
	}

	// Allocate Scratchpad Buffers if required by controller (real Intel xHCI requires this!)
	sp_hi := (hcs2 >> 21) & 0x1F
	sp_lo := (hcs2 >> 27) & 0x1F
	num_sp := (sp_hi << 5) | sp_lo
	if num_sp > 0 {
		if num_sp > 64 { num_sp = 64 }
		sp_arr_pg := pmm_alloc_page()
		if sp_arr_pg != 0 {
			sp_arr := ([^]u64)(uintptr(sp_arr_pg))
			for i := u32(0); i < num_sp; i += 1 {
				sp_arr[i] = pmm_alloc_page()
			}
			dcbaa := ([^]u64)(uintptr(dcbaa_pg))
			dcbaa[0] = sp_arr_pg
		}
	}

	g_xhci.present       = true
	g_xhci.bar0          = bar0
	g_xhci.op_base       = op_base
	g_xhci.rt_base       = rt_base
	g_xhci.db_base       = db_base
	g_xhci.ctx_size      = 64 if (hcc1 & (1 << 2)) != 0 else 32
	g_xhci.max_slots     = max_slots
	g_xhci.max_ports     = max_ports
	g_xhci.dcbaa_phys    = dcbaa_pg
	g_xhci.evt_ring_phys = evt_pg
	g_xhci.evt_deq       = 0
	g_xhci.evt_cycle     = 1

	xhci_ring_init(&g_xhci.cmd_ring, cmd_pg)

	// Program CONFIG, DCBAAP, CRCR
	mmio_write32(op_base + 0x38, max_slots)
	mmio_write64(op_base + 0x30, dcbaa_pg)
	mmio_write64(op_base + 0x18, cmd_pg | 1) // RCS = 1

	// Program Interrupter 0 Event Ring (polling mode)
	erst := (^XHCI_ERST_Entry)(uintptr(erst_pg))
	erst.ring_base = evt_pg
	erst.ring_size = XHCI_RING_SIZE
	erst.reserved  = 0

	ir0 := rt_base + 0x20
	mmio_write32(ir0 + 0x08, 1)       // ERSTSZ = 1
	mmio_write64(ir0 + 0x18, evt_pg)  // ERDP
	mmio_write64(ir0 + 0x10, erst_pg) // ERSTBA
	mmio_write32(ir0 + 0x00, 0)       // IMAN (polling)

	// Start controller (RS = 1)
	arch_mfence()
	mmio_write32(op_base + 0x00, 1)
	for i := 0; i < 1_000_000; i += 1 {
		if (mmio_read32(op_base + 0x04) & 1) == 0 {
			break
		}
		arch_pause()
	}

	// Scan root hub ports for the first HID Boot Keyboard
	for p := u32(1); p <= max_ports; p += 1 {
		if xhci_try_port(p) {
			break
		}
	}
}

xhci_key_push :: proc "contextless" (ch: u8) {
	next := (g_xhci.key_head + 1) & 31
	if next != g_xhci.key_tail {
		g_xhci.key_q[g_xhci.key_head] = ch
		g_xhci.key_head = next
	}
}

xhci_process_kbd_report :: proc "contextless" () {
	rep := ([^]u8)(uintptr(g_xhci.kbd_buf_phys))
	mods  := rep[0]
	shift := (mods & 0x22) != 0 // Left or Right Shift
	ctrl  := (mods & 0x11) != 0 // Left or Right Ctrl

	for i := 0; i < 6; i += 1 {
		k := rep[2 + i]
		if k == 0 || k >= 64 {
			continue
		}
		// Only emit on newly pressed keys (edge-triggered)
		was_down := false
		for j := 0; j < 6; j += 1 {
			if g_xhci.prev_keys[j] == k {
				was_down = true
				break
			}
		}
		if !was_down {
			ch := g_hid_shift[k] if shift else g_hid_normal[k]
			if ctrl && (ch == 'l' || ch == 'L') {
				xhci_key_push(0x0C)
			} else if ch != 0 {
				xhci_key_push(ch)
			}
		}
	}

	for i := 0; i < 6; i += 1 {
		g_xhci.prev_keys[i] = rep[2 + i]
	}
}

xhci_poll_char :: proc "contextless" () -> (u8, bool) {
	if g_xhci.kbd_ready {
		// Drain pending events from Event Ring
		for guard := 0; guard < 16; guard += 1 {
			ev, ok := xhci_evt_pop()
			if !ok {
				break
			}
			t := (ev.control >> 10) & 0x3F
			slot := (ev.control >> 24) & 0xFF
			if t == TRB_TRANSFER_EVENT && slot == g_xhci.kbd_slot {
				xhci_process_kbd_report()
				xhci_queue_kbd_transfer()
			}
		}
	}

	if g_xhci.key_head != g_xhci.key_tail {
		ch := g_xhci.key_q[g_xhci.key_tail]
		g_xhci.key_tail = (g_xhci.key_tail + 1) & 31
		return ch, true
	}
	return 0, false
}

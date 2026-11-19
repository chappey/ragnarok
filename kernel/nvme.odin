package kernel

// Polling NVMe (NVM Express) SSD driver.
// Targets PCI class 0x01 / subclass 0x08 / progif 0x02 (ThinkPad T480, QEMU NVMe, etc.).

NVME_MAX_CTRLS :: 4
NVME_Q_DEPTH   :: u16(64)

NVME_ADMIN_CREATE_SQ :: u8(0x01)
NVME_ADMIN_CREATE_CQ :: u8(0x05)
NVME_ADMIN_IDENTIFY  :: u8(0x06)

NVME_IO_WRITE :: u8(0x01)
NVME_IO_READ  :: u8(0x02)

NVMe_SQE :: struct #packed {
	opcode: u8,
	flags:  u8,
	cid:    u16,
	nsid:   u32,
	rsvd:   u64,
	mptr:   u64,
	prp1:   u64,
	prp2:   u64,
	cdw10:  u32,
	cdw11:  u32,
	cdw12:  u32,
	cdw13:  u32,
	cdw14:  u32,
	cdw15:  u32,
}

NVMe_CQE :: struct #packed {
	dw0:    u32,
	dw1:    u32,
	sq_hd:  u16,
	sq_id:  u16,
	cid:    u16,
	status: u16, // bit 0 = Phase Tag (P), bits 1..15 = Status Code
}

NVMe_Queue :: struct {
	sq_phys: u64,
	cq_phys: u64,
	sq_tail: u16,
	cq_head: u16,
	phase:   u16,
	qid:     u16,
}

NVMe_Ctrl :: struct {
	bar0:       u64,
	stride:     u64,
	admin_q:    NVMe_Queue,
	io_q:       NVMe_Queue,
	dma_phys:   u64, // 4 KiB DMA bounce buffer
	next_cid:   u16,
	block_size: u32,
	ns_blocks:  u64,
}

g_nvme_ctrls: [NVME_MAX_CTRLS]NVMe_Ctrl
g_nvme_count: int

nvme_submit_and_wait :: proc "contextless" (c: ^NVMe_Ctrl, q: ^NVMe_Queue, cmd: ^NVMe_SQE) -> bool {
	c.next_cid += 1
	cmd.cid = c.next_cid

	sq := ([^]NVMe_SQE)(uintptr(q.sq_phys))
	sq[q.sq_tail] = cmd^
	q.sq_tail = (q.sq_tail + 1) % NVME_Q_DEPTH

	arch_mfence()
	sq_db := c.bar0 + 0x1000 + u64(2 * q.qid) * c.stride
	mmio_write32(sq_db, u32(q.sq_tail))

	cq := ([^]NVMe_CQE)(uintptr(q.cq_phys))
	for i := 0; i < 5_000_000; i += 1 {
		arch_mfence()
		cqe := cq[q.cq_head]
		if (cqe.status & 1) == q.phase {
			ok := ((cqe.status >> 1) == 0)
			q.cq_head += 1
			if q.cq_head == NVME_Q_DEPTH {
				q.cq_head = 0
				q.phase ~= 1
			}
			cq_db := c.bar0 + 0x1000 + u64(2 * q.qid + 1) * c.stride
			mmio_write32(cq_db, u32(q.cq_head))
			return ok
		}
		arch_pause()
	}
	return false
}

nvme_block_io :: proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr, is_write: bool) -> bool {
	c := (^NVMe_Ctrl)(dev.driver_data)
	bs := c.block_size
	if bs == 0 || bs > 4096 {
		return false
	}
	max_per_page := 4096 / bs
	raw := ([^]u8)(buf)
	rem := count
	cur_lba := lba
	off := u32(0)

	for rem > 0 {
		chunk := rem if rem <= max_per_page else max_per_page
		bytes := chunk * bs
		dma := ([^]u8)(uintptr(c.dma_phys))

		if is_write {
			for i := u32(0); i < bytes; i += 1 {
				dma[i] = raw[off + i]
			}
		}

		cmd := NVMe_SQE{
			opcode = NVME_IO_WRITE if is_write else NVME_IO_READ,
			nsid   = 1,
			prp1   = c.dma_phys,
			cdw10  = u32(cur_lba & 0xFFFF_FFFF),
			cdw11  = u32(cur_lba >> 32),
			cdw12  = chunk - 1, // 0-based NLB
		}
		if !nvme_submit_and_wait(c, &c.io_q, &cmd) {
			return false
		}

		if !is_write {
			for i := u32(0); i < bytes; i += 1 {
				raw[off + i] = dma[i]
			}
		}

		off += bytes
		cur_lba += u64(chunk)
		rem -= chunk
	}
	return true
}

nvme_block_read :: proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr) -> bool {
	return nvme_block_io(dev, lba, count, buf, false)
}

nvme_block_write :: proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr) -> bool {
	return nvme_block_io(dev, lba, count, buf, true)
}

nvme_init_ctrl :: proc "contextless" (dev: ^PCI_Device) {
	if g_nvme_count >= NVME_MAX_CTRLS {
		return
	}
	pci_enable_mmio_dma(dev)
	bar0 := pci_read_mmio_bar(dev, 0)
	if bar0 == 0 {
		return
	}

	cap := mmio_read64(bar0 + 0x00)
	dstrd := (cap >> 32) & 0x0F
	stride := u64(4) << dstrd

	// 1. Disable controller and wait for CSTS.RDY == 0
	cc := mmio_read32(bar0 + 0x14)
	if (cc & 1) != 0 {
		mmio_write32(bar0 + 0x14, cc & ~u32(1))
		for i := 0; i < 2_000_000; i += 1 {
			if (mmio_read32(bar0 + 0x1C) & 1) == 0 {
				break
			}
			arch_pause()
		}
	}

	asq := pmm_alloc_page()
	acq := pmm_alloc_page()
	isq := pmm_alloc_page()
	icq := pmm_alloc_page()
	dma := pmm_alloc_page()
	if asq == 0 || acq == 0 || isq == 0 || icq == 0 || dma == 0 {
		return
	}

	// 2. Configure Admin Queues (64 entries each)
	aqa := (u32(NVME_Q_DEPTH - 1) << 16) | u32(NVME_Q_DEPTH - 1)
	mmio_write32(bar0 + 0x24, aqa)
	mmio_write64(bar0 + 0x28, asq)
	mmio_write64(bar0 + 0x30, acq)

	// 3. Enable controller: IOCQES=4 (16B), IOSQES=6 (64B), EN=1
	mmio_write32(bar0 + 0x14, (u32(4) << 20) | (u32(6) << 16) | 1)
	ready := false
	for i := 0; i < 2_000_000; i += 1 {
		if (mmio_read32(bar0 + 0x1C) & 1) != 0 {
			ready = true
			break
		}
		arch_pause()
	}
	if !ready {
		return
	}

	idx := g_nvme_count
	g_nvme_ctrls[idx] = NVMe_Ctrl{
		bar0     = bar0,
		stride   = stride,
		admin_q  = NVMe_Queue{sq_phys = asq, cq_phys = acq, phase = 1, qid = 0},
		io_q     = NVMe_Queue{sq_phys = isq, cq_phys = icq, phase = 1, qid = 1},
		dma_phys = dma,
	}
	c := &g_nvme_ctrls[idx]

	// 4. Identify Namespace 1 (CNS = 0)
	id_cmd := NVMe_SQE{
		opcode = NVME_ADMIN_IDENTIFY,
		nsid   = 1,
		prp1   = dma,
		cdw10  = 0,
	}
	if !nvme_submit_and_wait(c, &c.admin_q, &id_cmd) {
		return
	}
	ns_ptr := ([^]u8)(uintptr(dma))
	nsze := (^u64)(uintptr(dma))^
	flbas := ns_ptr[26] & 0x0F
	lbaf  := (^u32)(uintptr(dma + 128 + u64(flbas) * 4))^
	lbads := (lbaf >> 16) & 0xFF
	block_size := u32(1) << lbads
	if block_size < 512 || block_size > 4096 {
		block_size = 512
	}
	c.block_size = block_size
	c.ns_blocks  = nsze

	// 5. Create I/O Completion Queue (QID = 1, PC = 1)
	cq_cmd := NVMe_SQE{
		opcode = NVME_ADMIN_CREATE_CQ,
		prp1   = icq,
		cdw10  = (u32(NVME_Q_DEPTH - 1) << 16) | 1,
		cdw11  = 1, // Physically Contiguous
	}
	if !nvme_submit_and_wait(c, &c.admin_q, &cq_cmd) {
		return
	}

	// 6. Create I/O Submission Queue (QID = 1, CQID = 1, PC = 1)
	sq_cmd := NVMe_SQE{
		opcode = NVME_ADMIN_CREATE_SQ,
		prp1   = isq,
		cdw10  = (u32(NVME_Q_DEPTH - 1) << 16) | 1,
		cdw11  = (1 << 16) | 1,
	}
	if !nvme_submit_and_wait(c, &c.admin_q, &sq_cmd) {
		return
	}

	g_nvme_count += 1
	block_register("nvme", rawptr(c), block_size, nsze, nvme_block_read, nvme_block_write)
}

nvme_init :: proc "contextless" () {
	g_nvme_count = 0
	for i := 0; i < g_pci_count; i += 1 {
		d := &g_pci_devs[i]
		if d.class == 0x01 && d.subclass == 0x08 && d.progif == 0x02 {
			nvme_init_ctrl(d)
		}
	}
}

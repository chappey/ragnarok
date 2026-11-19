package kernel

// Unified Block_Device abstraction shared by AHCI (SATA), NVMe, and future storage drivers.

BLOCK_MAX_DEVS :: 16

Block_Read_Proc  :: #type proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr) -> bool
Block_Write_Proc :: #type proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr) -> bool

Block_Device :: struct {
	name:         string,
	driver_data:  rawptr,
	block_size:   u32,
	total_blocks: u64,
	read:         Block_Read_Proc,
	write:        Block_Write_Proc,
}

g_block_devs:  [BLOCK_MAX_DEVS]Block_Device
g_block_count: int

block_register :: proc "contextless" (
	name: string,
	driver_data: rawptr,
	block_size: u32,
	total_blocks: u64,
	read_fn: Block_Read_Proc,
	write_fn: Block_Write_Proc,
) -> ^Block_Device {
	if g_block_count >= BLOCK_MAX_DEVS {
		return nil
	}
	idx := g_block_count
	g_block_count += 1
	g_block_devs[idx] = Block_Device{
		name         = name,
		driver_data  = driver_data,
		block_size   = block_size,
		total_blocks = total_blocks,
		read         = read_fn,
		write        = write_fn,
	}
	return &g_block_devs[idx]
}

block_read :: proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr) -> bool {
	if dev == nil || dev.read == nil || count == 0 {
		return false
	}
	return dev.read(dev, lba, count, buf)
}

block_write :: proc "contextless" (dev: ^Block_Device, lba: u64, count: u32, buf: rawptr) -> bool {
	if dev == nil || dev.write == nil || count == 0 {
		return false
	}
	return dev.write(dev, lba, count, buf)
}

block_write_devices :: proc "contextless" (ob: ^Out_Buf) {
	ob_puts(ob, "Block devices (")
	ob_put_u64(ob, u64(g_block_count))
	ob_puts(ob, " found):\n")
	for i := 0; i < g_block_count; i += 1 {
		d := &g_block_devs[i]
		mib := (d.total_blocks * u64(d.block_size)) / (1024 * 1024)
		ob_puts(ob, "  [")
		ob_put_u64(ob, u64(i))
		ob_puts(ob, "] ")
		ob_puts(ob, d.name)
		ob_puts(ob, "  ")
		ob_put_u64(ob, d.total_blocks)
		ob_puts(ob, " x ")
		ob_put_u64(ob, u64(d.block_size))
		ob_puts(ob, "B  (")
		ob_put_u64(ob, mib)
		ob_puts(ob, " MiB)\n")
	}
}

block_print_devices :: proc "contextless" () {
	out_puts("Block devices (")
	out_put_u64(u64(g_block_count))
	out_puts(" found):\n")
	for i := 0; i < g_block_count; i += 1 {
		d := &g_block_devs[i]
		mib := (d.total_blocks * u64(d.block_size)) / (1024 * 1024)
		out_puts("  [")
		out_put_u64(u64(i))
		out_puts("] ")
		out_puts(d.name)
		out_puts("  ")
		out_put_u64(d.total_blocks)
		out_puts(" x ")
		out_put_u64(u64(d.block_size))
		out_puts("B  (")
		out_put_u64(mib)
		out_puts(" MiB)\n")
	}
}

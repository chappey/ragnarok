package kernel

import "base:intrinsics"

mmio_read8 :: proc "contextless" (addr: u64) -> u8 {
	return intrinsics.volatile_load((^u8)(uintptr(addr)))
}

mmio_write8 :: proc "contextless" (addr: u64, val: u8) {
	intrinsics.volatile_store((^u8)(uintptr(addr)), val)
}

mmio_read16 :: proc "contextless" (addr: u64) -> u16 {
	return intrinsics.volatile_load((^u16)(uintptr(addr)))
}

mmio_write16 :: proc "contextless" (addr: u64, val: u16) {
	intrinsics.volatile_store((^u16)(uintptr(addr)), val)
}

mmio_read32 :: proc "contextless" (addr: u64) -> u32 {
	return intrinsics.volatile_load((^u32)(uintptr(addr)))
}

mmio_write32 :: proc "contextless" (addr: u64, val: u32) {
	intrinsics.volatile_store((^u32)(uintptr(addr)), val)
}

mmio_read64 :: proc "contextless" (addr: u64) -> u64 {
	lo := u64(mmio_read32(addr))
	hi := u64(mmio_read32(addr + 4))
	return lo | (hi << 32)
}

mmio_write64 :: proc "contextless" (addr: u64, val: u64) {
	mmio_write32(addr, u32(val & 0xFFFF_FFFF))
	mmio_write32(addr + 4, u32(val >> 32))
}

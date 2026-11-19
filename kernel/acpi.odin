package kernel

// Minimal ACPI RSDP/XSDT/FADT/DSDT parser for clean bare-metal S5 poweroff
// on real UEFI hardware (ThinkPad T480, OptiPlex 7020) as well as QEMU.

g_acpi_pm1a_cnt: u16
g_acpi_slp_typa: u16
g_acpi_ready:    bool

acpi_read_u32 :: proc "contextless" (addr: u64) -> u32 {
	b := ([^]u8)(uintptr(addr))
	return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24)
}

acpi_read_u64 :: proc "contextless" (addr: u64) -> u64 {
	return u64(acpi_read_u32(addr)) | (u64(acpi_read_u32(addr + 4)) << 32)
}

acpi_sig_eq :: proc "contextless" (addr: u64, sig: string) -> bool {
	if addr == 0 || len(sig) != 4 {
		return false
	}
	b := ([^]u8)(uintptr(addr))
	return b[0] == sig[0] && b[1] == sig[1] && b[2] == sig[2] && b[3] == sig[3]
}

acpi_parse_s5_dsdt :: proc "contextless" (dsdt: u64) -> (u16, bool) {
	if dsdt == 0 || !acpi_sig_eq(dsdt, "DSDT") {
		return 0, false
	}
	dsdt_len := acpi_read_u32(dsdt + 4)
	if dsdt_len < 40 || dsdt_len > 4 * 1024 * 1024 {
		return 0, false
	}
	b := ([^]u8)(uintptr(dsdt))
	limit := int(dsdt_len) - 8
	for i := 36; i < limit; i += 1 {
		if b[i] == '_' && b[i + 1] == 'S' && b[i + 2] == '5' && b[i + 3] == '_' {
			// Verify preceding NameOp (0x08) or backslash prefix to avoid false matches
			if i > 0 && (b[i - 1] == 0x08 || b[i - 1] == '\\' || b[i - 1] == '.') {
				p := i + 4
				if p < int(dsdt_len) && b[p] == 0x12 { // PackageOp
					p += 1
					if p >= int(dsdt_len) { continue }
					// PkgLength: top 2 bits indicate extra length bytes (0..3)
					extra := int(b[p] >> 6)
					p += 1 + extra // skip PkgLength
					p += 1         // skip NumElements
					if p >= int(dsdt_len) { continue }
					op := b[p]
					if op == 0x00 { // ZeroOp
						return 0, true
					} else if op == 0x01 { // OneOp
						return 1, true
					} else if op == 0x0A && p + 1 < int(dsdt_len) { // BytePrefix
						return u16(b[p + 1]) & 0x7, true
					}
				}
			}
		}
	}
	return 0, false
}

acpi_parse_fadt :: proc "contextless" (fadt: u64) {
	fadt_len := acpi_read_u32(fadt + 4)
	if fadt_len < 68 {
		return
	}
	pm1a := u16(acpi_read_u32(fadt + 64) & 0xFFFF)
	if pm1a == 0 && fadt_len >= 184 {
		// Check X_PM1a_CNT_BLK GAS at offset 172 (space_id 1 = System I/O)
		space := ([^]u8)(uintptr(fadt + 172))[0]
		if space == 1 {
			pm1a = u16(acpi_read_u64(fadt + 176) & 0xFFFF)
		}
	}
	if pm1a == 0 {
		return
	}

	dsdt := u64(0)
	if fadt_len >= 148 {
		dsdt = acpi_read_u64(fadt + 140) // X_DSDT
	}
	if dsdt == 0 {
		dsdt = u64(acpi_read_u32(fadt + 40)) // DSDT
	}

	slp_typa := u16(0)
	s5_ok := false
	if typ, ok := acpi_parse_s5_dsdt(dsdt); ok {
		slp_typa = typ
		s5_ok = true
	}

	g_acpi_pm1a_cnt = pm1a
	g_acpi_slp_typa = slp_typa
	g_acpi_ready    = s5_ok
}

acpi_init :: proc "contextless" (st: ^EFI_System_Table) {
	g_acpi_ready    = false
	g_acpi_pm1a_cnt = 0
	g_acpi_slp_typa = 0

	if st == nil || st.configuration_table == nil {
		return
	}

	rsdp_20 := u64(0)
	rsdp_10 := u64(0)
	count := int(st.number_of_table_entries)
	for i := 0; i < count; i += 1 {
		ent := st.configuration_table[i]
		if efi_guid_eq(ent.vendor_guid, EFI_ACPI_20_TABLE_GUID) {
			rsdp_20 = u64(uintptr(ent.vendor_table))
		} else if efi_guid_eq(ent.vendor_guid, EFI_ACPI_10_TABLE_GUID) {
			rsdp_10 = u64(uintptr(ent.vendor_table))
		}
	}

	rsdp := rsdp_20 if rsdp_20 != 0 else rsdp_10
	if rsdp == 0 {
		return
	}

	rb := ([^]u8)(uintptr(rsdp))
	if rb[0] != 'R' || rb[1] != 'S' || rb[2] != 'D' || rb[3] != ' ' ||
	   rb[4] != 'P' || rb[5] != 'T' || rb[6] != 'R' || rb[7] != ' ' {
		return
	}

	rev := rb[15]
	if rev >= 2 {
		xsdt := acpi_read_u64(rsdp + 24)
		if acpi_sig_eq(xsdt, "XSDT") {
			xlen := acpi_read_u32(xsdt + 4)
			if xlen >= 36 {
				entries := (xlen - 36) / 8
				for i := u32(0); i < entries; i += 1 {
					tbl := acpi_read_u64(xsdt + 36 + u64(i) * 8)
					if acpi_sig_eq(tbl, "FACP") {
						acpi_parse_fadt(tbl)
						return
					}
				}
			}
		}
	}

	rsdt := u64(acpi_read_u32(rsdp + 16))
	if acpi_sig_eq(rsdt, "RSDT") {
		rlen := acpi_read_u32(rsdt + 4)
		if rlen >= 36 {
			entries := (rlen - 36) / 4
			for i := u32(0); i < entries; i += 1 {
				tbl := u64(acpi_read_u32(rsdt + 36 + u64(i) * 4))
				if acpi_sig_eq(tbl, "FACP") {
					acpi_parse_fadt(tbl)
					return
				}
			}
		}
	}
}

acpi_poweroff :: proc "contextless" () {
	if g_acpi_ready && g_acpi_pm1a_cnt != 0 {
		arch_cli()
		arch_outw(g_acpi_pm1a_cnt, (g_acpi_slp_typa << 10) | (1 << 13))
	}
	arch_poweroff()
}

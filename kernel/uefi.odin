package kernel

EFI_Status :: distinct uintptr
EFI_Handle :: distinct rawptr

EFI_SUCCESS :: EFI_Status(0)

EFI_GUID :: struct {
	data1: u32,
	data2: u16,
	data3: u16,
	data4: [8]u8,
}

EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID :: EFI_GUID{
	0x9042a9de, 0x23dc, 0x4a38,
	{0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a},
}

EFI_LOADED_IMAGE_PROTOCOL_GUID :: EFI_GUID{
	0x5B1B31A1, 0x9562, 0x11D2,
	{0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B},
}

EFI_ACPI_20_TABLE_GUID :: EFI_GUID{
	0x8868E871, 0xE4F1, 0x11D3,
	{0xBC, 0x22, 0x00, 0x80, 0xC7, 0x3C, 0x88, 0x81},
}

EFI_ACPI_10_TABLE_GUID :: EFI_GUID{
	0xEB9D2D30, 0x2D88, 0x11D3,
	{0x9A, 0x16, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D},
}

efi_guid_eq :: proc "contextless" (a, b: EFI_GUID) -> bool {
	if a.data1 != b.data1 || a.data2 != b.data2 || a.data3 != b.data3 {
		return false
	}
	for i := 0; i < 8; i += 1 {
		if a.data4[i] != b.data4[i] {
			return false
		}
	}
	return true
}

EFI_Table_Header :: struct {
	signature:   u64,
	revision:    u32,
	header_size: u32,
	crc32:       u32,
	reserved:    u32,
}

EFI_Memory_Descriptor :: struct {
	type:           u32,
	_pad:           u32,
	physical_start: u64,
	virtual_start:  u64,
	number_of_pages: u64,
	attribute:      u64,
}

EFI_GOP_Mode_Info :: struct {
	version:               u32,
	horizontal_resolution: u32,
	vertical_resolution:   u32,
	pixel_format:          u32,
	pixel_info:            [4]u32,
	pixels_per_scan_line:  u32,
}

EFI_GOP_Mode :: struct {
	max_mode:          u32,
	mode:              u32,
	info:              ^EFI_GOP_Mode_Info,
	size_of_info:      uintptr,
	frame_buffer_base: u64,
	frame_buffer_size: uintptr,
}

EFI_GOP_Query_Mode :: #type proc "c" (
	this:          ^EFI_GOP,
	mode_number:   u32,
	size_of_info:  ^uintptr,
	info:          ^^EFI_GOP_Mode_Info,
) -> EFI_Status

EFI_GOP_Set_Mode :: #type proc "c" (
	this:        ^EFI_GOP,
	mode_number: u32,
) -> EFI_Status

EFI_GOP :: struct {
	query_mode: EFI_GOP_Query_Mode,
	set_mode:   EFI_GOP_Set_Mode,
	blt:        rawptr,
	mode:       ^EFI_GOP_Mode,
}

EFI_Get_Memory_Map :: #type proc "c" (
	memory_map_size: ^uintptr,
	memory_map:      rawptr,
	map_key:         ^uintptr,
	descriptor_size: ^uintptr,
	descriptor_ver:  ^u32,
) -> EFI_Status

EFI_Exit_Boot_Services :: #type proc "c" (
	image_handle: EFI_Handle,
	map_key:      uintptr,
) -> EFI_Status

EFI_Locate_Protocol :: #type proc "c" (
	protocol:     ^EFI_GUID,
	registration: rawptr,
	iface:        ^rawptr,
) -> EFI_Status

EFI_Handle_Protocol :: #type proc "c" (
	handle:   EFI_Handle,
	protocol: ^EFI_GUID,
	iface:    ^rawptr,
) -> EFI_Status

EFI_Loaded_Image :: struct {
	revision:          u32,
	_pad0:             u32,
	parent_handle:     EFI_Handle,
	system_table:      ^EFI_System_Table,
	device_handle:     EFI_Handle,
	file_path:         rawptr,
	reserved:          rawptr,
	load_options_size: u32,
	_pad1:             u32,
	load_options:      rawptr,
	image_base:        u64,
	image_size:        u64,
}

EFI_Configuration_Table :: struct {
	vendor_guid:  EFI_GUID,
	vendor_table: rawptr,
}

EFI_Boot_Services :: struct {
	hdr:                                    EFI_Table_Header,
	// Task Priority Services
	raise_tpl:                              rawptr,
	restore_tpl:                            rawptr,
	// Memory Services
	allocate_pages:                         rawptr,
	free_pages:                             rawptr,
	get_memory_map:                         EFI_Get_Memory_Map,
	allocate_pool:                          rawptr,
	free_pool:                              rawptr,
	// Event & Timer Services
	create_event:                           rawptr,
	set_timer:                              rawptr,
	wait_for_event:                         rawptr,
	signal_event:                           rawptr,
	close_event:                            rawptr,
	check_event:                            rawptr,
	// Protocol Handler Services
	install_protocol_interface:             rawptr,
	reinstall_protocol_interface:           rawptr,
	uninstall_protocol_interface:           rawptr,
	handle_protocol:                        EFI_Handle_Protocol,
	reserved:                               rawptr,
	register_protocol_notify:               rawptr,
	locate_handle:                          rawptr,
	locate_device_path:                     rawptr,
	install_configuration_table:            rawptr,
	// Image Services
	load_image:                             rawptr,
	start_image:                            rawptr,
	exit:                                   rawptr,
	unload_image:                           rawptr,
	exit_boot_services:                     EFI_Exit_Boot_Services,
	// Miscellaneous Services
	get_next_monotonic_count:               rawptr,
	stall:                                  rawptr,
	set_watchdog_timer:                     rawptr,
	// DriverSupport Services
	connect_controller:                     rawptr,
	disconnect_controller:                  rawptr,
	// Open and Close Protocol Services
	open_protocol:                          rawptr,
	close_protocol:                         rawptr,
	open_protocol_information:              rawptr,
	// Library Services
	protocols_per_handle:                   rawptr,
	locate_handle_buffer:                   rawptr,
	locate_protocol:                        EFI_Locate_Protocol,
}

EFI_System_Table :: struct {
	hdr:                   EFI_Table_Header,
	firmware_vendor:       rawptr,
	firmware_revision:     u32,
	_pad:                  u32,
	console_in_handle:     EFI_Handle,
	con_in:                rawptr,
	console_out_handle:    EFI_Handle,
	con_out:               rawptr,
	standard_error_handle: EFI_Handle,
	std_err:               rawptr,
	runtime_services:        rawptr,
	boot_services:           ^EFI_Boot_Services,
	number_of_table_entries: uintptr,
	configuration_table:     [^]EFI_Configuration_Table,
}

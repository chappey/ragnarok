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
	handle_protocol:                        rawptr,
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
	runtime_services:      rawptr,
	boot_services:         ^EFI_Boot_Services,
}

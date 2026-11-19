package syscalls

// Leaf syscall interface between Ragnarök kernel (Ring-0) and userspace programs.
// Imports nothing so userspace/ never depends on kernel internals.

SYSCALL_ABI_VERSION :: u32(2)

GFX_WIDTH  :: 640
GFX_HEIGHT :: 480

COL_BLACK       :: u8(0)
COL_BLUE        :: u8(1)
COL_GREEN       :: u8(2)
COL_CYAN        :: u8(3)
COL_RED         :: u8(4)
COL_PURPLE      :: u8(5)
COL_BROWN       :: u8(6)
COL_LTGRAY      :: u8(7)
COL_DKGRAY      :: u8(8)
COL_LTBLUE      :: u8(9)
COL_LTGREEN     :: u8(10)
COL_LTCYAN      :: u8(11)
COL_LTRED       :: u8(12)
COL_LTPURPLE    :: u8(13)
COL_YELLOW      :: u8(14)
COL_WHITE       :: u8(15)
COL_TRANSPARENT :: u8(255)

Dir_Entry :: struct {
	name:     [64]u8,
	name_len: u32,
	size:     u32,
	is_dir:   bool,
}

Cmd_Context :: struct {
	args:   []string,
	in_buf: []u8,
}

Table :: struct {
	abi_version:     u32,
	clear:           proc "contextless" (col: u8),
	plot:            proc "contextless" (x, y: i32, col: u8),
	hline:           proc "contextless" (x0, x1, y: i32, col: u8),
	line:            proc "contextless" (x0, y0, x1, y1: i32, col: u8),
	rect:            proc "contextless" (x, y, w, h: i32, col: u8),
	disc:            proc "contextless" (cx, cy, r: i32, col: u8),
	char:            proc "contextless" (x, y: i32, ch: u8, fg, bg: u8),
	text:            proc "contextless" (x, y: i32, s: string, fg, bg: u8),
	present:         proc "contextless" (),
	set_palette:     proc "contextless" (pal: [16]u32),
	reset_palette:   proc "contextless" (),
	wait_ms_or_key:  proc "contextless" (ms: u32) -> (u8, bool),
	ticks_ms:        proc "contextless" () -> u64,
	rng_next:        proc "contextless" () -> u32,
	isin:            proc "contextless" (angle: i32) -> i32,
	icos:            proc "contextless" (angle: i32) -> i32,
	print:           proc "contextless" (s: string),
	print_bytes:     proc "contextless" (b: []u8),
	alloc:           proc "contextless" (size, align: u64) -> rawptr,
	read_file:       proc "contextless" (path: string) -> ([]u8, bool),
	write_file:      proc "contextless" (path: string, data: []u8) -> bool,
	list_dir:        proc "contextless" (path: string) -> ([]Dir_Entry, bool),
	cwd:             proc "contextless" () -> string,
}

Prg_Entry :: #type proc "c" (sys: ^Table, ctx: ^Cmd_Context) -> i32

App_Proc :: #type proc(sys: ^Table, args: []string) -> int

App_Info :: struct {
	name:    string,
	summary: string,
	usage:   string,
	run:     App_Proc,
}

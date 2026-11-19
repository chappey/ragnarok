package prg

import "base:runtime"
import "../../kernel/syscalls"

// Shared runtime bootstrap, Arena-backed Odin allocator, and helpers for standalone .prg apps.

prg_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	sys := (^syscalls.Table)(allocator_data)
	if sys == nil || sys.alloc == nil {
		return nil, .Mode_Not_Implemented
	}

	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size <= 0 {
			return nil, nil
		}
		ptr := sys.alloc(u64(size), u64(alignment))
		if ptr == nil {
			return nil, .Out_Of_Memory
		}
		if mode == .Alloc {
			b := ([^]u8)(ptr)
			for i := 0; i < size; i += 1 {
				b[i] = 0
			}
		}
		return ([^]u8)(ptr)[:size], nil

	case .Resize, .Resize_Non_Zeroed:
		if size <= 0 {
			return nil, nil
		}
		ptr := sys.alloc(u64(size), u64(alignment))
		if ptr == nil {
			return nil, .Out_Of_Memory
		}
		dst := ([^]u8)(ptr)
		if old_memory != nil && old_size > 0 {
			src := ([^]u8)(old_memory)
			n := old_size if old_size < size else size
			for i := 0; i < n; i += 1 {
				dst[i] = src[i]
			}
		}
		if mode == .Resize && size > old_size {
			for i := old_size; i < size; i += 1 {
				dst[i] = 0
			}
		}
		return dst[:size], nil

	case .Free, .Free_All:
		return nil, nil

	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Query_Features}
		}
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}

run :: proc "contextless" (
	sys: ^syscalls.Table,
	ctx: ^syscalls.Cmd_Context,
	fn: proc(sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> int,
) -> i32 {
	if sys == nil || sys.abi_version != syscalls.SYSCALL_ABI_VERSION {
		return 1
	}
	alloc := runtime.Allocator{
		procedure = prg_allocator_proc,
		data      = rawptr(sys),
	}
	rt_ctx: runtime.Context
	rt_ctx.allocator      = alloc
	rt_ctx.temp_allocator = alloc
	context = rt_ctx
	return i32(fn(sys, ctx))
}

wait_exit :: proc "contextless" (sys: ^syscalls.Table, ms: u32) -> bool {
	k, ok := sys.wait_ms_or_key(ms)
	if !ok {
		return false
	}
	return k == 0x1B || k == 'q' || k == 'Q' || k == '\r' || k == '\n' || k == 0x03
}

want_help :: proc "contextless" (ctx: ^syscalls.Cmd_Context) -> bool {
	if ctx == nil {
		return false
	}
	for i := 1; i < len(ctx.args); i += 1 {
		if ctx.args[i] == "--help" {
			return true
		}
	}
	return false
}

print_u64 :: proc "contextless" (sys: ^syscalls.Table, val: u64) {
	if val == 0 {
		sys.print("0")
		return
	}
	buf: [20]u8
	n := 0
	v := val
	for v > 0 {
		buf[n] = u8('0' + (v % 10))
		v /= 10
		n += 1
	}
	rev: [20]u8
	for i := 0; i < n; i += 1 {
		rev[i] = buf[n - 1 - i]
	}
	sys.print(string(rev[:n]))
}

package kernel

import "base:runtime"

// Growable PMM-backed Arena Allocator + Arena-backed Out_Buf for commands & pipes.
// Default initial chunk: 64 KiB (16 contiguous 4 KiB pages).
// Bulk teardown via arena_destroy() returns every page to PMM with zero leaks.

ARENA_DEFAULT_PAGES :: u64(16) // 64 KiB

Arena_Chunk :: struct {
	next:  ^Arena_Chunk,
	phys:  u64,
	pages: u64,
	used:  u64,
	cap:   u64,
}

Arena :: struct {
	head:        ^Arena_Chunk,
	total_pages: u64,
	total_used:  u64,
}

arena_add_chunk :: proc "contextless" (a: ^Arena, min_bytes: u64) -> ^Arena_Chunk {
	hdr_size := u64(size_of(Arena_Chunk))
	// Align header to 16 bytes
	hdr_aligned := (hdr_size + 15) & ~u64(15)
	need_bytes := hdr_aligned + min_bytes
	pages := (need_bytes + PAGE_SIZE - 1) / PAGE_SIZE
	if pages < ARENA_DEFAULT_PAGES {
		pages = ARENA_DEFAULT_PAGES
	}

	phys := pmm_alloc_contiguous(pages)
	if phys == 0 {
		return nil
	}

	chunk := (^Arena_Chunk)(uintptr(phys))
	chunk.next  = a.head
	chunk.phys  = phys
	chunk.pages = pages
	chunk.used  = hdr_aligned
	chunk.cap   = pages * PAGE_SIZE

	a.head = chunk
	a.total_pages += pages
	return chunk
}

arena_init :: proc "contextless" (a: ^Arena) -> bool {
	a.head        = nil
	a.total_pages = 0
	a.total_used  = 0
	return arena_add_chunk(a, 0) != nil
}

arena_destroy :: proc "contextless" (a: ^Arena) {
	cur := a.head
	for cur != nil {
		next  := cur.next
		phys  := cur.phys
		pages := cur.pages
		pmm_free_pages(phys, pages)
		cur = next
	}
	a.head        = nil
	a.total_pages = 0
	a.total_used  = 0
}

arena_alloc :: proc "contextless" (a: ^Arena, size: u64, align: u64 = 8) -> rawptr {
	if size == 0 {
		return nil
	}
	al := align if align >= 1 else 1
	mask := al - 1

	chunk := a.head
	if chunk != nil {
		aligned := (chunk.used + mask) & ~mask
		if aligned + size <= chunk.cap {
			ptr := rawptr(uintptr(chunk.phys + aligned))
			chunk.used = aligned + size
			a.total_used += size
			return ptr
		}
	}

	chunk = arena_add_chunk(a, size + al)
	if chunk == nil {
		return nil
	}
	aligned := (chunk.used + mask) & ~mask
	ptr := rawptr(uintptr(chunk.phys + aligned))
	chunk.used = aligned + size
	a.total_used += size
	return ptr
}

// Standard Odin runtime.Allocator backed by our PMM Arena
arena_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	a := (^Arena)(allocator_data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size <= 0 {
			return nil, nil
		}
		ptr := arena_alloc(a, u64(size), u64(alignment))
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
		ptr := arena_alloc(a, u64(size), u64(alignment))
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
		// Individual frees are no-ops; arena_destroy reclaims all PMM pages in O(1)
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

arena_allocator :: proc "contextless" (a: ^Arena) -> runtime.Allocator {
	return runtime.Allocator{
		procedure = arena_allocator_proc,
		data      = rawptr(a),
	}
}

// Growable byte output buffer backed by an Arena (powers both direct output & pipes!)
Out_Buf :: struct {
	arena: ^Arena,
	data:  [^]u8,
	len:   int,
	cap:   int,
}

ob_init :: proc "contextless" (ob: ^Out_Buf, a: ^Arena, initial_cap: int = 1024) {
	ob.arena = a
	ob.len   = 0
	ob.cap   = initial_cap
	ob.data  = ([^]u8)(arena_alloc(a, u64(initial_cap), 8))
	if ob.data == nil {
		ob.cap = 0
	}
}

ob_grow :: proc "contextless" (ob: ^Out_Buf, need: int) -> bool {
	if ob.len + need <= ob.cap {
		return true
	}
	new_cap := ob.cap * 2
	if new_cap < 1024 { new_cap = 1024 }
	for new_cap < ob.len + need {
		new_cap *= 2
	}
	new_ptr := ([^]u8)(arena_alloc(ob.arena, u64(new_cap), 8))
	if new_ptr == nil {
		return false
	}
	for i := 0; i < ob.len; i += 1 {
		new_ptr[i] = ob.data[i]
	}
	ob.data = new_ptr
	ob.cap  = new_cap
	return true
}

ob_putc :: proc "contextless" (ob: ^Out_Buf, c: u8) {
	if !ob_grow(ob, 1) {
		return
	}
	ob.data[ob.len] = c
	ob.len += 1
}

ob_puts :: proc "contextless" (ob: ^Out_Buf, s: string) {
	if len(s) == 0 || !ob_grow(ob, len(s)) {
		return
	}
	for i := 0; i < len(s); i += 1 {
		ob.data[ob.len + i] = s[i]
	}
	ob.len += len(s)
}

ob_put_bytes :: proc "contextless" (ob: ^Out_Buf, b: []u8) {
	if len(b) == 0 || !ob_grow(ob, len(b)) {
		return
	}
	for i := 0; i < len(b); i += 1 {
		ob.data[ob.len + i] = b[i]
	}
	ob.len += len(b)
}

ob_put_u64 :: proc "contextless" (ob: ^Out_Buf, val: u64) {
	if val == 0 {
		ob_putc(ob, '0')
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
	for i := n - 1; i >= 0; i -= 1 {
		ob_putc(ob, buf[i])
	}
}

ob_put_hex8 :: proc "contextless" (ob: ^Out_Buf, v: u8) {
	hex := "0123456789ABCDEF"
	ob_putc(ob, hex[(v >> 4) & 0xF])
	ob_putc(ob, hex[v & 0xF])
}

ob_put_hex16 :: proc "contextless" (ob: ^Out_Buf, v: u16) {
	ob_put_hex8(ob, u8(v >> 8))
	ob_put_hex8(ob, u8(v & 0xFF))
}

ob_put_hex64 :: proc "contextless" (ob: ^Out_Buf, val: u64) {
	hex := "0123456789ABCDEF"
	ob_puts(ob, "0x")
	for shift := u64(60); ; shift -= 4 {
		ob_putc(ob, hex[(val >> shift) & 0xF])
		if shift == 0 {
			break
		}
	}
}

ob_bytes :: proc "contextless" (ob: ^Out_Buf) -> []u8 {
	if ob.data == nil || ob.len == 0 {
		return nil
	}
	return ob.data[:ob.len]
}

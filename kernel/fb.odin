package kernel

Framebuffer :: struct {
	base:   [^]u32,
	width:  u32,
	height: u32,
	pitch:  u32, // pixels per scanline
}

g_fb: Framebuffer

fb_clear :: proc "contextless" (color: u32) {
	if g_fb.base == nil {
		return
	}
	for y := u32(0); y < g_fb.height; y += 1 {
		row := y * g_fb.pitch
		for x := u32(0); x < g_fb.width; x += 1 {
			g_fb.base[row + x] = color
		}
	}
}

fb_fill_rect :: proc "contextless" (x0, y0, w, h: u32, color: u32) {
	if g_fb.base == nil {
		return
	}
	for dy := u32(0); dy < h; dy += 1 {
		y := y0 + dy
		if y >= g_fb.height {
			break
		}
		row := y * g_fb.pitch
		for dx := u32(0); dx < w; dx += 1 {
			x := x0 + dx
			if x >= g_fb.width {
				break
			}
			g_fb.base[row + x] = color
		}
	}
}

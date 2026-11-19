package kernel

// Polling PS/2 i8042 keyboard driver (Scancode Set 1, US QWERTY).
// Works in QEMU and on bare-metal laptops with an internal i8042 EC (e.g. ThinkPad T480).

PS2_DATA   :: u16(0x60)
PS2_STATUS :: u16(0x64)

KEY_LEFT   :: u8(0x80)
KEY_RIGHT  :: u8(0x81)
KEY_UP     :: u8(0x82)
KEY_DOWN   :: u8(0x83)
KEY_HOME   :: u8(0x84)
KEY_END    :: u8(0x85)
KEY_DELETE :: u8(0x86)

g_ps2_present:  bool
g_ps2_shift:    bool
g_ps2_ctrl:     bool
g_ps2_caps:     bool
g_ps2_extended: bool

g_scancode_normal := [128]u8{
	0,    0x1B, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0x08, '\t',
	'q',  'w',  'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,  'a',  's',
	'd',  'f',  'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0,  '\\', 'z', 'x', 'c', 'v',
	'b',  'n',  'm', ',', '.', '/', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,    0,
	0,    0,    0,   0,   0,   0,   0,   '7', '8', '9', '-', '4', '5', '6', '+',  '1',
	'2',  '3',  '0', '.', 0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
	0,    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
	0,    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
}

g_scancode_shift := [128]u8{
	0,    0x1B, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0x08, '\t',
	'Q',  'W',  'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0,  'A',  'S',
	'D',  'F',  'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0,   '|', 'Z', 'X', 'C',  'V',
	'B',  'N',  'M', '<', '>', '?', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,    0,
	0,    0,    0,   0,   0,   0,   0,   '7', '8', '9', '-', '4', '5', '6', '+',  '1',
	'2',  '3',  '0', '.', 0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
	0,    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
	0,    0,    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,    0,
}

ps2_init :: proc "contextless" () {
	status := arch_inb(PS2_STATUS)
	if status == 0xFF {
		g_ps2_present = false
		return
	}
	g_ps2_present = true
	// Drain any stale scancodes left over from UEFI boot menu (bounded)
	for i := 0; i < 64; i += 1 {
		if (arch_inb(PS2_STATUS) & 0x01) == 0 {
			break
		}
		_ = arch_inb(PS2_DATA)
	}
}

ps2_poll_char :: proc "contextless" () -> (u8, bool) {
	if !g_ps2_present {
		return 0, false
	}
	status := arch_inb(PS2_STATUS)
	if status == 0xFF || (status & 0x01) == 0 {
		return 0, false
	}
	sc := arch_inb(PS2_DATA)

	// Bit 5 set = AUX/mouse/TrackPoint packet; ignore so it doesn't corrupt keyboard input
	if (status & 0x20) != 0 {
		return 0, false
	}

	if sc == 0xE0 {
		g_ps2_extended = true
		return 0, false
	}
	if g_ps2_extended {
		g_ps2_extended = false
		if (sc & 0x80) != 0 {
			return 0, false
		}
		switch sc {
		case 0x4B: return KEY_LEFT, true
		case 0x4D: return KEY_RIGHT, true
		case 0x48: return KEY_UP, true
		case 0x50: return KEY_DOWN, true
		case 0x47: return KEY_HOME, true
		case 0x4F: return KEY_END, true
		case 0x53: return KEY_DELETE, true
		case 0x1C: return '\n', true
		}
		return 0, false
	}

	released := (sc & 0x80) != 0
	code := sc & 0x7F

	// Modifiers
	if code == 0x2A || code == 0x36 { // Left / Right Shift
		g_ps2_shift = !released
		return 0, false
	}
	if code == 0x1D { // Ctrl
		g_ps2_ctrl = !released
		return 0, false
	}
	if code == 0x3A && !released { // Caps Lock
		g_ps2_caps = !g_ps2_caps
		return 0, false
	}

	if released {
		return 0, false
	}

	ch := g_scancode_shift[code] if g_ps2_shift else g_scancode_normal[code]
	if ch == 0 {
		return 0, false
	}

	// Apply Caps Lock to letters only
	if g_ps2_caps {
		if ch >= 'a' && ch <= 'z' {
			ch -= 32
		} else if ch >= 'A' && ch <= 'Z' {
			ch += 32
		}
	}

	// Ctrl+A..Z -> 0x01..0x1A (readline shortcuts)
	if g_ps2_ctrl && ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
		return ch & 0x1F, true
	}

	return ch, true
}

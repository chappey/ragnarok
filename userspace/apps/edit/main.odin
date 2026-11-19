package main

import "../../prg"
import "../../../kernel/syscalls"

// Standalone full-screen 80x57 text editor backed by syscalls.Table + FAT32.

ED_COLS      :: i32(80)
ED_VIEW_ROWS :: i32(57) // Screen rows 1..57
ED_GUTTER    :: i32(5)  // "NNNN "
ED_TEXT_COLS :: ED_COLS - ED_GUTTER

Editor :: struct {
	filename:     string,
	lines:        [dynamic][dynamic]u8,
	cur_row:      int,
	cur_col:      int,
	scroll_y:     int,
	scroll_x:     int,
	dirty:        bool,
	quit_armed:   bool,
	clip:         [dynamic]u8,
	has_clip:     bool,
	search_query: [64]u8,
	search_len:   int,
	status_msg:   [80]u8,
	status_len:   int,
	status_col:   u8,
}

ed_upper :: proc "contextless" (c: u8) -> u8 {
	if c >= 'a' && c <= 'z' {
		return c - 32
	}
	return c
}

ed_ci_match_at :: proc "contextless" (line: []u8, col: int, query: []u8) -> bool {
	if len(query) == 0 || col < 0 || col + len(query) > len(line) {
		return false
	}
	for i := 0; i < len(query); i += 1 {
		if ed_upper(line[col + i]) != ed_upper(query[i]) {
			return false
		}
	}
	return true
}

ed_is_comment_line :: proc "contextless" (line: []u8) -> bool {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	return i < len(line) && line[i] == '#'
}

ed_set_status :: proc "contextless" (ed: ^Editor, col: u8, s: string) {
	n := len(s)
	if n > len(ed.status_msg) {
		n = len(ed.status_msg)
	}
	for i := 0; i < n; i += 1 {
		ed.status_msg[i] = s[i]
	}
	ed.status_len = n
	ed.status_col = col
}

ed_set_status_u64 :: proc "contextless" (ed: ^Editor, col: u8, prefix: string, num: u64, suffix: string) {
	pos := 0
	append_str :: proc "contextless" (buf: []u8, pos: ^int, s: string) {
		for i := 0; i < len(s) && pos^ < len(buf); i += 1 {
			buf[pos^] = s[i]
			pos^ += 1
		}
	}
	append_str(ed.status_msg[:], &pos, prefix)
	if num == 0 {
		append_str(ed.status_msg[:], &pos, "0")
	} else {
		tmp: [20]u8
		n := 0
		v := num
		for v > 0 {
			tmp[n] = u8('0' + (v % 10))
			v /= 10
			n += 1
		}
		for i := n - 1; i >= 0 && pos < len(ed.status_msg); i -= 1 {
			ed.status_msg[pos] = tmp[i]
			pos += 1
		}
	}
	append_str(ed.status_msg[:], &pos, suffix)
	ed.status_len = pos
	ed.status_col = col
}

ed_fmt_dec :: proc "contextless" (buf: []u8, val: u64) -> string {
	if val == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	tmp: [20]u8
	n := 0
	v := val
	for v > 0 {
		tmp[n] = u8('0' + (v % 10))
		v /= 10
		n += 1
	}
	for i := 0; i < n; i += 1 {
		buf[i] = tmp[n - 1 - i]
	}
	return string(buf[:n])
}

ed_ensure_visible :: proc "contextless" (ed: ^Editor) {
	if len(ed.lines) == 0 {
		return
	}
	if ed.cur_row < 0 { ed.cur_row = 0 }
	if ed.cur_row >= len(ed.lines) { ed.cur_row = len(ed.lines) - 1 }
	line_len := len(ed.lines[ed.cur_row])
	if ed.cur_col < 0 { ed.cur_col = 0 }
	if ed.cur_col > line_len { ed.cur_col = line_len }

	if ed.cur_row < ed.scroll_y {
		ed.scroll_y = ed.cur_row
	} else if ed.cur_row >= ed.scroll_y + int(ED_VIEW_ROWS) {
		ed.scroll_y = ed.cur_row - int(ED_VIEW_ROWS) + 1
	}

	if ed.cur_col < ed.scroll_x {
		ed.scroll_x = ed.cur_col
	} else if ed.cur_col >= ed.scroll_x + int(ED_TEXT_COLS) {
		ed.scroll_x = ed.cur_col - int(ED_TEXT_COLS) + 1
	}
}

ed_load_file :: proc(sys: ^syscalls.Table, ed: ^Editor) {
	data, exists := sys.read_file(ed.filename)
	if !exists {
		first := make([dynamic]u8, 0, 64)
		append(&ed.lines, first)
		ed_set_status(ed, syscalls.COL_LTCYAN, "New file")
		return
	}

	if len(data) == 0 {
		first := make([dynamic]u8, 0, 64)
		append(&ed.lines, first)
		ed_set_status(ed, syscalls.COL_LTGRAY, "Opened empty file")
		return
	}

	start := 0
	for i := 0; i <= len(data); i += 1 {
		if i == len(data) || data[i] == '\n' {
			end := i
			if end > start && data[end - 1] == '\r' {
				end -= 1
			}
			// Do not create a spurious extra blank line after a trailing '\n'
			if !(i == len(data) && start == len(data)) {
				line := make([dynamic]u8, 0, (end - start) + 16)
				for k := start; k < end; k += 1 {
					append(&line, data[k])
				}
				append(&ed.lines, line)
			}
			start = i + 1
		}
	}
	if len(ed.lines) == 0 {
		first := make([dynamic]u8, 0, 64)
		append(&ed.lines, first)
	}
	ed_set_status_u64(ed, syscalls.COL_LTGRAY, "Loaded ", u64(len(data)), " B")
}

ed_render :: proc "contextless" (sys: ^syscalls.Table, ed: ^Editor) {
	// 1. Title bar (row 0)
	sys.rect(0, 0, syscalls.GFX_WIDTH, 8, syscalls.COL_BLUE)
	sys.text(8, 0, "EDIT:", syscalls.COL_YELLOW, syscalls.COL_BLUE)
	sys.text(56, 0, ed.filename, syscalls.COL_WHITE, syscalls.COL_BLUE)
	if ed.dirty {
		dirty_x := i32(56 + len(ed.filename) * 8 + 8)
		if dirty_x < 400 {
			sys.text(dirty_x, 0, "[*]", syscalls.COL_LTRED, syscalls.COL_BLUE)
		}
	}

	// Format right-hand "Ln X/Y Col Z"
	pos_buf: [40]u8
	tmp_buf: [20]u8
	p := 0
	push_s :: proc "contextless" (dst: []u8, p: ^int, s: string) {
		for i := 0; i < len(s) && p^ < len(dst); i += 1 {
			dst[p^] = s[i]
			p^ += 1
		}
	}
	push_s(pos_buf[:], &p, "Ln ")
	push_s(pos_buf[:], &p, ed_fmt_dec(tmp_buf[:], u64(ed.cur_row + 1)))
	push_s(pos_buf[:], &p, "/")
	push_s(pos_buf[:], &p, ed_fmt_dec(tmp_buf[:], u64(len(ed.lines))))
	push_s(pos_buf[:], &p, " Col ")
	push_s(pos_buf[:], &p, ed_fmt_dec(tmp_buf[:], u64(ed.cur_col + 1)))
	pos_str := string(pos_buf[:p])
	pos_x := syscalls.GFX_WIDTH - i32(p + 1) * 8
	sys.text(pos_x, 0, pos_str, syscalls.COL_LTCYAN, syscalls.COL_BLUE)

	// 2. Editor viewport (rows 1..57)
	query := ed.search_query[:ed.search_len]
	for vr := i32(0); vr < ED_VIEW_ROWS; vr += 1 {
		py := (vr + 1) * 8
		sys.rect(0, py, syscalls.GFX_WIDTH, 8, syscalls.COL_BLACK)

		li := ed.scroll_y + int(vr)
		if li >= len(ed.lines) {
			sys.char(0, py, '~', syscalls.COL_DKGRAY, syscalls.COL_BLACK)
			continue
		}

		// 4-digit gutter + space
		num := li + 1
		g_fg := syscalls.COL_LTCYAN if li == ed.cur_row else syscalls.COL_DKGRAY
		d3 := u8('0' + (num / 1000) % 10)
		d2 := u8('0' + (num / 100) % 10)
		d1 := u8('0' + (num / 10) % 10)
		d0 := u8('0' + num % 10)
		if num < 1000 { d3 = ' ' }
		if num < 100  { d2 = ' ' }
		if num < 10   { d1 = ' ' }
		sys.char(0,  py, d3, g_fg, syscalls.COL_BLACK)
		sys.char(8,  py, d2, g_fg, syscalls.COL_BLACK)
		sys.char(16, py, d1, g_fg, syscalls.COL_BLACK)
		sys.char(24, py, d0, g_fg, syscalls.COL_BLACK)

		line := ed.lines[li][:]
		base_fg := syscalls.COL_LTGREEN if ed_is_comment_line(line) else syscalls.COL_WHITE

		// Highlight span countdown when search query matches
		match_rem := 0
		if ed.search_len > 0 && ed.scroll_x > 0 {
			// Check if a match starting before scroll_x spills into view
			back_start := ed.scroll_x - (ed.search_len - 1)
			if back_start < 0 { back_start = 0 }
			for c0 := back_start; c0 < ed.scroll_x; c0 += 1 {
				if ed_ci_match_at(line, c0, query) {
					overlap := c0 + ed.search_len - ed.scroll_x
					if overlap > match_rem {
						match_rem = overlap
					}
				}
			}
		}

		for vc := i32(0); vc < ED_TEXT_COLS; vc += 1 {
			ci := ed.scroll_x + int(vc)
			if ed.search_len > 0 && ci < len(line) && ed_ci_match_at(line, ci, query) {
				if ed.search_len > match_rem {
					match_rem = ed.search_len
				}
			}

			ch := line[ci] if ci < len(line) else u8(' ')
			is_cur := (li == ed.cur_row && ci == ed.cur_col)
			fg := base_fg
			bg := syscalls.COL_BLACK
			if match_rem > 0 && ci < len(line) {
				fg = syscalls.COL_BLACK
				bg = syscalls.COL_LTCYAN
			}
			if is_cur {
				fg = syscalls.COL_BLACK
				bg = syscalls.COL_YELLOW
			}
			if ch != ' ' || bg != syscalls.COL_BLACK {
				sys.char((ED_GUTTER + vc) * 8, py, ch, fg, bg)
			}
			if match_rem > 0 {
				match_rem -= 1
			}
		}
	}

	// 3. Help bar (row 58) & status bar (row 59)
	sys.rect(0, 58 * 8, syscalls.GFX_WIDTH, 8, syscalls.COL_BLUE)
	sys.text(0, 58 * 8, " ^S Save  ^F Find  ^N Next  ^C Copy  ^X Cut  ^V Paste  ^G Goto  ^Q Quit", syscalls.COL_WHITE, syscalls.COL_BLUE)

	sys.rect(0, 59 * 8, syscalls.GFX_WIDTH, 8, syscalls.COL_BLACK)
	if ed.status_len > 0 {
		sys.text(8, 59 * 8, string(ed.status_msg[:ed.status_len]), ed.status_col, syscalls.COL_BLACK)
	}
	sys.present()
}

ed_prompt_minibuffer :: proc "contextless" (sys: ^syscalls.Table, prompt: string, out_buf: []u8) -> (int, bool) {
	n := 0
	for {
		sys.rect(0, 59 * 8, syscalls.GFX_WIDTH, 8, syscalls.COL_BLACK)
		sys.text(8, 59 * 8, prompt, syscalls.COL_YELLOW, syscalls.COL_BLACK)
		px := i32(8 + len(prompt) * 8)
		if n > 0 {
			sys.text(px, 59 * 8, string(out_buf[:n]), syscalls.COL_WHITE, syscalls.COL_BLACK)
		}
		sys.rect(px + i32(n) * 8, 59 * 8, 8, 8, syscalls.COL_YELLOW)
		sys.present()

		k := sys.getc()
		if k == '\r' || k == '\n' {
			return n, true
		}
		if k == 0x1B || k == 0x03 || k == 0x11 {
			return 0, false
		}
		if k == 0x08 || k == 0x7F {
			if n > 0 {
				n -= 1
			}
		} else if k >= 0x20 && k < 0x7F && n < len(out_buf) {
			out_buf[n] = k
			n += 1
		}
	}
}

ed_insert_char :: proc(ed: ^Editor, c: u8) {
	line := &ed.lines[ed.cur_row]
	col := ed.cur_col
	append(line, 0)
	for i := len(line^) - 1; i > col; i -= 1 {
		line^[i] = line^[i - 1]
	}
	line^[col] = c
	ed.cur_col += 1
	ed.dirty = true
}

ed_split_line :: proc(ed: ^Editor) {
	line := &ed.lines[ed.cur_row]
	col := ed.cur_col
	tail := make([dynamic]u8, 0, len(line^) - col + 16)
	for i := col; i < len(line^); i += 1 {
		append(&tail, line^[i])
	}
	resize(line, col)

	append(&ed.lines, tail)
	for r := len(ed.lines) - 1; r > ed.cur_row + 1; r -= 1 {
		ed.lines[r] = ed.lines[r - 1]
	}
	ed.lines[ed.cur_row + 1] = tail
	ed.cur_row += 1
	ed.cur_col = 0
	ed.dirty = true
}

ed_remove_line_at :: proc(ed: ^Editor, idx: int) {
	for r := idx; r + 1 < len(ed.lines); r += 1 {
		ed.lines[r] = ed.lines[r + 1]
	}
	resize(&ed.lines, len(ed.lines) - 1)
}

ed_backspace :: proc(ed: ^Editor) {
	if ed.cur_col > 0 {
		line := &ed.lines[ed.cur_row]
		for i := ed.cur_col; i < len(line^); i += 1 {
			line^[i - 1] = line^[i]
		}
		resize(line, len(line^) - 1)
		ed.cur_col -= 1
		ed.dirty = true
	} else if ed.cur_row > 0 {
		prev := &ed.lines[ed.cur_row - 1]
		cur  := &ed.lines[ed.cur_row]
		join_col := len(prev^)
		for i := 0; i < len(cur^); i += 1 {
			append(prev, cur^[i])
		}
		ed_remove_line_at(ed, ed.cur_row)
		ed.cur_row -= 1
		ed.cur_col = join_col
		ed.dirty = true
	}
}

ed_delete_char :: proc(ed: ^Editor) {
	line := &ed.lines[ed.cur_row]
	if ed.cur_col < len(line^) {
		for i := ed.cur_col + 1; i < len(line^); i += 1 {
			line^[i - 1] = line^[i]
		}
		resize(line, len(line^) - 1)
		ed.dirty = true
	} else if ed.cur_row + 1 < len(ed.lines) {
		next := &ed.lines[ed.cur_row + 1]
		for i := 0; i < len(next^); i += 1 {
			append(line, next^[i])
		}
		ed_remove_line_at(ed, ed.cur_row + 1)
		ed.dirty = true
	}
}

ed_save :: proc(sys: ^syscalls.Table, ed: ^Editor) {
	total := 0
	for r := 0; r < len(ed.lines); r += 1 {
		total += len(ed.lines[r]) + 1
	}
	if len(ed.lines) == 1 && len(ed.lines[0]) == 0 {
		total = 0
	}

	buf := make([]u8, total)
	pos := 0
	if total > 0 {
		for r := 0; r < len(ed.lines); r += 1 {
			line := ed.lines[r][:]
			for k := 0; k < len(line); k += 1 {
				buf[pos] = line[k]
				pos += 1
			}
			buf[pos] = '\n'
			pos += 1
		}
	}

	if !sys.write_file(ed.filename, buf[:pos]) {
		ed_set_status(ed, syscalls.COL_LTRED, "Save failed (use 8.3 name, e.g. TEST.TXT)")
		return
	}
	ed.dirty = false
	ed.quit_armed = false
	ed_set_status_u64(ed, syscalls.COL_LTGREEN, "Saved ", u64(pos), " B")
}

ed_find_next :: proc "contextless" (ed: ^Editor) {
	if ed.search_len == 0 {
		ed_set_status(ed, syscalls.COL_YELLOW, "No active search pattern (^F)")
		return
	}
	query := ed.search_query[:ed.search_len]
	nlines := len(ed.lines)
	for step := 0; step <= nlines; step += 1 {
		r := (ed.cur_row + step) % nlines
		line := ed.lines[r][:]
		start_c := 0
		end_c   := len(line)
		if step == 0 {
			start_c = ed.cur_col + 1
		} else if step == nlines {
			end_c = ed.cur_col + 1
			if end_c > len(line) { end_c = len(line) }
		}
		for c := start_c; c + ed.search_len <= end_c; c += 1 {
			if ed_ci_match_at(line, c, query) {
				ed.cur_row = r
				ed.cur_col = c
				ed_set_status_u64(ed, syscalls.COL_LTCYAN, "Found on line ", u64(r + 1), "")
				return
			}
		}
	}
	ed_set_status(ed, syscalls.COL_LTRED, "Not found")
}

ed_copy_line :: proc(ed: ^Editor) {
	clear(&ed.clip)
	src := ed.lines[ed.cur_row][:]
	for i := 0; i < len(src); i += 1 {
		append(&ed.clip, src[i])
	}
	ed.has_clip = true
	ed_set_status_u64(ed, syscalls.COL_LTCYAN, "Copied line ", u64(ed.cur_row + 1), "")
}

ed_cut_line :: proc(ed: ^Editor) {
	ed_copy_line(ed)
	if len(ed.lines) == 1 {
		clear(&ed.lines[0])
		ed.cur_col = 0
	} else {
		row_num := ed.cur_row + 1
		ed_remove_line_at(ed, ed.cur_row)
		if ed.cur_row >= len(ed.lines) {
			ed.cur_row = len(ed.lines) - 1
		}
		if ed.cur_col > len(ed.lines[ed.cur_row]) {
			ed.cur_col = len(ed.lines[ed.cur_row])
		}
		ed_set_status_u64(ed, syscalls.COL_YELLOW, "Cut line ", u64(row_num), "")
	}
	ed.dirty = true
}

ed_paste_line :: proc(ed: ^Editor) {
	if !ed.has_clip {
		ed_set_status(ed, syscalls.COL_YELLOW, "Clipboard empty")
		return
	}
	if len(ed.lines[ed.cur_row]) == 0 {
		for i := 0; i < len(ed.clip); i += 1 {
			append(&ed.lines[ed.cur_row], ed.clip[i])
		}
		ed.cur_col = len(ed.clip)
	} else {
		pasted := make([dynamic]u8, 0, len(ed.clip) + 16)
		for i := 0; i < len(ed.clip); i += 1 {
			append(&pasted, ed.clip[i])
		}
		append(&ed.lines, pasted)
		insert_idx := ed.cur_row + 1
		for r := len(ed.lines) - 1; r > insert_idx; r -= 1 {
			ed.lines[r] = ed.lines[r - 1]
		}
		ed.lines[insert_idx] = pasted
		ed.cur_row = insert_idx
		ed.cur_col = len(pasted)
	}
	ed.dirty = true
	ed_set_status(ed, syscalls.COL_LTCYAN, "Pasted")
}

ed_goto_line :: proc "contextless" (sys: ^syscalls.Table, ed: ^Editor) {
	buf: [16]u8
	n, ok := ed_prompt_minibuffer(sys, "Goto line: ", buf[:])
	if !ok {
		ed_set_status(ed, syscalls.COL_LTGRAY, "Cancelled")
		return
	}
	if n == 0 {
		return
	}
	val := 0
	for i := 0; i < n; i += 1 {
		c := buf[i]
		if c < '0' || c > '9' {
			ed_set_status(ed, syscalls.COL_LTRED, "Invalid line number")
			return
		}
		val = val * 10 + int(c - '0')
	}
	if val < 1 { val = 1 }
	if val > len(ed.lines) { val = len(ed.lines) }
	ed.cur_row = val - 1
	ed.cur_col = 0
	ed_set_status_u64(ed, syscalls.COL_LTCYAN, "Line ", u64(val), "")
}

app_main :: proc(sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> int {
	if prg.want_help(ctx) {
		sys.print("Usage: edit <file>\n  Full-screen 80x57 FAT32 text editor (^S save, ^F find, ^C/^X/^V line edit, ^Q quit)\n")
		return 0
	}
	if ctx == nil || len(ctx.args) < 2 {
		sys.print("Usage: edit <file>\n")
		return 1
	}

	ed := new(Editor)
	ed.filename   = ctx.args[1]
	ed.lines      = make([dynamic][dynamic]u8, 0, 64)
	ed.clip       = make([dynamic]u8, 0, 80)
	ed.status_col = syscalls.COL_LTGRAY

	ed_load_file(sys, ed)
	sys.clear(syscalls.COL_BLACK)

	for {
		ed_ensure_visible(ed)
		ed_render(sys, ed)

		k := sys.getc()
		if k != 0x11 {
			ed.quit_armed = false
		}

		switch k {
		case 0x11: // Ctrl+Q
			if !ed.dirty || ed.quit_armed {
				return 0
			}
			ed.quit_armed = true
			ed_set_status(ed, syscalls.COL_LTRED, "Unsaved changes! Press ^S to save or ^Q again to quit")

		case 0x13: // Ctrl+S
			ed_save(sys, ed)

		case 0x06: // Ctrl+F
			qbuf: [64]u8
			qn, qok := ed_prompt_minibuffer(sys, "Find: ", qbuf[:])
			if qok && qn > 0 {
				ed.search_len = qn
				for i := 0; i < qn; i += 1 {
					ed.search_query[i] = qbuf[i]
				}
				ed_find_next(ed)
			} else if !qok {
				ed_set_status(ed, syscalls.COL_LTGRAY, "Search cancelled")
			}

		case 0x0E: // Ctrl+N
			ed_find_next(ed)

		case 0x03: // Ctrl+C
			ed_copy_line(ed)

		case 0x18: // Ctrl+X
			ed_cut_line(ed)

		case 0x16: // Ctrl+V
			ed_paste_line(ed)

		case 0x07: // Ctrl+G
			ed_goto_line(sys, ed)

		case syscalls.KEY_LEFT, 0x02:
			if ed.cur_col > 0 {
				ed.cur_col -= 1
			} else if ed.cur_row > 0 {
				ed.cur_row -= 1
				ed.cur_col = len(ed.lines[ed.cur_row])
			}

		case syscalls.KEY_RIGHT:
			if ed.cur_col < len(ed.lines[ed.cur_row]) {
				ed.cur_col += 1
			} else if ed.cur_row + 1 < len(ed.lines) {
				ed.cur_row += 1
				ed.cur_col = 0
			}

		case syscalls.KEY_UP, 0x10:
			if ed.cur_row > 0 {
				ed.cur_row -= 1
			}

		case syscalls.KEY_DOWN:
			if ed.cur_row + 1 < len(ed.lines) {
				ed.cur_row += 1
			}

		case syscalls.KEY_HOME, 0x01:
			ed.cur_col = 0

		case syscalls.KEY_END, 0x05:
			ed.cur_col = len(ed.lines[ed.cur_row])

		case syscalls.KEY_PGUP:
			ed.cur_row -= int(ED_VIEW_ROWS)
			if ed.cur_row < 0 { ed.cur_row = 0 }

		case syscalls.KEY_PGDN:
			ed.cur_row += int(ED_VIEW_ROWS)
			if ed.cur_row >= len(ed.lines) { ed.cur_row = len(ed.lines) - 1 }

		case '\r', '\n':
			ed_split_line(ed)

		case 0x08, 0x7F:
			ed_backspace(ed)

		case syscalls.KEY_DELETE, 0x04:
			ed_delete_char(ed)

		case '\t':
			for s := 0; s < 4; s += 1 {
				ed_insert_char(ed, ' ')
			}

		case:
			if k >= 0x20 && k < 0x7F {
				ed_insert_char(ed, k)
			}
		}
	}
}

@(export, link_name="prg_main")
prg_main :: proc "c" (sys: ^syscalls.Table, ctx: ^syscalls.Cmd_Context) -> i32 {
	return prg.run(sys, ctx, app_main)
}

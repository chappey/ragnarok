package kernel

// Kernel .rsh scripting engine: shell variables, $ expansion, if/else, for..in, and AUTO.RSH.

SCRIPT_MAX_VARS     :: 64
SCRIPT_VAR_NAME_MAX :: 32
SCRIPT_VAR_VAL_MAX  :: 192
SCRIPT_MAX_DEPTH    :: 8
SCRIPT_MAX_ARGS     :: 16
SCRIPT_MAX_EXPAND   :: 1024

Shell_Var :: struct {
	used:     bool,
	name:     [SCRIPT_VAR_NAME_MAX]u8,
	name_len: int,
	val:      [SCRIPT_VAR_VAL_MAX]u8,
	val_len:  int,
}

Script_Flow :: enum {
	Normal,
	Break,
	Continue,
	Return,
}

g_shell_vars:   [SCRIPT_MAX_VARS]Shell_Var
g_last_status:  int
g_script_args:  [SCRIPT_MAX_ARGS]string
g_script_argc:  int
g_script_depth: int

// ---------------------------------------------------------------------------
// Integer parsing / formatting helpers
// ---------------------------------------------------------------------------

parse_i64 :: proc "contextless" (s: string) -> (i64, bool) {
	b := transmute([]u8)s
	if len(b) == 0 {
		return 0, false
	}
	i := 0
	neg := false
	if b[0] == '-' {
		neg = true
		i = 1
	} else if b[0] == '+' {
		i = 1
	}
	if i >= len(b) {
		return 0, false
	}
	acc := u64(0)
	for i < len(b) {
		c := b[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		acc = acc * 10 + u64(c - '0')
		i += 1
	}
	if neg {
		return -i64(acc), true
	}
	return i64(acc), true
}

fmt_i64 :: proc "contextless" (val: i64, buf: []u8) -> string {
	if len(buf) == 0 {
		return ""
	}
	if val == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	neg := val < 0
	v := u64(-val) if neg else u64(val)
	tmp: [24]u8
	n := 0
	for v > 0 {
		tmp[n] = u8('0' + (v % 10))
		v /= 10
		n += 1
	}
	pos := 0
	if neg && pos < len(buf) {
		buf[pos] = '-'
		pos += 1
	}
	for i := n - 1; i >= 0 && pos < len(buf); i -= 1 {
		buf[pos] = tmp[i]
		pos += 1
	}
	return string(buf[:pos])
}

// ---------------------------------------------------------------------------
// Variable table & $var expansion
// ---------------------------------------------------------------------------

var_is_ident_start :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

var_is_ident_char :: proc "contextless" (c: u8) -> bool {
	return var_is_ident_start(c) || (c >= '0' && c <= '9')
}

var_valid_name :: proc "contextless" (name: string) -> bool {
	b := transmute([]u8)name
	if len(b) == 0 || len(b) > SCRIPT_VAR_NAME_MAX || !var_is_ident_start(b[0]) {
		return false
	}
	for i := 1; i < len(b); i += 1 {
		if !var_is_ident_char(b[i]) {
			return false
		}
	}
	return true
}

var_set :: proc "contextless" (name, val: string) -> bool {
	if !var_valid_name(name) {
		return false
	}
	nb := transmute([]u8)name
	vb := transmute([]u8)val
	vlen := len(vb)
	if vlen > SCRIPT_VAR_VAL_MAX {
		vlen = SCRIPT_VAR_VAL_MAX
	}

	free_idx := -1
	for i := 0; i < SCRIPT_MAX_VARS; i += 1 {
		sv := &g_shell_vars[i]
		if !sv.used {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
		if sv.name_len == len(nb) && string(sv.name[:sv.name_len]) == name {
			for k := 0; k < vlen; k += 1 {
				sv.val[k] = vb[k]
			}
			sv.val_len = vlen
			return true
		}
	}

	if free_idx < 0 {
		return false
	}
	sv := &g_shell_vars[free_idx]
	sv.used     = true
	sv.name_len = len(nb)
	sv.val_len  = vlen
	for k := 0; k < len(nb); k += 1 {
		sv.name[k] = nb[k]
	}
	for k := 0; k < vlen; k += 1 {
		sv.val[k] = vb[k]
	}
	return true
}

var_unset :: proc "contextless" (name: string) -> bool {
	nb := transmute([]u8)name
	for i := 0; i < SCRIPT_MAX_VARS; i += 1 {
		sv := &g_shell_vars[i]
		if sv.used && sv.name_len == len(nb) && string(sv.name[:sv.name_len]) == name {
			sv.used     = false
			sv.name_len = 0
			sv.val_len  = 0
			return true
		}
	}
	return false
}

var_get :: proc "contextless" (name: string, tmp: []u8) -> (string, bool) {
	if name == "status" || name == "?" {
		return fmt_i64(i64(g_last_status), tmp), true
	}
	if name == "cwd" {
		return fat32_pwd(), true
	}
	if name == "#" {
		n := g_script_argc - 1 if g_script_argc > 0 else 0
		return fmt_i64(i64(n), tmp), true
	}
	if len(name) == 1 && name[0] >= '0' && name[0] <= '9' {
		idx := int(name[0] - '0')
		if idx < g_script_argc {
			return g_script_args[idx], true
		}
		return "", true
	}

	nb := transmute([]u8)name
	for i := 0; i < SCRIPT_MAX_VARS; i += 1 {
		sv := &g_shell_vars[i]
		if sv.used && sv.name_len == len(nb) && string(sv.name[:sv.name_len]) == name {
			return string(sv.val[:sv.val_len]), true
		}
	}
	return "", false
}

var_write_all :: proc "contextless" (ob: ^Out_Buf) {
	tmp: [32]u8
	ob_puts(ob, "status=")
	ob_puts(ob, fmt_i64(i64(g_last_status), tmp[:]))
	ob_putc(ob, '\n')
	for i := 0; i < SCRIPT_MAX_VARS; i += 1 {
		sv := &g_shell_vars[i]
		if !sv.used {
			continue
		}
		ob_put_bytes(ob, sv.name[:sv.name_len])
		ob_putc(ob, '=')
		ob_put_bytes(ob, sv.val[:sv.val_len])
		ob_putc(ob, '\n')
	}
}

script_expand_vars :: proc "contextless" (src: []u8, dst: []u8) -> []u8 {
	out_len := 0
	in_sq := false
	in_dq := false
	tmp: [32]u8

	i := 0
	for i < len(src) {
		c := src[i]
		if c == '\'' && !in_dq {
			in_sq = !in_sq
			if out_len < len(dst) {
				dst[out_len] = c
				out_len += 1
			}
			i += 1
			continue
		}
		if c == '"' && !in_sq {
			in_dq = !in_dq
			if out_len < len(dst) {
				dst[out_len] = c
				out_len += 1
			}
			i += 1
			continue
		}
		if !in_sq && c == '$' && i + 1 < len(src) {
			next := src[i + 1]
			if next == '$' {
				if out_len < len(dst) {
					dst[out_len] = '$'
					out_len += 1
				}
				i += 2
				continue
			}

			var_name := ""
			consumed := 0
			if next == '?' || next == '#' || (next >= '0' && next <= '9') {
				var_name = string(src[i + 1 : i + 2])
				consumed = 2
			} else if next == '{' {
				close_idx := -1
				for j := i + 2; j < len(src); j += 1 {
					if src[j] == '}' {
						close_idx = j
						break
					}
				}
				if close_idx > i + 2 {
					var_name = string(src[i + 2 : close_idx])
					consumed = (close_idx + 1) - i
				}
			} else if var_is_ident_start(next) {
				j := i + 2
				for j < len(src) && var_is_ident_char(src[j]) {
					j += 1
				}
				var_name = string(src[i + 1 : j])
				consumed = j - i
			}

			if consumed > 0 {
				val, _ := var_get(var_name, tmp[:])
				vb := transmute([]u8)val
				for k := 0; k < len(vb) && out_len < len(dst); k += 1 {
					dst[out_len] = vb[k]
					out_len += 1
				}
				i += consumed
				continue
			}
		}

		if out_len < len(dst) {
			dst[out_len] = c
			out_len += 1
		}
		i += 1
	}
	return dst[:out_len]
}

// ---------------------------------------------------------------------------
// Script resolution (.rsh) & shared comment stripping
// ---------------------------------------------------------------------------

shell_strip_comment :: proc "contextless" (raw: []u8) -> []u8 {
	eff := len(raw)
	in_sq := false
	in_dq := false
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		if c == '\'' && !in_dq {
			in_sq = !in_sq
		} else if c == '"' && !in_sq {
			in_dq = !in_dq
		} else if !in_sq && !in_dq && c == '#' {
			eff = i
			break
		}
	}
	return shell_trim_ws(raw[:eff])
}

script_has_ext :: proc "contextless" (s: string) -> bool {
	b := transmute([]u8)s
	if len(b) < 4 {
		return false
	}
	n := len(b)
	return b[n - 4] == '.' &&
		ascii_upper(b[n - 3]) == 'R' &&
		ascii_upper(b[n - 2]) == 'S' &&
		ascii_upper(b[n - 1]) == 'H'
}

script_resolve_path :: proc "contextless" (cmd_name: string, a: ^Arena) -> (string, bool) {
	if !g_fat32.mounted || len(cmd_name) == 0 || a == nil {
		return "", false
	}
	if prg_has_slash(cmd_name) || script_has_ext(cmd_name) {
		if prg_try_file(cmd_name) {
			return cmd_name, true
		}
		if !script_has_ext(cmd_name) {
			with_ext := prg_join_upper("", cmd_name, ".RSH", a)
			if len(with_ext) > 0 && prg_try_file(with_ext) {
				return with_ext, true
			}
		}
		return "", false
	}

	in_cwd := prg_join_upper("", cmd_name, ".RSH", a)
	if len(in_cwd) > 0 && prg_try_file(in_cwd) {
		return in_cwd, true
	}
	in_bin := prg_join_upper("/BIN/", cmd_name, ".RSH", a)
	if len(in_bin) > 0 && prg_try_file(in_bin) {
		return in_bin, true
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Control-flow interpreter: if/else/end, for..in/end, break, continue, return
// ---------------------------------------------------------------------------

script_kw_match :: proc "contextless" (line: []u8, kw: string) -> ([]u8, bool) {
	if len(line) < len(kw) {
		return nil, false
	}
	for i := 0; i < len(kw); i += 1 {
		if line[i] != kw[i] {
			return nil, false
		}
	}
	if len(line) > len(kw) && line[len(kw)] != ' ' && line[len(kw)] != '\t' {
		return nil, false
	}
	return shell_trim_ws(line[len(kw):]), true
}

script_find_block :: proc "contextless" (
	lines: [][]u8,
	start_idx: int,
	allow_else: bool,
) -> (else_idx: int, end_idx: int, ok: bool) {
	else_idx = -1
	depth := 0
	for k := start_idx + 1; k < len(lines); k += 1 {
		l := shell_strip_comment(lines[k])
		if len(l) == 0 {
			continue
		}
		if _, is_if := script_kw_match(l, "if"); is_if {
			depth += 1
			continue
		}
		if _, is_for := script_kw_match(l, "for"); is_for {
			depth += 1
			continue
		}
		if rem, is_end := script_kw_match(l, "end"); is_end && len(rem) == 0 {
			if depth == 0 {
				return else_idx, k, true
			}
			depth -= 1
			continue
		}
		if rem, is_endif := script_kw_match(l, "endif"); is_endif && len(rem) == 0 {
			if depth == 0 {
				return else_idx, k, true
			}
			depth -= 1
			continue
		}
		if allow_else && depth == 0 {
			if rem, is_else := script_kw_match(l, "else"); is_else && len(rem) == 0 {
				if else_idx < 0 {
					else_idx = k
				}
			}
		}
	}
	return -1, -1, false
}

script_eval_cond :: proc "contextless" (cond_raw: []u8, out_sink: ^Out_Buf) -> bool {
	exp_buf: [SCRIPT_MAX_EXPAND]u8
	expanded := shell_trim_ws(script_expand_vars(cond_raw, exp_buf[:]))
	if len(expanded) == 0 {
		return false
	}

	cond_arena: Arena
	if !arena_init(&cond_arena) {
		return false
	}
	toks: [SHELL_MAX_ARGS]string
	ntok, tok_ok := shell_tokenize(expanded, &cond_arena, toks[:])

	if tok_ok && ntok == 2 && toks[0] == "exists" {
		_, ok := fat32_resolve_path(transmute([]u8)toks[1])
		arena_destroy(&cond_arena)
		return ok
	}
	if tok_ok && ntok == 3 && (toks[0] == "!" || toks[0] == "not") && toks[1] == "exists" {
		_, ok := fat32_resolve_path(transmute([]u8)toks[2])
		arena_destroy(&cond_arena)
		return !ok
	}
	if tok_ok && ntok == 3 {
		op := toks[1]
		if op == "==" {
			res := toks[0] == toks[2]
			arena_destroy(&cond_arena)
			return res
		}
		if op == "!=" {
			res := toks[0] != toks[2]
			arena_destroy(&cond_arena)
			return res
		}
		if op == "<" || op == "<=" || op == ">" || op == ">=" {
			a, ok_a := parse_i64(toks[0])
			b, ok_b := parse_i64(toks[2])
			arena_destroy(&cond_arena)
			if !ok_a || !ok_b {
				return false
			}
			switch op {
			case "<":  return a < b
			case "<=": return a <= b
			case ">":  return a > b
			case ">=": return a >= b
			}
		}
	}

	arena_destroy(&cond_arena)
	return shell_exec_line_out(expanded, out_sink) == 0
}

parse_range_u8 :: proc "contextless" (s: string) -> (a, b: i64, ok: bool) {
	bytes := transmute([]u8)s
	dot_idx := -1
	for i := 0; i + 1 < len(bytes); i += 1 {
		if bytes[i] == '.' && bytes[i + 1] == '.' {
			dot_idx = i
			break
		}
	}
	if dot_idx <= 0 || dot_idx + 2 >= len(bytes) {
		return 0, 0, false
	}
	lo, ok_lo := parse_i64(string(bytes[:dot_idx]))
	hi, ok_hi := parse_i64(string(bytes[dot_idx + 2:]))
	if !ok_lo || !ok_hi {
		return 0, 0, false
	}
	return lo, hi, true
}

script_exec_block :: proc "contextless" (
	lines: [][]u8,
	start, end: int,
	out_sink: ^Out_Buf,
) -> Script_Flow {
	for i := start; i < end; i += 1 {
		line := shell_strip_comment(lines[i])
		if len(line) == 0 {
			continue
		}

		if cond_raw, is_if := script_kw_match(line, "if"); is_if {
			else_idx, end_idx, blk_ok := script_find_block(lines, i, true)
			if !blk_ok {
				out_puts("Script error: unclosed 'if'\n")
				g_last_status = 1
				return .Return
			}
			flow := Script_Flow.Normal
			if script_eval_cond(cond_raw, out_sink) {
				branch_end := else_idx if else_idx >= 0 else end_idx
				flow = script_exec_block(lines, i + 1, branch_end, out_sink)
			} else if else_idx >= 0 {
				flow = script_exec_block(lines, else_idx + 1, end_idx, out_sink)
			}
			i = end_idx
			if flow != .Normal {
				return flow
			}
			continue
		}

		if for_raw, is_for := script_kw_match(line, "for"); is_for {
			end_idx, blk_ok := -1, false
			_, end_idx, blk_ok = script_find_block(lines, i, false)
			if !blk_ok {
				out_puts("Script error: unclosed 'for'\n")
				g_last_status = 1
				return .Return
			}

			// Expect: <var> in <items...>
			p := 0
			for p < len(for_raw) && for_raw[p] != ' ' && for_raw[p] != '\t' {
				p += 1
			}
			var_name := string(for_raw[:p])
			after_var := shell_trim_ws(for_raw[p:])
			items_raw, in_ok := script_kw_match(after_var, "in")
			if !var_valid_name(var_name) || !in_ok {
				out_puts("Script error: expected 'for <var> in <items...>'\n")
				g_last_status = 1
				return .Return
			}

			exp_buf: [SCRIPT_MAX_EXPAND]u8
			exp_items := script_expand_vars(items_raw, exp_buf[:])

			for_arena: Arena
			if !arena_init(&for_arena) {
				out_puts("Script error: out of memory in 'for'\n")
				g_last_status = 1
				return .Return
			}
			items: [SHELL_MAX_ARGS]string
			nitems, tok_ok := shell_tokenize(exp_items, &for_arena, items[:])
			if !tok_ok {
				arena_destroy(&for_arena)
				out_puts("Script error: syntax error in 'for' list\n")
				g_last_status = 1
				return .Return
			}

			if nitems == 1 {
				if lo, hi, is_rng := parse_range_u8(items[0]); is_rng {
					step := i64(1) if lo <= hi else i64(-1)
					num_buf: [32]u8
					iters := 0
					cur := lo
					for iters < 10000 {
						if (step > 0 && cur > hi) || (step < 0 && cur < hi) {
							break
						}
						_ = var_set(var_name, fmt_i64(cur, num_buf[:]))
						flow := script_exec_block(lines, i + 1, end_idx, out_sink)
						if flow == .Break {
							break
						}
						if flow == .Return {
							arena_destroy(&for_arena)
							return .Return
						}
						cur += step
						iters += 1
					}
					arena_destroy(&for_arena)
					i = end_idx
					continue
				}
			}

			for idx := 0; idx < nitems; idx += 1 {
				_ = var_set(var_name, items[idx])
				flow := script_exec_block(lines, i + 1, end_idx, out_sink)
				if flow == .Break {
					break
				}
				if flow == .Return {
					arena_destroy(&for_arena)
					return .Return
				}
			}
			arena_destroy(&for_arena)
			i = end_idx
			continue
		}

		if rem, is_brk := script_kw_match(line, "break"); is_brk && len(rem) == 0 {
			return .Break
		}
		if rem, is_cnt := script_kw_match(line, "continue"); is_cnt && len(rem) == 0 {
			return .Continue
		}
		if rem, is_ret := script_kw_match(line, "return"); is_ret {
			code := 0
			if len(rem) > 0 {
				exp_buf: [SCRIPT_MAX_EXPAND]u8
				exp_rem := shell_trim_ws(script_expand_vars(rem, exp_buf[:]))
				if parsed, ok := parse_i64(string(exp_rem)); ok {
					code = int(parsed)
				}
			}
			g_last_status = code
			return .Return
		}

		_ = shell_exec_line_out(line, out_sink)
	}
	return .Normal
}

script_exec_file :: proc "contextless" (path: string, args: []string, out_sink: ^Out_Buf) -> int {
	if g_script_depth >= SCRIPT_MAX_DEPTH {
		out_puts("Script error: max include/call depth reached\n")
		g_last_status = 1
		return 1
	}

	script_arena: Arena
	if !arena_init(&script_arena) {
		out_puts("Script error: out of memory\n")
		g_last_status = 1
		return 1
	}

	raw, ok := fat32_read_file(transmute([]u8)path, &script_arena)
	if !ok {
		arena_destroy(&script_arena)
		out_puts("run: cannot read script: ")
		out_puts(path)
		out_puts("\n")
		g_last_status = 1
		return 1
	}

	// Pass 1: count lines
	nlines := 0
	if len(raw) > 0 {
		nlines = 1
		for idx := 0; idx < len(raw); idx += 1 {
			if raw[idx] == '\n' {
				nlines += 1
			}
		}
	}

	lines: [][]u8 = nil
	if nlines > 0 {
		mem := arena_alloc(&script_arena, u64(nlines) * u64(size_of([]u8)), align_of([]u8))
		if mem == nil {
			arena_destroy(&script_arena)
			g_last_status = 1
			return 1
		}
		lines = ([^][]u8)(mem)[:nlines]

		li := 0
		start := 0
		for idx := 0; idx <= len(raw); idx += 1 {
			if idx == len(raw) || raw[idx] == '\n' {
				end := idx
				if end > start && raw[end - 1] == '\r' {
					end -= 1
				}
				if li < nlines {
					lines[li] = raw[start:end]
					li += 1
				}
				start = idx + 1
			}
		}
		lines = lines[:li]
	}

	prev_args := g_script_args
	prev_argc := g_script_argc

	g_script_args[0] = path
	g_script_argc = 1
	for k := 0; k < len(args) && g_script_argc < SCRIPT_MAX_ARGS; k += 1 {
		g_script_args[g_script_argc] = args[k]
		g_script_argc += 1
	}
	g_script_depth += 1
	g_last_status = 0

	_ = script_exec_block(lines, 0, len(lines), out_sink)

	g_script_depth -= 1
	g_script_args = prev_args
	g_script_argc = prev_argc

	arena_destroy(&script_arena)
	return g_last_status
}

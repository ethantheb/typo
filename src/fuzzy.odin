package editor

// A small fzy-style scorer for the file finder: the query must appear as a
// case-insensitive subsequence; consecutive matches and matches at word/path
// boundaries score higher, gaps cost a little. Byte-based, which suits file
// names. Runs on the main thread only (the score matrices are shared).

@(private = "file") SCORE_GAP_LEADING :: -0.005
@(private = "file") SCORE_GAP_TRAILING :: -0.005
@(private = "file") SCORE_GAP_INNER :: -0.01
@(private = "file") SCORE_MATCH_CONSECUTIVE :: 1.0
@(private = "file") SCORE_MATCH_SLASH :: 0.9
@(private = "file") SCORE_MATCH_WORD :: 0.8
@(private = "file") SCORE_MATCH_CAPITAL :: 0.7
@(private = "file") SCORE_MATCH_DOT :: 0.6
@(private = "file") SCORE_MIN :: min(f32)
@(private = "file") MAX_MATCH_LEN :: 512

@(private = "file")
lower :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

@(private = "file")
bonus :: proc(prev, c: u8) -> f32 {
	switch prev {
	case '/', '\\':
		return SCORE_MATCH_SLASH
	case '-', '_', ' ':
		return SCORE_MATCH_WORD
	case '.':
		return SCORE_MATCH_DOT
	}
	if prev >= 'a' && prev <= 'z' && c >= 'A' && c <= 'Z' do return SCORE_MATCH_CAPITAL
	return 0
}

@(private = "file")
is_subsequence :: proc(needle, haystack: string) -> bool #no_bounds_check {
	i := 0
	for j in 0 ..< len(haystack) {
		if i < len(needle) && lower(needle[i]) == lower(haystack[j]) do i += 1
	}
	return i == len(needle)
}

// D[i*m+j]: best score with needle[i] matched exactly at haystack[j].
// M[i*m+j]: best score for needle[:i+1] within haystack[:j+1].
@(private = "file")
compute :: proc(needle, haystack: string, D, M: []f32) #no_bounds_check {
	n, m := len(needle), len(haystack)
	for i in 0 ..< n {
		prev_score: f32 = SCORE_MIN
		gap: f32 = i == n - 1 ? SCORE_GAP_TRAILING : SCORE_GAP_INNER
		prev_char: u8 = '/'
		for j in 0 ..< m {
			c := haystack[j]
			if lower(needle[i]) == lower(c) {
				score: f32 = SCORE_MIN
				b := bonus(prev_char, c)
				if i == 0 {
					score = f32(j) * SCORE_GAP_LEADING + b
				} else if j > 0 {
					score = max(M[(i - 1) * m + j - 1] + b, D[(i - 1) * m + j - 1] + SCORE_MATCH_CONSECUTIVE)
				}
				D[i * m + j] = score
				prev_score = max(score, prev_score + gap)
			} else {
				D[i * m + j] = SCORE_MIN
				prev_score = prev_score + gap
			}
			M[i * m + j] = prev_score
			prev_char = c
		}
	}
}

// Score matrices, reused across calls.
@(private = "file")
scratch: [dynamic]f32

fuzzy_destroy :: proc() {
	delete(scratch)
	scratch = nil
}

@(private = "file")
matrices :: proc(n, m: int) -> (D, M: []f32) {
	if len(scratch) < 2 * n * m do resize(&scratch, 2 * n * m)
	return scratch[:n * m], scratch[n * m:2 * n * m]
}

fuzzy_score :: proc(needle, haystack: string) -> (score: f32, ok: bool) {
	if len(needle) == 0 do return 0, true
	if len(needle) > len(haystack) || len(haystack) > MAX_MATCH_LEN do return 0, false
	if !is_subsequence(needle, haystack) do return 0, false
	if len(needle) == len(haystack) do return max(f32), true

	n, m := len(needle), len(haystack)
	D, M := matrices(n, m)
	compute(needle, haystack, D, M)
	return M[(n - 1) * m + m - 1], true
}

// Which bytes of haystack the best match used, for highlighting.
fuzzy_positions :: proc(needle, haystack: string, allocator := context.temp_allocator) -> []bool {
	if len(needle) == 0 || len(haystack) > MAX_MATCH_LEN || !is_subsequence(needle, haystack) do return nil
	n, m := len(needle), len(haystack)
	D, M := matrices(n, m)
	compute(needle, haystack, D, M)

	matched := make([]bool, m, allocator)
	match_required := false
	j := m - 1
	for i := n - 1; i >= 0; i -= 1 {
		for ; j >= 0; j -= 1 {
			// Take this position if the best score came from matching here, or
			// if the previous pick was part of a consecutive run that requires it.
			d := D[i * m + j]
			if d != SCORE_MIN && (match_required || d == M[i * m + j]) {
				match_required = i > 0 && j > 0 && M[i * m + j] == D[(i - 1) * m + j - 1] + SCORE_MATCH_CONSECUTIVE
				matched[j] = true
				j -= 1
				break
			}
		}
	}
	return matched
}

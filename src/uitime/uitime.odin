package uitime

// A feature's share of the UI thread: the time spent in its calls since the
// perf suite last took it, which the suite limits per frame. Each feature that
// does work on the UI thread keeps a Share (thread-local, so only the UI
// thread's calls count) and starts its procs with `uitime.timed(&share)`

import "core:time"


Share :: struct {
	depth: int,           // timed calls under way, nested
	total: time.Duration, // counted since the last take
}


// Counts the time to the end of the caller's scope in `s`. Nested calls count
// once
@(deferred_in_out = timed_end)
timed :: proc(s: ^Share) -> time.Tick {
	s.depth += 1
	return time.tick_now()
}


@(private)
timed_end :: proc(s: ^Share, start: time.Tick) {
	s.depth -= 1
	if s.depth == 0 do s.total += time.tick_since(start)
}


// The time counted since the last take, counting from zero again
take :: proc(s: ^Share) -> time.Duration {
	total := s.total
	s.total = 0
	return total
}

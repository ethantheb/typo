#+build windows
package term

import "core:os"
import "core:testing"


// A child's chain goes through this process; no process, no chain
@(test)
test_process_ancestors :: proc(t: ^testing.T) {
	desc := os.Process_Desc {
		command = {"cmd.exe", "/c", "ping -n 3 127.0.0.1 >nul"},
	}
	child, err := os.process_start(desc)
	testing.expect_value(t, err, nil)
	if err != nil do return
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child)
	}

	chain := process_ancestors(child.pid, 8, context.temp_allocator)
	testing.expectf(t, len(chain) >= 2, "chain: %v", chain)
	if len(chain) >= 2 {
		testing.expect_value(t, chain[0], child.pid)
		testing.expect_value(t, chain[1], os.get_pid())
	}

	// A limit cuts it short
	testing.expect_value(t, len(process_ancestors(child.pid, 1, context.temp_allocator)), 1)
	testing.expect_value(t, len(process_ancestors(0, 8, context.temp_allocator)), 0)
}

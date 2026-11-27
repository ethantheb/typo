package editor

// `typo ctl <command>`: sends a control request to the typo window whose
// terminal this runs in (docs/agent_control.md) and prints its answer: JSON on
// stdout, a problem on stderr. Never opens a window

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "ipc"


// Exit codes
@(private = "file")
Control_Exit :: enum {
	Done      = 0,
	Failed    = 1, // refused or failed; the message says why
	Usage     = 2,
	No_Window = 3, // none runs, or none has this terminal
	Declined  = 4, // the user said no
}

// The first argument that makes a control command (a file named so opens as ./ctl)
CONTROL_WORD :: "ctl"

// How long `restart` waits for the new window to take the project
@(private = "file")
RESTART_WAIT :: 20 * time.Second

// The manual for agents (`typo ctl --skill`)
@(private = "file")
CONTROL_SKILL :: `# typo ctl: control the typo window you run in

You run in a terminal of typo, a code editor. "typo ctl <command>" controls that
window. It works only from typo's own terminals and never opens a window.
Output is JSON on stdout; a problem is one line on stderr.

## The window

  typo ctl ls                         panes (ids, kinds, rects), layout, focus
  typo ctl do <command> [--pane P]    a command as its keys would run it, named as
                                      in settings.toml (save, toggle_sidebar, ...)
  typo ctl open <file>[:line[:col]] [--at P --side S] [--focus]
  typo ctl terminal [--pinned | --local] [--name N] [--at P --side S]
                    [--hidden] [--focus] [-- <command line>]
  typo ctl move P (--side S --of Q | --edge S | --shelf)
  typo ctl focus P | close P | maximize P | maximize --off
  typo ctl rename P <name>            a terminal's name
  typo ctl diff <file> [--staged] [--focus]
  typo ctl git open | git message (<text> | -)    the Git pane, its message box
  typo ctl restart [--exe <path>]     saves, quits and starts typo again in this
                                      project (this typo, or --exe); pinned
                                      terminals (yours) come back

P and Q are panes: p<id> (from ls), "self" (the terminal you run in), "focused",
or an open file's path. S is left, right, top or bottom. open, terminal and diff
take the user's focus only with --focus; focus and maximize move it (and do
--pane may leave it on a maximized pane). Closing a file with unsaved changes, or
a terminal running a program, asks the user; while they're being asked every
request is refused ("try again once they answer"). To commit or push, run git
yourself.

## Testing typo

  typo ctl wait idle [--timeout S]    until nothing animates, loads or waits
  typo ctl screenshot [P] --out <file.png>   what typo drew, all or one pane
  typo ctl click (<element id> | <x>,<y>) [--right | --double]
  typo ctl drag <from> <to>           press, move, release (ids or x,y)
  typo ctl hover <element id | x,y>   the pointer rests there (tooltips)
  typo ctl keys <chord>...            pressed as typed, e.g. Ctrl+S Enter Escape
  typo ctl type <text>                typed as text into what has the keys
  typo ctl ui <element id>...         where the last layout put elements
  typo ctl log [--lines N]            recent log lines and dialogs shown

Coordinates are the layout's units (ls rects). Element ids are Clay's ("Main",
"TitleBar", or "Name:index"). Keys and clicks act on the window as a person's
would (keys stops when one opens a dialog: "user_asked" in its answer): test in
a typo started for the test rather than the user's window.

## Exit codes

  0 done, 1 refused or failed (stderr says why), 2 bad arguments,
  3 no typo window has this terminal, 4 the user declined

## Working on typo itself

After building (python build.py), "typo ctl restart --exe build/typo.exe" runs
your build in this window: it's copied first, so the next build can replace
build/typo.exe. Restart only works from a pinned terminal, which outlives typo.
Then: act, "typo ctl wait idle", "typo ctl screenshot --out x.png", look.
`


// Runs `typo ctl <args>`; returns the exit code
control_main :: proc(args: []string) -> int {
	attach_console()

	// The request
	if len(args) == 1 && args[0] == "--skill" {
		fmt.print(CONTROL_SKILL)
		return int(Control_Exit.Done)
	}
	request, problem := control_parse(args)
	if problem != "" {
		fmt.eprintfln("typo ctl: %s (typo ctl --skill lists the commands)", problem)
		return int(Control_Exit.Usage)
	}
	data, err := json.marshal(request, allocator = context.temp_allocator)
	if err != nil do return int(Control_Exit.Failed)
	if len(data) > ipc.MAX_MESSAGE - 64 {
		fmt.eprintfln("typo ctl: the request is too long (at most %d KB)", ipc.MAX_MESSAGE / 1024)
		return int(Control_Exit.Usage)
	}

	// The window: this terminal's, or for a pinned one each window showing its
	// project, newest first
	endpoint := os.get_env(ipc.ENV_NAME, context.temp_allocator)
	if endpoint == "" {
		fmt.eprintln("typo ctl: not run in a typo terminal")
		return int(Control_Exit.No_Window)
	}
	project := strings.has_prefix(endpoint, ipc.PROJECT_PREFIX)
	endpoints := project ? ipc.project_endpoints(endpoint) : []string{endpoint}

	for e in endpoints {
		reply, send_err := ipc.send_control(e, string(data))
		switch send_err {
		case .None:
		case .Not_Running:
			if project do ipc.project_forget(endpoint, e)
			continue
		case .Too_Old:
			fmt.eprintln("typo ctl: this window's typo is older and has no typo ctl; restart it")
			return int(Control_Exit.Failed)
		case .Failed:
			fmt.eprintln("typo ctl: the typo window did not answer")
			return int(Control_Exit.Failed)
		}

		switch reply.status {
		case .Not_Mine:
			continue
		case .Error:
			fmt.eprintfln("typo ctl: %s", reply_message(reply.json))
			return int(Control_Exit.Failed)
		case .Declined:
			fmt.eprintfln("typo ctl: %s", reply_message(reply.json))
			return int(Control_Exit.Declined)
		case .Ok:
		}

		if request.cmd == "restart" && project {
			return restart_wait(endpoint, e, reply.json)
		}
		fmt.println(reply.json)
		return int(Control_Exit.Done)
	}

	fmt.eprintln("typo ctl: no typo window has this terminal (is typo open?)")
	return int(Control_Exit.No_Window)
}


// The request the arguments make, or what's wrong with them
@(private = "file")
control_parse :: proc(args: []string) -> (request: Control_Args, problem: string) {
	if len(args) == 0 do return {}, "a command is missing"

	request.cmd = args[0]
	rest := args[1:]
	switch request.cmd {
	case "ls":
		if len(rest) > 0 do return {}, "ls takes no arguments"

	case "restart":
		for i := 0; i < len(rest); i += 1 {
			if rest[i] != "--exe" || i + 1 >= len(rest) {
				return {}, fmt.tprintf("restart doesn't take %q", rest[i])
			}
			i += 1
			exe, ok := absolute(rest[i])
			if !ok do return {}, fmt.tprintf("%s isn't a path", rest[i])
			request.exe = exe
		}

		// Without --exe, the typo run here: the one installed, not the one the
		// window runs from (an install moves that aside)
		if request.exe == "" {
			own, err := os.get_executable_path(context.temp_allocator)
			if err == nil do request.exe = own
		}

	case "screenshot":
		for i := 0; i < len(rest); i += 1 {
			switch {
			case rest[i] == "--out" && i + 1 < len(rest):
				i += 1
				out, ok := absolute(rest[i])
				if !ok do return {}, fmt.tprintf("%s isn't a path", rest[i])
				request.out = out
			case request.pane == "" && !strings.has_prefix(rest[i], "-"):
				request.pane = rest[i]
			case:
				return {}, fmt.tprintf("screenshot doesn't take %q", rest[i])
			}
		}
		if request.out == "" do return {}, "screenshot needs --out <file.png>"

	case "keys":
		if len(rest) == 0 do return {}, "keys needs chords, such as Ctrl+S or Enter"
		request.keys = rest

	case "type":
		if len(rest) == 0 do return {}, "type needs the text"
		request.text = strings.join(rest, " ", context.temp_allocator)

	case "click":
		for arg in rest {
			switch {
			case arg == "--right":  request.right = true
			case arg == "--double": request.double = true
			case request.target == "" && !strings.has_prefix(arg, "-"):
				request.target = arg
			case:
				return {}, fmt.tprintf("click doesn't take %q", arg)
			}
		}
		if request.target == "" do return {}, "click needs an element id or x,y"

	case "hover":
		if len(rest) != 1 do return {}, "hover needs an element id or x,y"
		request.target = rest[0]

	case "drag":
		if len(rest) != 2 do return {}, "drag needs where from and where to"
		request.target = rest[0]
		request.to = rest[1]

	case "wait":
		if len(rest) == 0 || rest[0] != "idle" do return {}, "wait takes idle"
		for i := 1; i < len(rest); i += 1 {
			if rest[i] != "--timeout" || i + 1 >= len(rest) {
				return {}, fmt.tprintf("wait doesn't take %q", rest[i])
			}
			i += 1
			seconds, ok := strconv.parse_f64(rest[i])
			if !ok || seconds <= 0 do return {}, "--timeout takes seconds"
			request.timeout = seconds
		}

	case "ui":
		if len(rest) == 0 do return {}, "ui needs element ids"
		request.ids = rest

	case "log":
		for i := 0; i < len(rest); i += 1 {
			if rest[i] != "--lines" || i + 1 >= len(rest) {
				return {}, fmt.tprintf("log doesn't take %q", rest[i])
			}
			i += 1
			n, ok := strconv.parse_int(rest[i])
			if !ok || n <= 0 do return {}, "--lines takes a number"
			request.lines = n
		}

	case "do", "open", "terminal", "move", "focus", "maximize", "close", "rename", "diff",
	     "git":
		return parse_pane_command(request, rest)

	case:
		return {}, fmt.tprintf("unknown command %q", request.cmd)
	}
	return request, ""
}


// The pane commands' arguments: a pane, a file or a word first, then flags
@(private = "file")
parse_pane_command :: proc(
	request: Control_Args,
	rest: []string,
) -> (
	out: Control_Args,
	problem: string,
) {
	r := request
	words := make([dynamic]string, context.temp_allocator)

	// Flags; a terminal's command follows "--"
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		value := i + 1 < len(rest) ? rest[i + 1] : ""
		takes := true
		switch arg {
		case "--":
			r.command = strings.join(rest[i + 1:], " ", context.temp_allocator)
			i = len(rest)
			takes = false
		case "--pane":  r.pane = value
		case "--at":    r.at = value
		case "--side":  r.side = value
		case "--of":    r.of = value
		case "--edge":  r.edge = value
		case "--name":  r.name = value
		case "--shelf", "--focus", "--pinned", "--local", "--hidden", "--staged", "--off":
			takes = false
			switch arg {
			case "--shelf":  r.shelf = true
			case "--focus":  r.focus = true
			case "--pinned": r.pinned = true
			case "--local":  r.local = true
			case "--hidden": r.hidden = true
			case "--staged": r.staged = true
			case "--off":    r.off = true
			}
		case:
			if strings.has_prefix(arg, "--") {
				return {}, fmt.tprintf("%s doesn't take %q", r.cmd, arg)
			}
			append(&words, arg)
			takes = false
		}
		if takes {
			if value == "" do return {}, fmt.tprintf("%s needs a value", arg)
			i += 1
		}
	}

	// The words each command takes
	first := len(words) > 0 ? words[0] : ""
	switch r.cmd {
	case "do":
		if first == "" do return {}, "do needs a command, as settings.toml names it"
		r.command = first
	case "open":
		if first == "" do return {}, "open needs a file"
		r.path, r.line, r.col = split_place(first)
		r.path = absolute(r.path) or_else r.path
	case "diff":
		if first == "" do return {}, "diff needs a file"
		r.path = absolute(first) or_else first
	case "move", "focus", "close":
		if first == "" do return {}, fmt.tprintf("%s needs a pane", r.cmd)
		r.pane = first
	case "maximize":
		if first == "" && !r.off do return {}, "maximize needs a pane (or --off)"
		r.pane = first
	case "rename":
		if len(words) < 2 do return {}, "rename needs a pane and a name"
		r.pane = first
		r.name = strings.join(words[1:], " ", context.temp_allocator)
	case "git":
		r.git = first
		if first == "message" {
			r.text = strings.join(words[1:], " ", context.temp_allocator)
			if r.text == "-" do r.text = read_stdin()
		}
	}
	if r.pinned && r.local do return {}, "a terminal is --pinned or --local"

	// A file naming a pane is found by its full path
	r.pane = pane_arg(r.pane)
	r.at = pane_arg(r.at)
	r.of = pane_arg(r.of)
	return r, ""
}


// A pane reference as sent: "self", "focused" and "p<id>" as they are, a file's
// path made absolute
@(private = "file")
pane_arg :: proc(ref: string) -> string {
	switch ref {
	case "", "self", "focused":
		return ref
	}
	if strings.has_prefix(ref, "p") {
		_, is_id := strconv.parse_uint(ref[1:], 10)
		if is_id do return ref
	}
	return absolute(ref) or_else ref
}


// "path:line:col" or "path:line" as its parts; a drive's colon isn't one
@(private = "file")
split_place :: proc(s: string) -> (path: string, line, col: int) {
	path = s
	for _ in 0 ..< 2 {
		colon := strings.last_index_byte(path, ':')
		if colon <= 1 do break

		n, ok := strconv.parse_int(path[colon + 1:], 10)
		if !ok || n <= 0 do break
		col, line = line, n
		path = path[:colon]
	}
	return
}


// What was piped in (temp)
@(private = "file")
read_stdin :: proc() -> string {
	data, err := os.read_entire_file(os.stdin, context.temp_allocator)
	if err != nil do return ""
	return strings.trim_right(string(data), "\r\n")
}


// A path made absolute from where typo ctl runs (temp)
@(private = "file")
absolute :: proc(path: string) -> (abs: string, ok: bool) {
	result, err := os.get_absolute_path(path, context.temp_allocator)
	return result, err == nil
}


// The message in an error's JSON
@(private = "file")
reply_message :: proc(data: string) -> string {
	Message :: struct {
		message: string,
	}
	m: Message
	if json.unmarshal_string(data, &m, allocator = context.temp_allocator) != nil {
		return data
	}
	return m.message
}


// After a restart was agreed: waits until a new window under the project has
// this terminal back (it lists itself before it reattaches), so a command
// right after finds it
@(private = "file")
restart_wait :: proc(project, old: string, reply: string) -> int {
	start := time.tick_now()
	for time.tick_since(start) < RESTART_WAIT {
		for e in ipc.project_endpoints(project) {
			if e == old do continue

			answer, err := ipc.send_control(e, `{"cmd":"ls"}`)
			if err == .None && answer.status == .Ok {
				fmt.println(reply)
				return int(Control_Exit.Done)
			}
		}
		time.sleep(200 * time.Millisecond)
	}

	fmt.eprintln("typo ctl: the new typo didn't open the project in time")
	return int(Control_Exit.Failed)
}

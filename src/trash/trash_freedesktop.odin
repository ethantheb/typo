#+build linux, freebsd, openbsd, netbsd
package trash

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

// The freedesktop.org trash (the Trash specification), which GNOME, KDE and
// the other desktops share. An item on the home folder's device goes to the
// home trash ($XDG_DATA_HOME/Trash); one on another device to that device's
// own, at its top: .Trash/$uid when the administrator made a .Trash there
// (a folder with the sticky bit), else .Trash-$uid. Each item's .trashinfo,
// created first with O_EXCL, reserves its name in the trash and says where it
// came from and when, so file managers can restore it. All in the temp
// allocator


// Names tried before giving up: "name", "name.2", "name.3", ...
@(private = "file")
MAX_NAMES :: 1000

@(private = "file")
OWNER_ONLY :: posix.mode_t{.IRUSR, .IWUSR, .IXUSR}


move :: proc(path: string) -> Result {
	context.allocator = context.temp_allocator

	absolute := path
	if !filepath.is_abs(path) {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		absolute = join(cwd, path)
	}

	item: posix.stat_t
	if posix.lstat(cstr(absolute), &item) != .OK do return .Failed

	// The home trash, when the item is on its device
	if home := home_trash(); home != "" && on_device(home, item.st_dev) {
		return move_into(absolute, home, absolute)
	}

	// Else its device's own, which says where it was from the device's top
	top := device_top(absolute, item.st_dev)
	trash := top_trash(top)
	if trash == "" do return .Not_Recyclable

	from_top := strings.trim_left(absolute[len(top):], "/")
	return move_into(absolute, trash, from_top)
}


// $XDG_DATA_HOME/Trash (by default ~/.local/share/Trash), made if needed; ""
// if there is none
@(private = "file")
home_trash :: proc() -> string {
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do return ""
		data = join(home, ".local", "share")
	}
	_ = os.make_directory_all(data)

	trash := join(data, "Trash")
	return trash_ready(trash) ? trash : ""
}


// The trash at a device's top folder, made if needed; "" if it can't be used
@(private = "file")
top_trash :: proc(top: string) -> string {
	uid := fmt.tprintf("%d", posix.getuid())

	// The administrator's .Trash, if it is a real folder with the sticky bit
	shared := join(top, ".Trash")
	info: posix.stat_t
	is_shared := posix.lstat(cstr(shared), &info) == .OK &&
	             posix.S_ISDIR(info.st_mode) &&
	             .ISVXT in info.st_mode
	if is_shared {
		trash := join(shared, uid)
		if trash_ready(trash) do return trash
	}

	// Else the user's own
	own := join(top, strings.concatenate({".Trash-", uid}))
	return trash_ready(own) ? own : ""
}


// Makes a trash folder and its files/ and info/ folders, readable only by
// the user; whether they are there now
@(private = "file")
trash_ready :: proc(trash: string) -> bool {
	for dir in ([]string{trash, join(trash, "files"), join(trash, "info")}) {
		if posix.mkdir(cstr(dir), OWNER_ONLY) == .OK do continue
		if posix.errno() != .EEXIST do return false

		existing: posix.stat_t
		is_dir := posix.lstat(cstr(dir), &existing) == .OK && posix.S_ISDIR(existing.st_mode)
		if !is_dir do return false
	}
	return true
}


// Whether `dir` is on the device `dev`
@(private = "file")
on_device :: proc(dir: string, dev: posix.dev_t) -> bool {
	info: posix.stat_t
	return posix.stat(cstr(dir), &info) == .OK && info.st_dev == dev
}


// The highest folder above `path` still on its device: where the device is
// mounted
@(private = "file")
device_top :: proc(path: string, dev: posix.dev_t) -> string {
	top := filepath.dir(path)
	for top != "/" {
		parent := filepath.dir(top)
		if !on_device(parent, dev) do break
		top = parent
	}
	return top
}


// Reserves a name in the trash with its .trashinfo, then moves the item in
// under it. `origin` is what the info records as the item's place
@(private = "file")
move_into :: proc(path, trash, origin: string) -> Result {
	name := filepath.base(path)
	stamp := deletion_date()

	for n in 1 ..= MAX_NAMES {
		candidate := n == 1 ? name : fmt.tprintf("%s.%d", name, n)
		info := join(trash, "info", strings.concatenate({candidate, ".trashinfo"}))
		target := join(trash, "files", candidate)

		// The info first: creating it reserves the name
		flags := posix.O_Flags{.WRONLY, .CREAT, .EXCL}
		fd := posix.open(cstr(info), flags, posix.mode_t{.IRUSR, .IWUSR})
		if fd < 0 {
			if posix.errno() == .EEXIST do continue
			return .Failed
		}
		text := fmt.tprintf(
			"[Trash Info]\nPath=%s\nDeletionDate=%s\n",
			url_escape(origin),
			stamp,
		)
		written := posix.write(fd, raw_data(text), len(text))
		posix.close(fd)

		// A file left in files/ without its info also holds the name
		taken: posix.stat_t
		if written != len(text) || posix.lstat(cstr(target), &taken) == .OK {
			posix.unlink(cstr(info))
			if written != len(text) do return .Failed
			continue
		}

		if libc.rename(cstr(path), cstr(target)) != 0 {
			cross_device := posix.errno() == .EXDEV
			posix.unlink(cstr(info))
			return cross_device ? .Not_Recyclable : .Failed
		}
		return .Done
	}
	return .Failed
}


// Now in local time, as the specification's DeletionDate: YYYY-MM-DDThh:mm:ss
@(private = "file")
deletion_date :: proc() -> string {
	now := posix.time_t(libc.time(nil))
	t: posix.tm
	posix.localtime_r(&now, &t)
	return fmt.tprintf(
		"%04d-%02d-%02dT%02d:%02d:%02d",
		t.tm_year + 1900,
		t.tm_mon + 1,
		t.tm_mday,
		t.tm_hour,
		t.tm_min,
		t.tm_sec,
	)
}


// A path as the .trashinfo's Path: bytes other than unreserved URI characters
// and "/" percent-encoded
@(private = "file")
url_escape :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)path {
		unreserved := (c >= 'a' && c <= 'z') ||
		              (c >= 'A' && c <= 'Z') ||
		              (c >= '0' && c <= '9') ||
		              strings.index_byte("-._~/", c) >= 0
		if unreserved {
			strings.write_byte(&b, c)
		} else {
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}


// Joins path parts (in the context's allocator: move's temp allocator)
@(private = "file")
join :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts)
	return path
}


@(private = "file")
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

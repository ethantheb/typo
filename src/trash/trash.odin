package trash

// Moving files and folders to the system's trash, where they can be restored:
// the Recycle Bin on Windows (trash_windows.odin), the Trash on macOS
// (trash_darwin.odin), and elsewhere the freedesktop.org trash that Linux and
// BSD desktops share (trash_freedesktop.odin). `move` may block for as long as
// the system takes (a large folder, a network drive), so call it off the UI
// thread. It stands alone: no app state


Result :: enum {
	Done,
	Failed,
	Not_Recyclable, // the item can't go to the trash there; nothing was deleted
}

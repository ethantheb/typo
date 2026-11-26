#+build windows
package editor

import win "core:sys/windows"

import clay "../vendor/clay-odin"
import "gfx"
import sdl "../vendor/sdl3"

// SDL's borderless window keeps WS_CAPTION, WS_THICKFRAME, WS_SYSMENU and the
// minimize and maximize boxes, and its WM_NCCALCSIZE leaves no non-client area
// (maximized, the monitor's work area). A subclass in front of SDL's window
// procedure answers the hit test (edges, the strip as caption, the maximize
// button as the system's, for Snap Layouts) and takes the maximize button's
// pointer messages, which DefWindowProc would answer by drawing a classic button

@(private = "file")
SUBCLASS_ID :: 1

@(private = "file")
ABM_GETAUTOHIDEBAREX :: 0x0000000b

// Left free where an auto-hide taskbar is, so the pointer can still reveal it
@(private = "file")
AUTOHIDE_GAP :: 2


// Subclasses the window and asks DWM for rounded corners. Returns false if the
// frame can't be drawn by typo
frame_platform_init :: proc(window: ^sdl.Window) -> bool {
	hwnd := frame_hwnd(window)
	if hwnd == nil do return false
	win.SetWindowSubclass(hwnd, frame_subclass, SUBCLASS_ID, 0)

	// DWM rounds windows with a caption style; asked for anyway, as nothing of
	// the native caption is left
	corners := win.DWM_WINDOW_CORNER_PREFERENCE.ROUND
	attribute := u32(win.DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE)
	win.DwmSetWindowAttribute(hwnd, attribute, &corners, size_of(corners))

	// The frame again, through the subclass
	flags: win.UINT = win.SWP_FRAMECHANGED | win.SWP_NOMOVE | win.SWP_NOSIZE
	flags |= win.SWP_NOZORDER | win.SWP_NOACTIVATE
	win.SetWindowPos(hwnd, nil, 0, 0, 0, 0, flags)
	return true
}


// The 1px border DWM draws around the window, in the theme's border color
frame_platform_border :: proc(color: clay.Color) {
	hwnd := frame_hwnd(g.window)
	if hwnd == nil do return

	// COLORREF: 0x00BBGGRR
	ref := u32(color.r) | u32(color.g) << 8 | u32(color.b) << 16
	attribute := u32(win.DWMWINDOWATTRIBUTE.DWMWA_BORDER_COLOR)
	win.DwmSetWindowAttribute(hwnd, attribute, &ref, size_of(ref))
}


@(private = "file")
frame_hwnd :: proc(window: ^sdl.Window) -> win.HWND {
	props := sdl.GetWindowProperties(window)
	return win.HWND(sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
}


@(private = "file")
frame_subclass :: proc "system" (
	hwnd: win.HWND,
	msg: win.UINT,
	wparam: win.WPARAM,
	lparam: win.LPARAM,
	id: win.UINT_PTR,
	data: win.DWORD_PTR,
) -> win.LRESULT {
	context = g.ctx
	f := &window_frame

	switch msg {
	case win.WM_NCCALCSIZE:
		result := win.DefSubclassProc(hwnd, msg, wparam, lparam)
		if wparam != 0 && win.IsZoomed(hwnd) {
			params := (^win.NCCALCSIZE_PARAMS)(rawptr(uintptr(lparam)))
			leave_autohide_taskbar(hwnd, &params.rgrc[0])
		}
		return result

	case win.WM_NCHITTEST:
		if hit, inside := frame_hit_test(hwnd, lparam); inside {
			return hit
		}

	// Each new size is drawn while the system's size loop runs: SDL draws only
	// on a timer then, which leaves the new edges unpainted for a frame or more.
	// Presents don't wait for vsync meanwhile: the system's compositor syncs a
	// window anyway, and each new size should show as soon as it is drawn
	case win.WM_ENTERSIZEMOVE:
		f.size_move = true
		_ = sdl.SetRenderVSync(gfx.renderer, 0)

	case win.WM_EXITSIZEMOVE:
		f.size_move = false
		_ = sdl.SetRenderVSync(gfx.renderer, 1)
	case win.WM_WINDOWPOSCHANGED:
		result := win.DefSubclassProc(hwnd, msg, wparam, lparam)
		pos := (^win.WINDOWPOS)(rawptr(uintptr(lparam)))
		resized := pos.flags & win.SWP_NOSIZE == 0
		if f.size_move && resized && !f.drawing {
			f.drawing = true
			app_iterate(nil)
			f.drawing = false
			f.drawn_at = sdl.GetTicksNS()
		}
		return result

	// The pointer over the strip and the background: SDL sees it leave, so
	// what it hovered last would stay lit. Then the maximize button's hover
	case win.WM_NCMOUSEMOVE:
		if p, inside := client_point(hwnd, lparam); inside {
			g.mouse_pos = p
			wake_main_loop(nil)
		}

		hover := wparam == win.HTMAXBUTTON
		if hover {
			track := win.TRACKMOUSEEVENT {
				cbSize    = size_of(win.TRACKMOUSEEVENT),
				dwFlags   = win.TME_LEAVE | win.TME_NONCLIENT,
				hwndTrack = hwnd,
			}
			win.TrackMouseEvent(&track)
		}
		set_max_state(hover, f.max_down && hover)

	case win.WM_NCMOUSELEAVE, win.WM_MOUSEMOVE:
		set_max_state(false, false)

	case win.WM_NCLBUTTONDOWN, win.WM_NCLBUTTONDBLCLK:
		if wparam == win.HTMAXBUTTON {
			set_max_state(true, true)
			return 0
		}

	case win.WM_NCLBUTTONUP:
		if wparam == win.HTMAXBUTTON {
			if f.max_down {
				command := win.IsZoomed(hwnd) ? win.SC_RESTORE : win.SC_MAXIMIZE
				win.PostMessageW(hwnd, win.WM_SYSCOMMAND, win.WPARAM(command), 0)
			}
			set_max_state(true, false)
			return 0
		}

	// Alt+Space opens the system menu (SDL drops SC_KEYMENU)
	case win.WM_SYSCOMMAND:
		is_key_menu := wparam & 0xFFF0 == win.SC_KEYMENU
		if is_key_menu && lparam == win.LPARAM(win.VK_SPACE) {
			return win.DefWindowProcW(hwnd, msg, wparam, lparam)
		}
	}

	return win.DefSubclassProc(hwnd, msg, wparam, lparam)
}


@(private = "file")
set_max_state :: proc(hover, down: bool) {
	f := &window_frame
	same := f.max_hover == hover && f.max_down == down
	if same do return

	f.max_hover = hover
	f.max_down = down
	wake_main_loop(nil)
}


// A message's screen point in the layout's units, if it is in the client area
@(private = "file")
client_point :: proc(hwnd: win.HWND, lparam: win.LPARAM) -> (p: [2]f32, inside: bool) {
	point := win.POINT{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
	win.ScreenToClient(hwnd, &point)

	client: win.RECT
	win.GetClientRect(hwnd, &client)
	w, h: i32
	_ = sdl.GetWindowSize(g.window, &w, &h)

	inside = point.x >= 0 && point.y >= 0 && point.x < client.right && point.y < client.bottom
	if !inside || w <= 0 {
		return {}, false
	}

	pixels_per_coord := f32(client.right) / f32(w)
	p = [2]f32{f32(point.x), f32(point.y)} / pixels_per_coord
	return window_to_layout(p.x, p.y), true
}


// The hit test, in the layout's units. Points outside the client area (the gap
// left for an auto-hide taskbar) aren't answered
@(private = "file")
frame_hit_test :: proc(hwnd: win.HWND, lparam: win.LPARAM) -> (win.LRESULT, bool) {
	p, inside := client_point(hwnd, lparam)
	if !inside do return 0, false

	w, h: i32
	_ = sdl.GetWindowSize(g.window, &w, &h)
	size := window_to_layout(f32(w), f32(h))
	hit := window_frame_hit(p, size, bool(win.IsZoomed(hwnd)))

	switch hit {
	case .Client:       return win.HTCLIENT, true
	case .Caption:      return win.HTCAPTION, true
	case .Background:   return background_hit(), true
	case .Maximize:     return win.HTMAXBUTTON, true
	case .Left:         return win.HTLEFT, true
	case .Right:        return win.HTRIGHT, true
	case .Top:          return win.HTTOP, true
	case .Bottom:       return win.HTBOTTOM, true
	case .Top_Left:     return win.HTTOPLEFT, true
	case .Top_Right:    return win.HTTOPRIGHT, true
	case .Bottom_Left:  return win.HTBOTTOMLEFT, true
	case .Bottom_Right: return win.HTBOTTOMRIGHT, true
	}
	return win.HTCLIENT, true
}


// The background drags with the left button; with another down it is typo's,
// so a right press there still opens typo's menu (SDL's hit test does the same)
@(private = "file")
background_hit :: proc() -> win.LRESULT {
	right_down := win.GetAsyncKeyState(win.VK_RBUTTON) < 0
	middle_down := win.GetAsyncKeyState(win.VK_MBUTTON) < 0
	if right_down || middle_down {
		return win.HTCLIENT
	}
	return win.HTCAPTION
}


// A maximized window covering the monitor would keep an auto-hide taskbar
// hidden: the edge it is on is left a few pixels short
@(private = "file")
leave_autohide_taskbar :: proc(hwnd: win.HWND, rect: ^win.RECT) {
	monitor := win.MonitorFromWindow(hwnd, .MONITOR_DEFAULTTONEAREST)
	info := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	if !win.GetMonitorInfoW(monitor, &info) do return

	edges := [4]win.UINT{win.ABE_LEFT, win.ABE_TOP, win.ABE_RIGHT, win.ABE_BOTTOM}
	for edge in edges {
		bar := win.APPBARDATA {
			cbSize = size_of(win.APPBARDATA),
			uEdge  = edge,
			rc     = info.rcMonitor,
		}
		if win.SHAppBarMessage(ABM_GETAUTOHIDEBAREX, &bar) == 0 do continue

		switch edge {
		case win.ABE_LEFT:   rect.left = max(rect.left, info.rcMonitor.left + AUTOHIDE_GAP)
		case win.ABE_TOP:    rect.top = max(rect.top, info.rcMonitor.top + AUTOHIDE_GAP)
		case win.ABE_RIGHT:  rect.right = min(rect.right, info.rcMonitor.right - AUTOHIDE_GAP)
		case win.ABE_BOTTOM: rect.bottom = min(rect.bottom, info.rcMonitor.bottom - AUTOHIDE_GAP)
		}
	}
}

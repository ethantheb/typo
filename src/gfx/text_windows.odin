#+build windows
package gfx

import win "core:sys/windows"


// Whether Windows draws text with ClearType, and the order of the screen's
// subpixels: 1 (RGB) or 2 (BGR), as ttf.SetFontLCD takes it
system_subpixel :: proc() -> (cleartype: bool, order: i32) {
	// Smoothing switched off keeps its type, which can still say ClearType
	smoothing_on: win.BOOL
	_ = win.SystemParametersInfoW(win.SPI_GETFONTSMOOTHING, 0, &smoothing_on, 0)
	smoothing: win.UINT
	_ = win.SystemParametersInfoW(win.SPI_GETFONTSMOOTHINGTYPE, 0, &smoothing, 0)
	cleartype = bool(smoothing_on) && smoothing == win.FE_FONTSMOOTHINGCLEARTYPE

	orientation := win.UINT(win.FE_FONTSMOOTHINGORIENTATIONRGB)
	_ = win.SystemParametersInfoW(win.SPI_GETFONTSMOOTHINGORIENTATION, 0, &orientation, 0)
	order = orientation == win.FE_FONTSMOOTHINGORIENTATIONBGR ? 2 : 1
	return
}

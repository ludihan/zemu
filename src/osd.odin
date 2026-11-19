package zemu

// On-screen messages ("STATE 0 SAVED"), drawn by the GUI at the bottom left
// like ZSNES does.

import "core:strings"
import sdl "vendor:sdl3"

OSD :: struct {
	text:     [128]byte,
	len:      int,
	until_ns: u64,
}

osd: OSD

osd_message :: proc(msg: string, seconds: f32 = 2) {
	n := copy(osd.text[:], msg)
	osd.len = n
	// ZSNES messages are upper case; so is our font.
	for i in 0 ..< n {
		ch := osd.text[i]
		if ch >= 'a' && ch <= 'z' do osd.text[i] = ch - 32
	}
	secs := max(seconds, 1)
	osd.until_ns = sdl.GetTicksNS() + u64(secs * 1e9)
}

osd_current :: proc() -> (string, bool) {
	if osd.len == 0 || sdl.GetTicksNS() > osd.until_ns do return "", false
	return string(osd.text[:osd.len]), true
}

_ :: strings

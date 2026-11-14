package main

import "core:math"
import sdl "vendor:sdl3"

import "emu"

Video :: struct {
	texture:  ^sdl.Texture,
	tex_w:    i32,
	tex_h:    i32,
	frame_w:  i32,
	frame_h:  i32,
	has_frame: bool,
}

video_destroy :: proc(v: ^Video) {
	if v.texture != nil {
		sdl.DestroyTexture(v.texture)
		v.texture = nil
	}
	v.has_frame = false
}

// Copies a core's frame into the streaming texture, growing it if needed.
video_upload :: proc(v: ^Video, r: ^sdl.Renderer, f: emu.Frame, smooth: bool) {
	if !emu.frame_is_valid(f) {
		return
	}
	w, h := i32(f.width), i32(f.height)
	if v.texture == nil || w > v.tex_w || h > v.tex_h {
		video_destroy(v)
		v.tex_w = max(w, 256)
		v.tex_h = max(h, 256)
		v.texture = sdl.CreateTexture(r, .XRGB8888, .STREAMING, v.tex_w, v.tex_h)
		if v.texture == nil {
			return
		}
	}
	sdl.SetTextureScaleMode(v.texture, smooth ? .LINEAR : .NEAREST)
	rect := sdl.Rect{0, 0, w, h}
	sdl.UpdateTexture(v.texture, &rect, raw_data(f.pixels), i32(f.pitch * size_of(u32)))
	v.frame_w = w
	v.frame_h = h
	v.has_frame = true
}

// Computes where the picture goes inside an output of `out_w` x `out_h`.
// The aspect ratio is always preserved: the leftover area becomes black bars.
letterbox :: proc(frame_w, frame_h: i32, pixel_aspect: f32, out_w, out_h: i32, integer: bool) -> sdl.FRect {
	if frame_w <= 0 || frame_h <= 0 || out_w <= 0 || out_h <= 0 {
		return {}
	}
	disp_w := f32(frame_w) * pixel_aspect
	disp_h := f32(frame_h)
	scale := min(f32(out_w) / disp_w, f32(out_h) / disp_h)
	if integer && scale >= 1 {
		// Whole-number vertical scale keeps scanlines even. Width follows the
		// aspect ratio, so non-square pixels still come out the right shape.
		scale = math.floor(scale)
	}
	w := math.round(disp_w * scale)
	h := math.round(disp_h * scale)
	return {
		x = math.floor((f32(out_w) - w) / 2),
		y = math.floor((f32(out_h) - h) / 2),
		w = w,
		h = h,
	}
}

video_draw :: proc(v: ^Video, r: ^sdl.Renderer, dst: sdl.FRect, brightness: u8 = 255) {
	if v.texture == nil || !v.has_frame {
		return
	}
	src := sdl.FRect{0, 0, f32(v.frame_w), f32(v.frame_h)}
	d := dst
	sdl.SetTextureColorMod(v.texture, brightness, brightness, brightness)
	sdl.RenderTexture(r, v.texture, &src, &d)
}

// Effective pixel aspect for the configured mode.
pixel_aspect_for :: proc(mode: Aspect_Mode, native: f32, frame_w, frame_h: i32) -> f32 {
	switch mode {
	case .Original:
		return native
	case .Force_4_3:
		return (4.0 / 3.0) * f32(frame_h) / f32(max(frame_w, 1))
	case .Square:
		return 1
	}
	return 1
}

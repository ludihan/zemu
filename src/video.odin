package zemu

// Game video: the core's frames go into a streaming texture that is drawn
// into a rectangle chosen by the GUI layout.

import "core:c"
import "core:math"
import retro "libretro"
import sdl "vendor:sdl3"

Scale_Mode :: enum u8 {
	Aspect,   // largest size that keeps the aspect ratio
	Integer,  // largest integer multiple of the base size
	Stretch,  // fill the area
}

Video :: struct {
	texture:     ^sdl.Texture,
	tex_w:       int,
	tex_h:       int,
	tex_format:  retro.Pixel_Format,
	frame_w:     int,
	frame_h:     int,
	have_frame:  bool,
}

video: Video

video_reset :: proc() {
	if video.texture != nil {
		sdl.DestroyTexture(video.texture)
		video.texture = nil
	}
	video.have_frame = false
}

pixel_format_to_sdl :: proc(f: retro.Pixel_Format) -> sdl.PixelFormat {
	switch f {
	case .XRGB1555: return .XRGB1555
	case .XRGB8888: return .XRGB8888
	case .RGB565:   return .RGB565
	}
	return .XRGB8888
}

video_refresh_cb :: proc "c" (data: rawptr, width, height: c.uint, pitch: c.size_t) {
	context = app_ctx
	if data == nil || data == retro.HW_FRAME_BUFFER_VALID do return // duplicate frame

	w, h := int(width), int(height)
	need_w := max(w, int(core.av_info.geometry.max_width))
	need_h := max(h, int(core.av_info.geometry.max_height))
	if video.texture == nil || video.tex_format != core.pixel_format || w > video.tex_w || h > video.tex_h {
		if video.texture != nil do sdl.DestroyTexture(video.texture)
		video.texture = sdl.CreateTexture(app.renderer, pixel_format_to_sdl(core.pixel_format), .STREAMING, c.int(need_w), c.int(need_h))
		if video.texture == nil do return
		_ = sdl.SetTextureScaleMode(video.texture, .LINEAR if settings.video_filter else .NEAREST)
		video.tex_w, video.tex_h = need_w, need_h
		video.tex_format = core.pixel_format
	}
	rect := sdl.Rect{0, 0, c.int(w), c.int(h)}
	_ = sdl.UpdateTexture(video.texture, &rect, data, c.int(pitch))
	video.frame_w, video.frame_h = w, h
	video.have_frame = true
}

video_aspect :: proc() -> f32 {
	g := core.av_info.geometry
	a := g.aspect_ratio
	if a <= 0 {
		if video.frame_h > 0 do a = f32(video.frame_w) / f32(video.frame_h)
		else if g.base_height > 0 do a = f32(g.base_width) / f32(g.base_height)
		else do a = 4.0 / 3.0
	}
	if core.rotation % 2 == 1 do a = 1 / a
	return a
}

// Fit the game into `area` (render pixels) according to the scale mode.
video_fit :: proc(area: sdl.FRect, mode: Scale_Mode) -> sdl.FRect {
	aspect := video_aspect()
	w, h: f32
	switch mode {
	case .Stretch:
		return area
	case .Aspect:
		w = area.w
		h = w / aspect
		if h > area.h {
			h = area.h
			w = h * aspect
		}
	case .Integer:
		bw := f32(video.frame_w if video.frame_w > 0 else int(core.av_info.geometry.base_width))
		bh := f32(video.frame_h if video.frame_h > 0 else int(core.av_info.geometry.base_height))
		if core.rotation % 2 == 1 do bw, bh = bh, bw
		// Integer scale on height; width follows the aspect ratio.
		s := math.floor(min(area.h / bh, area.w / (bh * aspect)))
		if s < 1 {
			return video_fit(area, .Aspect)
		}
		h = bh * s
		w = h * aspect
	}
	return {area.x + math.floor((area.w - w) / 2), area.y + math.floor((area.h - h) / 2), w, h}
}

video_draw :: proc(area: sdl.FRect, dim: bool = false) {
	if !video.have_frame || video.texture == nil do return
	dst := video_fit(area, settings.scale_mode)
	src := sdl.FRect{0, 0, f32(video.frame_w), f32(video.frame_h)}
	_ = sdl.SetTextureScaleMode(video.texture, .LINEAR if settings.video_filter else .NEAREST)
	if dim {
		_ = sdl.SetTextureColorMod(video.texture, 96, 96, 110)
	} else {
		_ = sdl.SetTextureColorMod(video.texture, 255, 255, 255)
	}
	if core.rotation == 0 {
		_ = sdl.RenderTexture(app.renderer, video.texture, &src, &dst)
	} else {
		// Rotated cores: rotate around the centre; swap w/h of the destination.
		rd := dst
		if core.rotation % 2 == 1 {
			rd = {dst.x + (dst.w - dst.h) / 2, dst.y + (dst.h - dst.w) / 2, dst.h, dst.w}
		}
		_ = sdl.RenderTextureRotated(app.renderer, video.texture, &src, &rd, f64(-90 * core.rotation), nil, .NONE)
	}
}

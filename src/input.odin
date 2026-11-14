package main

import sdl "vendor:sdl3"

import "emu"

MAX_GAMEPADS :: 4
STICK_DEADZONE :: 12000

Gamepads :: struct {
	pads: [MAX_GAMEPADS]^sdl.Gamepad,
}

gamepad_added :: proc(g: ^Gamepads, id: sdl.JoystickID) {
	for p in g.pads {
		if p != nil && sdl.GetGamepadID(p) == id {
			return
		}
	}
	for &p in g.pads {
		if p == nil {
			p = sdl.OpenGamepad(id)
			return
		}
	}
}

gamepad_removed :: proc(g: ^Gamepads, id: sdl.JoystickID) {
	for &p in g.pads {
		if p != nil && sdl.GetGamepadID(p) == id {
			sdl.CloseGamepad(p)
			p = nil
		}
	}
}

gamepads_close :: proc(g: ^Gamepads) {
	for &p in g.pads {
		if p != nil {
			sdl.CloseGamepad(p)
			p = nil
		}
	}
}

@(private = "file")
gamepad_buttons :: proc(p: ^sdl.Gamepad) -> (b: emu.Buttons) {
	if p == nil {
		return
	}
	MAP :: [?]struct {
		pad: sdl.GamepadButton,
		btn: emu.Button,
	} {
		{.DPAD_UP, .Up},
		{.DPAD_DOWN, .Down},
		{.DPAD_LEFT, .Left},
		{.DPAD_RIGHT, .Right},
		{.EAST, .A},
		{.SOUTH, .B},
		{.NORTH, .X},
		{.WEST, .Y},
		{.LEFT_SHOULDER, .L},
		{.RIGHT_SHOULDER, .R},
		{.BACK, .Select},
		{.START, .Start},
	}
	for m in MAP {
		if sdl.GetGamepadButton(p, m.pad) {
			b += {m.btn}
		}
	}
	x := sdl.GetGamepadAxis(p, .LEFTX)
	y := sdl.GetGamepadAxis(p, .LEFTY)
	if x < -STICK_DEADZONE {b += {.Left}}
	if x > STICK_DEADZONE {b += {.Right}}
	if y < -STICK_DEADZONE {b += {.Up}}
	if y > STICK_DEADZONE {b += {.Down}}
	if sdl.GetGamepadAxis(p, .LEFT_TRIGGER) > 16000 {b += {.L2}}
	if sdl.GetGamepadAxis(p, .RIGHT_TRIGGER) > 16000 {b += {.R2}}
	return
}

// Builds controller state from the keyboard bindings and attached gamepads.
read_input :: proc(cfg: ^Config, g: ^Gamepads) -> (input: emu.Input) {
	num_keys: i32
	state := sdl.GetKeyboardState(&num_keys)
	for pad in 0 ..< emu.MAX_PADS {
		for sc, btn in cfg.keys[pad] {
			idx := i32(sc)
			if sc != .UNKNOWN && idx > 0 && idx < num_keys && state[idx] {
				input.pads[pad] += {btn}
			}
		}
		input.pads[pad] += gamepad_buttons(g.pads[pad])
	}
	return
}

package main

import "core:strings"
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

// A gamepad input bound to an emulated button: an SDL gamepad button, one of
// the analog triggers, or nothing.
Pad_Input :: distinct i32

PAD_NONE :: Pad_Input(-1)
PAD_LEFT_TRIGGER :: Pad_Input(100)
PAD_RIGHT_TRIGGER :: Pad_Input(101)

Pad_Map :: [emu.Button]Pad_Input

DEFAULT_PAD_MAP :: Pad_Map {
	.Up     = Pad_Input(sdl.GamepadButton.DPAD_UP),
	.Down   = Pad_Input(sdl.GamepadButton.DPAD_DOWN),
	.Left   = Pad_Input(sdl.GamepadButton.DPAD_LEFT),
	.Right  = Pad_Input(sdl.GamepadButton.DPAD_RIGHT),
	.A      = Pad_Input(sdl.GamepadButton.EAST),
	.B      = Pad_Input(sdl.GamepadButton.SOUTH),
	.X      = Pad_Input(sdl.GamepadButton.NORTH),
	.Y      = Pad_Input(sdl.GamepadButton.WEST),
	.L      = Pad_Input(sdl.GamepadButton.LEFT_SHOULDER),
	.R      = Pad_Input(sdl.GamepadButton.RIGHT_SHOULDER),
	.L2     = PAD_LEFT_TRIGGER,
	.R2     = PAD_RIGHT_TRIGGER,
	.Select = Pad_Input(sdl.GamepadButton.BACK),
	.Start  = Pad_Input(sdl.GamepadButton.START),
}

TRIGGER_THRESHOLD :: 16000

// Name used in the config file and the input window ("a", "dpup",
// "lefttrigger", ...), following SDL's gamepad mapping names.
pad_input_name :: proc(p: Pad_Input) -> string {
	switch p {
	case PAD_NONE: return ""
	case PAD_LEFT_TRIGGER: return "lefttrigger"
	case PAD_RIGHT_TRIGGER: return "righttrigger"
	}
	if p >= 0 && p <= Pad_Input(max(sdl.GamepadButton)) {
		if n := sdl.GetGamepadStringForButton(sdl.GamepadButton(p)); n != nil {
			return string(n)
		}
	}
	return ""
}

pad_input_from_name :: proc(name: string) -> Pad_Input {
	switch name {
	case "": return PAD_NONE
	case "lefttrigger": return PAD_LEFT_TRIGGER
	case "righttrigger": return PAD_RIGHT_TRIGGER
	}
	b := sdl.GetGamepadButtonFromString(strings.clone_to_cstring(name, context.temp_allocator))
	if b == .INVALID {
		return PAD_NONE
	}
	return Pad_Input(b)
}

pad_input_held :: proc(p: ^sdl.Gamepad, in_: Pad_Input) -> bool {
	switch in_ {
	case PAD_NONE: return false
	case PAD_LEFT_TRIGGER: return sdl.GetGamepadAxis(p, .LEFT_TRIGGER) > TRIGGER_THRESHOLD
	case PAD_RIGHT_TRIGGER: return sdl.GetGamepadAxis(p, .RIGHT_TRIGGER) > TRIGGER_THRESHOLD
	}
	return sdl.GetGamepadButton(p, sdl.GamepadButton(in_))
}

@(private = "file")
gamepad_buttons :: proc(p: ^sdl.Gamepad, m: ^Pad_Map) -> (b: emu.Buttons) {
	if p == nil {
		return
	}
	for in_, btn in m {
		if pad_input_held(p, in_) {
			b += {btn}
		}
	}
	// The left stick always works as a d-pad too.
	x := sdl.GetGamepadAxis(p, .LEFTX)
	y := sdl.GetGamepadAxis(p, .LEFTY)
	if x < -STICK_DEADZONE {b += {.Left}}
	if x > STICK_DEADZONE {b += {.Right}}
	if y < -STICK_DEADZONE {b += {.Up}}
	if y > STICK_DEADZONE {b += {.Down}}
	return
}

// Player number (0-based) of the pad with this joystick id, or -1.
gamepad_player :: proc(g: ^Gamepads, id: sdl.JoystickID) -> int {
	for p, i in g.pads {
		if p != nil && sdl.GetGamepadID(p) == id {
			return i
		}
	}
	return -1
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
		input.pads[pad] += gamepad_buttons(g.pads[pad], &cfg.pad_map[pad])
	}
	return
}

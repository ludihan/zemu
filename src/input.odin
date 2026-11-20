package zemu

// RetroPad input from keyboard, gamepads and the on-screen touch pad.

import "core:c"
import retro "libretro"
import sdl "vendor:sdl3"

MAX_PORTS :: 4
NUM_BUTTONS :: 16

Pad_State :: struct {
	buttons: u16,       // bit per retro.Joypad_Id
	analog:  [2][2]i16, // [stick][axis]
}

Input :: struct {
	pads:      [MAX_PORTS]Pad_State,
	gamepads:  [MAX_PORTS]^sdl.Gamepad,
	touch_pad: Pad_State, // filled by the mobile on-screen controls, merged into port 0
}

input: Input

BUTTON_NAMES := [NUM_BUTTONS]string{
	"B", "Y", "SELECT", "START", "UP", "DOWN", "LEFT", "RIGHT",
	"A", "X", "L", "R", "L2", "R2", "L3", "R3",
}

// Default keyboard layout for player 1, close to ZSNES' defaults.
DEFAULT_KEYS := [NUM_BUTTONS]sdl.Scancode{
	.Z,       // B
	.A,       // Y
	.RSHIFT,  // SELECT
	.RETURN,  // START
	.UP, .DOWN, .LEFT, .RIGHT,
	.X,       // A
	.S,       // X
	.D,       // L
	.C,       // R
	.Q,       // L2
	.E,       // R2
	.UNKNOWN, // L3
	.UNKNOWN, // R3
}

GAMEPAD_MAP := [NUM_BUTTONS]sdl.GamepadButton{
	.SOUTH, .WEST, .BACK, .START,
	.DPAD_UP, .DPAD_DOWN, .DPAD_LEFT, .DPAD_RIGHT,
	.EAST, .NORTH, .LEFT_SHOULDER, .RIGHT_SHOULDER,
	.INVALID, .INVALID, // L2/R2 are triggers (axes)
	.LEFT_STICK, .RIGHT_STICK,
}

input_gamepad_added :: proc(id: sdl.JoystickID) {
	for &g in input.gamepads {
		if g != nil && sdl.GetGamepadID(g) == id do return
	}
	for &g in input.gamepads {
		if g == nil {
			g = sdl.OpenGamepad(id)
			if g != nil do osd_message("CONTROLLER CONNECTED")
			return
		}
	}
}

input_gamepad_removed :: proc(id: sdl.JoystickID) {
	for &g in input.gamepads {
		if g != nil && sdl.GetGamepadID(g) == id {
			sdl.CloseGamepad(g)
			g = nil
			osd_message("CONTROLLER DISCONNECTED")
		}
	}
}

// Read every input source into input.pads. Called from the core's input_poll,
// and by the GUI so it can be driven with a gamepad.
input_update :: proc() {
	keys := sdl.GetKeyboardState(nil)
	// Alt+Enter toggles fullscreen; don't also press whatever Enter is bound
	// to, including after Alt is let go while Enter is still down.
	@(static) enter_in_combo: bool
	if keys[sdl.Scancode.RETURN] {
		if keys[sdl.Scancode.LALT] || keys[sdl.Scancode.RALT] do enter_in_combo = true
	} else {
		enter_in_combo = false
	}
	for port in 0 ..< MAX_PORTS {
		p := &input.pads[port]
		p^ = {}
		if port == 0 && !app.gui_open {
			for sc, b in settings.keys {
				if enter_in_combo && sc == .RETURN do continue
				if sc != .UNKNOWN && keys[sc] do p.buttons |= 1 << u16(b)
			}
			p.buttons |= input.touch_pad.buttons
			for s in 0 ..< 2 do for a in 0 ..< 2 {
				if input.touch_pad.analog[s][a] != 0 do p.analog[s][a] = input.touch_pad.analog[s][a]
			}
		}
		g := input.gamepads[port]
		if g == nil do continue
		for btn, b in GAMEPAD_MAP {
			if btn != .INVALID && sdl.GetGamepadButton(g, btn) do p.buttons |= 1 << u16(b)
		}
		if sdl.GetGamepadAxis(g, .LEFT_TRIGGER) > 16000 do p.buttons |= 1 << u16(retro.Joypad_Id.L2)
		if sdl.GetGamepadAxis(g, .RIGHT_TRIGGER) > 16000 do p.buttons |= 1 << u16(retro.Joypad_Id.R2)
		p.analog[0][0] = sdl.GetGamepadAxis(g, .LEFTX)
		p.analog[0][1] = sdl.GetGamepadAxis(g, .LEFTY)
		p.analog[1][0] = sdl.GetGamepadAxis(g, .RIGHTX)
		p.analog[1][1] = sdl.GetGamepadAxis(g, .RIGHTY)
		// Cores that only read the d-pad still work with the stick.
		if settings.stick_as_dpad {
			DEAD :: 20000
			if p.analog[0][0] < -DEAD do p.buttons |= 1 << u16(retro.Joypad_Id.LEFT)
			if p.analog[0][0] >  DEAD do p.buttons |= 1 << u16(retro.Joypad_Id.RIGHT)
			if p.analog[0][1] < -DEAD do p.buttons |= 1 << u16(retro.Joypad_Id.UP)
			if p.analog[0][1] >  DEAD do p.buttons |= 1 << u16(retro.Joypad_Id.DOWN)
		}
	}
}

input_poll_cb :: proc "c" () {
	context = app_ctx
	input_update()
}

input_state_cb :: proc "c" (port, device, index, id: c.uint) -> i16 {
	if port >= MAX_PORTS do return 0
	p := &input.pads[port]
	switch retro.Device(device & retro.DEVICE_MASK) {
	case .JOYPAD:
		if id == retro.DEVICE_ID_JOYPAD_MASK do return i16(p.buttons)
		if id < NUM_BUTTONS do return 1 if p.buttons & (1 << u16(id)) != 0 else 0
	case .ANALOG:
		if index < 2 && id < 2 do return p.analog[index][id]
	case .NONE, .MOUSE, .KEYBOARD, .LIGHTGUN, .POINTER:
	}
	return 0
}

rumble_cb :: proc "c" (port: c.uint, effect: retro.Rumble_Effect, strength: u16) -> bool {
	context = app_ctx
	if port >= MAX_PORTS do return false
	g := input.gamepads[port]
	if g == nil do return false
	@(static) levels: [MAX_PORTS][2]u16
	levels[port][int(effect)] = strength
	return sdl.RumbleGamepad(g, levels[port][0], levels[port][1], 5000)
}

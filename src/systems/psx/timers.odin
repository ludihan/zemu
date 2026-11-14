package psx

// Root counters 0-2.

Timer :: struct {
	counter:  u32,
	mode:     u32,
	target:   u32,
	frac:     int,  // sub-tick accumulator (dot clock / sysclock-8 sources)
	paused:   bool,
	irq_done: bool, // one-shot IRQ already fired
}

@(private = "file", rodata)
DOT_DIVIDERS := [8]int{10, 7, 8, 7, 5, 7, 4, 7} // indexed like Gpu.hres

@(private = "file")
fire :: proc(c: ^Console, i: int, t: ^Timer) {
	if t.mode & (1 << 6) == 0 && t.irq_done {
		return
	}
	t.irq_done = true
	if t.mode & (1 << 7) != 0 {
		t.mode ~= 1 << 10 // toggle mode
		if t.mode & (1 << 10) != 0 {
			return
		}
	}
	request_irq(c, Irq(u32(Irq.Timer0) + u32(i)))
	if t.mode & (1 << 7) == 0 {
		t.mode |= 1 << 10 // pulse mode returns high right away
	}
}

@(private = "file")
advance :: proc(c: ^Console, i: int, n: u32) {
	t := &c.timers[i]
	if t.paused || n == 0 {
		return
	}
	target := t.target & 0xFFFF
	old := t.counter
	v := old + n
	if old < target && v >= target || (old == target && n > 0 && target == 0) {
		t.mode |= 1 << 11
		if t.mode & (1 << 4) != 0 {
			fire(c, i, t)
		}
	}
	if t.mode & (1 << 3) != 0 {
		if v > target {
			v = target == 0 ? 0 : (v - target - 1) % (target + 1)
		}
	}
	if v > 0xFFFF {
		v &= 0xFFFF
		t.mode |= 1 << 12
		if t.mode & (1 << 5) != 0 {
			fire(c, i, t)
		}
	}
	t.counter = v
}

timers_tick :: proc(c: ^Console, cycles: int) {
	// timer 0: system clock or GPU dot clock
	t0 := &c.timers[0]
	if (t0.mode >> 8) & 1 != 0 {
		// dot clock = GPU clock / divider; GPU clock = CPU clock * 11/7
		t0.frac += cycles * 11
		div := DOT_DIVIDERS[c.gpu.hres & 7] * 7
		advance(c, 0, u32(t0.frac / div))
		t0.frac %= div
	} else {
		advance(c, 0, u32(cycles))
	}
	// timer 1: system clock (or hblank, counted in timers_hblank)
	if (c.timers[1].mode >> 8) & 1 == 0 {
		advance(c, 1, u32(cycles))
	}
	// timer 2: system clock or system clock / 8
	t2 := &c.timers[2]
	if t2.mode & 1 != 0 && (t2.mode >> 1) & 3 == 0 || t2.mode & 1 != 0 && (t2.mode >> 1) & 3 == 3 {
		return // synchronization modes 0 and 3 stop the counter
	}
	if (t2.mode >> 9) & 1 != 0 {
		t2.frac += cycles
		advance(c, 2, u32(t2.frac / 8))
		t2.frac %= 8
	} else {
		advance(c, 2, u32(cycles))
	}
}

timers_hblank :: proc(c: ^Console) {
	if (c.timers[1].mode >> 8) & 1 != 0 {
		advance(c, 1, 1)
	}
}

timers_vblank :: proc(c: ^Console, entering: bool) {
	t := &c.timers[1]
	if t.mode & 1 == 0 {
		t.paused = false
		return
	}
	switch (t.mode >> 1) & 3 {
	case 0: t.paused = entering
	case 1:
		if entering {t.counter = 0}
	case 2:
		if entering {t.counter = 0}
		t.paused = !entering
	case 3:
		if entering {
			t.paused = false
			t.mode &= ~u32(1) // free-run afterwards
		}
	}
}

timer_read :: proc(c: ^Console, p: u32) -> u32 {
	i := int((p >> 4) & 3)
	if i > 2 {
		return 0
	}
	t := &c.timers[i]
	switch p & 0xF {
	case 0x0:
		return t.counter
	case 0x4:
		v := t.mode
		t.mode &= ~u32(1 << 11 | 1 << 12)
		return v
	case 0x8:
		return t.target
	}
	return 0
}

timer_write :: proc(c: ^Console, p: u32, v: u32) {
	i := int((p >> 4) & 3)
	if i > 2 {
		return
	}
	t := &c.timers[i]
	switch p & 0xF {
	case 0x0:
		t.counter = v & 0xFFFF
	case 0x4:
		t.mode = (v & 0x3FF) | (1 << 10)
		t.counter = 0
		t.irq_done = false
		t.paused = false
		if i == 1 && t.mode & 1 != 0 && (t.mode >> 1) & 3 == 3 {
			t.paused = true // wait for the next vblank
		}
	case 0x8:
		t.target = v & 0xFFFF
	}
}

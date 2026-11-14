package psx

Dma_Port :: enum u32 {
	Mdec_In  = 0,
	Mdec_Out = 1,
	Gpu      = 2,
	Cdrom    = 3,
	Spu      = 4,
	Pio      = 5,
	Otc      = 6,
}

Dma_Channel :: struct {
	madr: u32,
	bcr:  u32,
	chcr: u32,
}

Dma :: struct {
	ch:   [7]Dma_Channel,
	dpcr: u32,
	dicr: u32,
}

@(private = "file")
dicr_master :: proc(d: ^Dma) -> bool {
	force := d.dicr & (1 << 15) != 0
	enabled := d.dicr & (1 << 23) != 0
	pending := (d.dicr >> 16) & (d.dicr >> 24) & 0x7F
	return force || (enabled && pending != 0)
}

@(private = "file")
update_dicr :: proc(c: ^Console) {
	d := &c.dma
	was := d.dicr & (1 << 31) != 0
	now := dicr_master(d)
	if now {d.dicr |= 1 << 31} else {d.dicr &= ~u32(1 << 31)}
	if now && !was {
		request_irq(c, .Dma)
	}
}

dma_read :: proc(c: ^Console, p: u32) -> u32 {
	off := p - 0x1F80_1080
	ch := off >> 4
	if ch == 7 {
		switch off & 0xF {
		case 0x0: return c.dma.dpcr
		case 0x4: return c.dma.dicr
		}
		return 0
	}
	chan := &c.dma.ch[ch]
	switch off & 0xF {
	case 0x0: return chan.madr
	case 0x4: return chan.bcr
	case 0x8: return chan.chcr
	}
	return 0
}

dma_write :: proc(c: ^Console, p: u32, v: u32) {
	off := p - 0x1F80_1080
	ch := off >> 4
	if ch == 7 {
		switch off & 0xF {
		case 0x0:
			c.dma.dpcr = v
			// Channels already armed start as soon as they are enabled.
			for port in Dma_Port {
				try_start(c, port)
			}
		case 0x4:
			keep := c.dma.dicr & 0x7F00_0000
			ack := v & 0x7F00_0000
			c.dma.dicr = (v & 0x00FF_803F) | (keep & ~ack)
			update_dicr(c)
		}
		return
	}
	chan := &c.dma.ch[ch]
	switch off & 0xF {
	case 0x0: chan.madr = v & 0x00FF_FFFF
	case 0x4: chan.bcr = v
	case 0x8:
		if ch == u32(Dma_Port.Otc) {
			// OTC only allows a few bits; direction and step are fixed.
			chan.chcr = (v & 0x5100_0000) | 0x2
		} else {
			chan.chcr = v
		}
		try_start(c, Dma_Port(ch))
	}
}

@(private = "file")
try_start :: proc(c: ^Console, port: Dma_Port) {
	chan := &c.dma.ch[port]
	enabled := c.dma.dpcr & (1 << (u32(port) * 4 + 3)) != 0
	sync := (chan.chcr >> 9) & 3
	trigger := chan.chcr & (1 << 28) != 0
	if chan.chcr & (1 << 24) == 0 || !enabled || (sync == 0 && !trigger) {
		return
	}
	run(c, port)
	chan.chcr &= ~u32(1 << 24 | 1 << 28)
	if c.dma.dicr & (1 << (16 + u32(port))) != 0 {
		c.dma.dicr |= 1 << (24 + u32(port))
	}
	update_dicr(c)
}

@(private = "file")
run :: proc(c: ^Console, port: Dma_Port) {
	chan := &c.dma.ch[port]
	sync := (chan.chcr >> 9) & 3
	from_ram := chan.chcr & 1 != 0
	step: u32 = chan.chcr & 2 != 0 ? ~u32(3) : 4 // -4 or +4

	if port == .Otc {
		count := chan.bcr & 0xFFFF
		if count == 0 {count = 0x10000}
		addr := chan.madr & 0x1F_FFFC
		for i in 0 ..< count {
			v: u32 = i == count - 1 ? 0x00FF_FFFF : (addr - 4) & 0x1F_FFFF
			ram_write32(c, addr, v)
			addr = (addr - 4) & 0x1F_FFFC
		}
		return
	}

	if sync == 2 {
		// linked list (GPU command lists)
		addr := chan.madr & 0x1F_FFFC
		for _ in 0 ..< 0x10_0000 { // guard against cyclic lists
			header := ram_read32(c, addr)
			n := header >> 24
			for k in 1 ..= n {
				gpu_gp0(&c.gpu, ram_read32(c, addr + k * 4))
			}
			if header & 0x0080_0000 != 0 {
				break
			}
			addr = header & 0x1F_FFFC
		}
		chan.madr = 0x00FF_FFFF
		gpu_check_irq(c)
		return
	}

	words: u32
	if sync == 0 {
		words = chan.bcr & 0xFFFF
		if words == 0 {words = 0x10000}
	} else {
		words = (chan.bcr & 0xFFFF) * (chan.bcr >> 16)
	}
	addr := chan.madr & 0x1F_FFFC
	for _ in 0 ..< words {
		if from_ram {
			v := ram_read32(c, addr)
			#partial switch port {
			case .Gpu:     gpu_gp0(&c.gpu, v)
			case .Spu:     spu_dma_write(&c.spu, v)
			case .Mdec_In: mdec_write_command(c, v)
			}
		} else {
			v: u32
			#partial switch port {
			case .Gpu:      v = gpu_read(&c.gpu)
			case .Cdrom:    v = cdrom_dma_read(&c.cdrom)
			case .Spu:      v = spu_dma_read(&c.spu)
			case .Mdec_Out: v = mdec_read_data(c)
			}
			ram_write32(c, addr, v)
		}
		addr = (addr + step) & 0x1F_FFFC
	}
	if sync == 1 {
		chan.madr = addr
		chan.bcr &= 0xFFFF // block count reaches zero
	}
	if port == .Gpu {
		gpu_check_irq(c)
	}
}

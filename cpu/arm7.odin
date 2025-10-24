package cpu

import "core:fmt"
import "base:intrinsics"

arm7_reset :: proc(pc: u32) {
    halt = false
    stop = false
    regs = {}
    pipeline = {}
    PC = pc
    CPSR = Flags(0)
    refetch = false
    cpu_init()
}

arm7_step :: proc() -> u32 {
    cpu_exec_irq()

    if(stop || halt) {
        return 1
    }

    cycles: u32
    if(CPSR.Thumb) {
        cycles = cpu_exec_thumb(u16(pipeline[0]))
    } else {
        cycles = cpu_exec_arm(pipeline[0])
    }
    if(refetch) {
        refetch = false
        if(CPSR.Thumb) {
            cpu_refetch16()
        } else {
            cpu_refetch32()
        }
    }
    return cycles
}

arm7_stop :: proc() {
    stop = true
}

arm7_halt :: proc() {
    halt = true
}

arm7_get_stop :: proc() -> bool {
    return stop
}

arm7_reg_get :: proc(reg: Regs) -> u32 {
    return cpu_reg_get(reg)
}

arm7_get_cpsr :: proc() -> Flags {
    return CPSR
}

arm7_get_instruction :: proc(idx: u32) -> u32 {
    if(CPSR.Thumb) {
        return u32(pipeline[idx] & 0xFFFF)
    } else {
        return pipeline[idx]
    }
}

arm7_init_no_bios :: proc() {
    cpu_reg_set(Regs.R0, 0x00000CA5)
    CPSR = Flags(0x1F)
    regs[Regs.SP][u16(Modes.M_SUPERVISOR) - 16] = 0x03007FE0
    regs[Regs.SP][u16(Modes.M_IRQ) - 16] = 0x03007FA0
    cpu_reg_set(Regs.SP, 0x03007F00)
    cpu_reg_set(Regs.LR, 0x08000000)
}

@(private="file")
cpu_exec_arm :: proc(opcode: u32) -> u32 {
    cpu_prefetch32()
    //4 uppermost bits are conditional, if they match, execute, otherwise return
    exec := true
    cond := opcode & 0xF0000000
    switch(cond) {
    case 0x00000000: //EQ - Z set
        if(!CPSR.Z) {
            exec = false
        }
        break
    case 0x10000000: //NE - Z clear
        if(CPSR.Z) {
            exec = false
        }
        break
    case 0x20000000: //CS - C set
        if(!CPSR.C) {
            exec = false
        }
        break
    case 0x30000000: //CC - C clear
        if(CPSR.C) {
            exec = false
        }
        break
    case 0x40000000: //MI - N set
        if(!CPSR.N) {
            exec = false
        }
        break
    case 0x50000000: //PL - N clear
        if(CPSR.N) {
            exec = false
        }
        break
    case 0x60000000: //VS - V set
        if(!CPSR.V) {
            exec = false
        }
        break
    case 0x70000000: //VC - V clear
        if(CPSR.V) {
            exec = false
        }
        break
    case 0x80000000: //HI - C set and Z clear
        if(!(CPSR.C && !CPSR.Z)) {
            exec = false
        }
        break
    case 0x90000000: //LS - C clear OR Z set
        if(!(!CPSR.C || CPSR.Z)) {
            exec = false
        }
        break
    case 0xA0000000: //GE - N == V
        if(CPSR.N != CPSR.V) {
            exec = false
        }
        break
    case 0xB0000000: //LT - N != V
        if(CPSR.N == CPSR.V) {
            exec = false
        }
        break
    case 0xC0000000: //GT - Z clear and (N == V)
        if(!(!CPSR.Z && (CPSR.N == CPSR.V))) {
            exec = false
        }
        break
    case 0xD0000000: //LE - Z set or (N != V)
        if(!(CPSR.Z || (CPSR.N != CPSR.V))) {
            exec = false
        }
        break
    case 0xE0000000: //AL - Always run
        break
    }

    if(!exec) {
        PC += 4
        return 1
    }

    id := opcode & 0xE000000
    retval: u32
    switch(id) {
    case 0x0000000:
    {
        if((opcode & 0xFFFFFC0) == 0x12FFF00) {
            retval = cpu_bx(opcode)
        } else if((opcode & 0x10000F0) == 0x0000090) { //MUL, MLA
            if(utils_bit_get32(opcode, 23)) { //MULL, MLAL
                retval = cpu_mull_mlal(opcode)
            } else {
                retval = cpu_mul_mla(opcode)
            }
        } else if((opcode & 0x10000F0) == 0x1000090) {
            retval = cpu_swap(opcode)
        } else if(((opcode & 0xF0) == 0xB0) || ((opcode & 0xD0) == 0xD0)) {
            retval = cpu_hw_transfer(opcode)
        } else { //ALU reg
            retval = cpu_arm_alu(opcode, false)
        }
        break
    }
    case 0x2000000: //ALU immediate
        retval = cpu_arm_alu(opcode, true)
        break
    case 0x4000000: //LDR, STR immediate
        retval = cpu_ldr(opcode, false)
        break
    case 0x6000000: //LDR, STR register
        retval = cpu_ldr(opcode, true)
        break
    case 0x8000000: //LDM, STM (PUSH, POP)
        retval = cpu_ldm_stm(opcode)
        break
    case 0xA000000: //B, BL, BLX
        retval = cpu_b_bl(opcode)
        break
    case 0xC000000: //LDC, STC
        retval = cpu_ldc_stc(opcode)
        break
    case 0xE000000: //SWI
        if(utils_bit_get32(opcode, 24)) {
            retval = cpu_swi()
        } else {
            if(utils_bit_get32(opcode, 4)) {
                retval = cpu_mrc_mcr(opcode)
            } else {
                retval = cpu_cdp(opcode)
            }
        }
        break
    case:
        fmt.print("Unimplemented arm code: ")
        fmt.println(opcode)
        break
    }
    return retval
}

@(private="file")
cpu_bx :: proc(opcode: u32) -> u32 {
    Rn := Regs(opcode & 0xF)
    value := cpu_reg_get(Rn)
    thumb := utils_bit_get32(value, 0)
    PC += 4
    if(thumb) {
        CPSR.Thumb = true
        cpu_reg_set(Regs.PC, (value & 0xFFFFFFFE))
    } else {
        cpu_reg_set(Regs.PC, value)
    }
    return 3
}

@(private="file")
cpu_hw_transfer :: proc(opcode: u32) -> u32 {
    P := utils_bit_get32(opcode, 24)
    U := utils_bit_get32(opcode, 23)
    I := utils_bit_get32(opcode, 22)
    W := true
    if(P) {
        W = utils_bit_get32(opcode, 21)
    }
    L := utils_bit_get32(opcode, 20)
    Rn := Regs((opcode & 0xF0000) >> 16)
    Rd := Regs((opcode & 0xF000) >> 12)
    offs2 := (opcode & 0xF00) >> 4
    op := opcode & 0x60
    Rm := Regs(opcode & 0xF)
    offset := i64(cpu_reg_get(Rm))
    address := cpu_reg_get(Rn)
    cycles: u32
    data: u32

    if(I) {
        offset = i64(Rm) + i64(offs2)
    }
    if(!U) {
        offset = -offset
    }

    address = u32(i64(address) + i64(P) * offset) //Pre increment
    PC += 4
    
    if(L) {
        switch(op) {
        case 0x20: //LDRH
            shift := address & 0x1
            data = u32(bus_read16(address))
            if(shift == 1) {
                data = cpu_ror32(data, 8)
            }
            address = u32(i64(address) + (1 - i64(P)) * offset) //Post increment
            if(W && !((Rn == Regs.PC) && (Rd == Regs.PC))) {
                if(Rn == Regs.PC) {
                    cpu_reg_set(Rn, address + 4)
                } else {
                    cpu_reg_set(Rn, address)
                }
        }
            break
        case 0x40: //LDRSB
            data = u32(i32(i8(bus_read8(address))))
            address = u32(i64(address) + (1 - i64(P)) * offset) //Post increment
            if(W) {
                if(Rn == Regs.PC) {// writeback fails. technically invalid here
                    if(Rd != Regs.PC) {
                        cpu_reg_set(Rn, address + 4)
                    }
                } else {
                    cpu_reg_set(Rn, address)
                }
            }
            break
        case 0x60: //LDRSH
            data = u32(i32(i16(bus_read16(address))))
            shift := address & 0x1
            if(shift == 1) {
                data = u32(i32(i16(cpu_ror32(data, 8))))
            }
            address = u32(i64(address) + (1 - i64(P)) * offset) //Post increment
            if(W) {
                if(Rn == Regs.PC) {// writeback fails. technically invalid here
                    if(Rd != Regs.PC) {
                        cpu_reg_set(Rn, address + 4)
                    }
                } else {
                    cpu_reg_set(Rn, address)
                }
            }
            break
        }
        cpu_reg_set(Rd, data)
        cycles = 3
    } else {
        switch(op) {
        case 0x20: //STRH
            value := cpu_reg_get(Rd)
            bus_write16(address, u16(value))
            cycles = 2
            address = u32(i64(address) + (1 - i64(P)) * offset) //Post increment
            if(W) {
                if(Rn == Regs.PC) {
                    cpu_reg_set(Rn, address + 4)
                } else {
                    cpu_reg_set(Rn, address)
                }
            }
        }
    }
    return cycles
}

@(private="file")
cpu_mrc_mcr :: proc(opcode: u32) -> u32 {
    cpu_unknown_irq()
    return 3
}

@(private="file")
cpu_ldr :: proc(opcode: u32, I: bool) -> u32 {
    P := i64(utils_bit_get32(opcode, 24))
    U := utils_bit_get32(opcode, 23)
    B := utils_bit_get32(opcode, 22)
    W := true
    if(bool(P)) {
        W = utils_bit_get32(opcode, 21)
    }
    L := utils_bit_get32(opcode, 20)
    Rn := Regs((opcode & 0xF0000) >> 16)
    Rd := Regs((opcode & 0xF000) >> 12)
    offset: i64
    address := cpu_reg_get(Rn)
    logic_carry: bool
    data: u32

    if(I) {
        offset = i64(cpu_reg_shift(opcode, &logic_carry)) //Carry not used
    } else {
        offset = i64(opcode & 0xFFF)
    }
    if(!U) {
        offset = -offset
    }
    PC += 4
    address = u32(i64(address) + P * offset) //Pre increment
    if(L) {
        if(B) { //LDRB
            data = u32(bus_read8(address))
        } else { //LDR
            shift := address & 0x3
            data = bus_read32(address)
            if(shift > 0) {
                data = cpu_ror32(data, shift * 8)
            }
        }
        address = u32(i64(address) + (1 - P) * offset) //Post increment
        if(W) {
            if(Rn == Regs.PC) {
                cpu_reg_set(Rn, address + 4)
            } else {
                cpu_reg_set(Rn, address)
            }
        }
        cpu_reg_set(Rd, data)
    } else {
        if(B) { //STRB
            bus_write8(address, u8(cpu_reg_get(Rd)))
        } else { //STR
            value := cpu_reg_get(Rd)
            bus_write32(address, value)
        }
        address = u32(i64(address) + (1 - P) * offset) //Post increment
        if(W) {
            if(Rn == Regs.PC) {
                cpu_reg_set(Rn, address + 4)
            } else {
                cpu_reg_set(Rn, address)
            }
        }
    }
    return 3
}

@(private="file")
cpu_ldm_stm :: proc(opcode: u32) -> u32 {
    P := utils_bit_get32(opcode, 24)
    U := utils_bit_get32(opcode, 23)
    S := utils_bit_get32(opcode, 22)
    W := utils_bit_get32(opcode, 21)
    L := utils_bit_get32(opcode, 20)
    Rn := Regs((opcode & 0xF0000) >> 16)
    rlist := u16(opcode & 0xFFFF)
    cycles: u32 = 2
    rcount: u32
    first :u8= 20
    for i :u8= 0; i < 16; i += 1 {
        if(utils_bit_get16(rlist, i)) {
            rcount += 1
            if(first == 20) {
                first = i
            }
        }
    }
    num_regs := rcount << 2 // 4 byte per register

    if(rlist == 0) {
        rlist = 0x8000
        first = 15
        num_regs = 64
    }
    move_pc := bool((rlist >> 15) & 1)

    address := cpu_reg_get(Rn)
    base_addr := address

    mode_switch := S && (!L || !move_pc)
    old_mode := CPSR.Mode
    if(mode_switch) {
        CPSR.Mode = Modes.M_USER
    }

    if(!U) {
        P = !P
        address -= num_regs
        base_addr -= num_regs
    } else {
        base_addr += num_regs
    }

    PC += 4

    for i :u8= first; i < 16; i += 1 {
        if(bool(~rlist & (1 << i))) {
            continue
        }
        i := Regs(i)
        if(P) {
            address += 4
        }
        if(L) {
            data := bus_read32(address)
            if(W && (u8(i) == first)) {
                cpu_reg_set(Rn, base_addr)
            }
            cpu_reg_set(i, data)
        } else {
            bus_write32(address, cpu_reg_get(i))
            if(W && (u8(i) == first)) {
                cpu_reg_set(Rn, base_addr)
            }
        }
        if(!P) {
            address += 4
        }
        cycles += 1
    }
    if(L) {
        if(move_pc && S) {
            CPSR |= Flags(0x10)
            CPSR = Flags(cpu_reg_get(Regs.SPSR))
        }
    }
    if(mode_switch) {
        CPSR.Mode = old_mode
    }
    return cycles
}

@(private="file")
cpu_exec_thumb :: proc(opcode: u16) -> u32 {
    cpu_prefetch16()
    id := opcode & 0xF800
    retval :u32= 0

    switch(id) {
    case 0x0000, 0x0800, 0x1000:
        retval = cpu_shift(opcode)
        break
    case 0x1800:
        retval = cpu_add_sub(opcode)
        break
    case 0x2000, //Move, compare
         0x2800, //add, substract
         0x3000, //add, substract
         0x3800: //add, substract
        retval = cpu_mcas_imm(opcode)
        break
    case 0x4000:
        if(utils_bit_get16(opcode, 10)) {
            retval = cpu_hi_reg(opcode)
        } else {
            retval = cpu_alu(opcode)
        }
        break
    case 0x4800:
        retval = cpu_ld_pc(opcode)
        break
    case 0x5000,
         0x5800:
        if(utils_bit_get16(opcode, 9)) {
            retval = cpu_ls_ext(opcode)
        } else {
            retval = cpu_ls_reg(opcode)
        }
        break
    case 0x6000,
         0x6800,
         0x7000,
         0x7800:
        retval = cpu_ls_imm(opcode)
        break
    case 0x8000,
         0x8800:
        retval = cpu_ls_hw(opcode)
        break
    case 0x9000,
         0x9800:
        retval = cpu_ls_sp(opcode)
        break
    case 0xA000,
         0xA800:
        retval = cpu_ld(opcode)
        break
    case 0xB000,
         0xB800:
        if(utils_bit_get16(opcode, 10)) {
            retval = cpu_push_pop(opcode)
        } else {
            retval = cpu_sp_ofs(opcode)
        }
        break
    case 0xC000,
         0xC800:
        retval = cpu_ls_mp(opcode)
        break
    case 0xD000,
         0xD800:
        retval = cpu_b_cond(opcode)
        break
    case 0xE000:
        retval = cpu_b_uncond(opcode)
        break
    case 0xF000,
         0xF800:
        retval = cpu_bl(opcode)
        break
    case:
        fmt.print("Unimplemented thumb code: ")
        fmt.println(opcode)
        break
    }
    return retval
}

@(private="file")
cpu_hi_reg :: proc(opcode: u16) -> u32 {
    Op := (opcode & 0x0300) >> 8
    H1 := Regs(u8(utils_bit_get16(opcode, 7)) * 8)
    H2 := Regs(u8(utils_bit_get16(opcode, 6)) * 8)
    Rs := Regs((opcode & 0x0038) >> 3)
    Rd := Regs(opcode & 0x0007)
    res: u32
    cycles :u32= 1

    switch(Op) {
    case 0:
        cpu_reg_set(Rd + H1, cpu_reg_get(Rd + H1) + cpu_reg_get(Rs + H2))
        break
    case 1: //CMP
        RsReg := cpu_reg_get(Rs + H2)
        RdReg := cpu_reg_get(Rd + H1)
        res = RdReg - RsReg
        CPSR.Z = res == 0
        CPSR.N = bool(res >> 31)
        CPSR.C = RdReg >= RsReg
        CPSR.V = bool(((RdReg ~ RsReg) & (RdReg ~ res)) >> 31)
        break
    case 2: //MOV
        cpu_reg_set(Rd + H1, cpu_reg_get(Rs + H2))
        break
    case 3: //BX
        value := cpu_reg_get(Rs + H2)
        thumb := utils_bit_get32(value, 0)
        CPSR.Thumb = thumb
        if(thumb) {
            cpu_reg_set(Regs.PC, (value & 0xFFFFFFFE))
        } else {
            cpu_reg_set(Regs.PC, value)
        }
        cycles += 2
        break
    }
    return cycles
}

@(private="file")
cpu_bl :: proc(opcode: u16) -> u32 {
    if(!utils_bit_get16(opcode, 11)) {
        imm := i16(opcode & 0x7FF) << 5
        imm2 := u32(i32(PC) - 2 + i32(u32(i32(imm)) << 7))
        cpu_reg_set(Regs.LR, imm2)
        return 1
    } else {
        tmp_pc := PC
        imm := u32(opcode & 0x7FF) << 1
        cpu_reg_set(Regs.PC, cpu_reg_get(Regs.LR) + imm)
        cpu_reg_set(Regs.LR, (tmp_pc | 1) - 4)
        return 3
    }
}

@(private="file")
cpu_push_pop :: proc(opcode: u16) -> u32 {
    R := utils_bit_get16(opcode, 8)
    L := utils_bit_get16(opcode, 11)
    imm := u32(opcode & 0x00FF)
    sp := cpu_reg_get(Regs.SP)
    cycles :u32= 2

    if(L) { //POP - post-increment
        for i :u8= 0; i < 8; i += 1 {
            if(utils_bit_get32(imm, i)) {
                cpu_reg_set(Regs(i), bus_read32(sp))
                sp += 4
                cycles += 1
            }
        }
        if(R || imm == 0) { //POP PC
            pc := bus_read32(sp)
            if(imm == 0 && !R) {
                PC = pc
                refetch = true
                sp += 60
            } else {
                cpu_reg_set(Regs.PC, utils_bit_clear32(pc, 0))
            }
            sp += 4
            cycles += 1
        }
        cpu_reg_set(Regs.SP, sp)
    } else { //PUSH - pre-decrement
        sp -= intrinsics.count_ones(imm) * 4 + (u32(R) * 4)
        cpu_reg_set(Regs.SP, sp)
        for i :u8= 0; i < 8; i += 1 {
            if(utils_bit_get32(imm, i)) {
                bus_write32(sp, cpu_reg_get(Regs(i)))
                sp += 4
                cycles += 1
            }
        }
        if(R || imm == 0) { //PUSH LR
            if(imm == 0 && !R) {
                sp -= 64
                bus_write32(sp, PC)
                cpu_reg_set(Regs.SP, sp)
            } else {
                bus_write32(sp, cpu_reg_get(Regs.LR))
            }
            cycles += 1
        }
    }
    return cycles
}

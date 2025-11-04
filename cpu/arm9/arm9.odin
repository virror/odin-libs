package arm9

import "core:fmt"
import "base:intrinsics"

IO_IME :u32: 0x4000208
IO_IE :u32: 0x4000210
IO_IF :u32: 0x4000214

Regs :: enum {
    R0 = 0,
    R1 = 1,
    R2 = 2,
    R3 = 3,
    R4 = 4,
    R5 = 5,
    R6 = 6,
    R7 = 7,
    R8 = 8,
    R9 = 9,
    R10 = 10,
    R11 = 11,
    R12 = 12,
    SP = 13,
    LR = 14,
    PC = 15,
    SPSR = 17,
}

Modes :: enum u8 {
    M_USER = 16,
    M_FIQ = 17,
    M_IRQ = 18,
    M_SUPERVISOR = 19,
    M_ABORT = 23,
    M_UNDEFINED = 27,
    M_SYSTEM = 31,
}

Flags :: bit_field u32 {
    Mode: Modes   | 5,
    Thumb: bool   | 1,
    FIQ: bool     | 1,
    IRQ: bool     | 1,
    Reserved: u32 | 19,
    Q: bool       | 1,
    V: bool       | 1,
    C: bool       | 1,
    Z: bool       | 1,
    N: bool       | 1,
}

bus_read8: proc(addr: u32, width: u8 = 1) -> u8
bus_read16: proc(addr: u32) -> u16
bus_read32: proc(addr: u32) -> u32
bus_write8: proc(addr: u32, value: u8, width: u8 = 1)
bus_write16: proc(addr: u32, value: u16)
bus_write32: proc(addr: u32, value: u32)
bus_get16: proc(addr: u32) -> u16
bus_get32: proc(addr: u32) -> u32

@(private="file")
halt := false
@(private="file")
stop := false
@(private="file")
regs: [18][15]u32
@(private="file")
pipeline: [3]u32
@(private="file")
PC: u32
@(private="file")
CPSR: Flags
@(private="file")
refetch: bool

cp15_read: proc(CRn: u32, CRm: u32, CP: u32) -> u32
cp15_write: proc(CRn: u32, CRm: u32, CP: u32, value: u32)

@(private="file")
cpu_init :: proc() {
    CPSR.Mode = Modes.M_SUPERVISOR
    cpu_refetch32()
}

@(private="file")
cpu_refetch16 :: proc() {
    pipeline[0] = u32(bus_read16(PC & 0xFFFFFFFE))
    pipeline[1] = u32(bus_read16((PC + 2) & 0xFFFFFFFE))
    PC += 4
}

@(private="file")
cpu_refetch32 :: proc() {
    pipeline[0] = bus_get32(PC)
    pipeline[1] = bus_get32(PC + 4)
    PC += 8
}

@(private="file")
cpu_prefetch16 :: proc() {
    pipeline[2] = u32(bus_read16(PC))
    pipeline[0] = pipeline[1]
    pipeline[1] = pipeline[2]
    PC += 2
}

@(private="file")
cpu_prefetch32 :: proc() {
    pipeline[2] = bus_get32(PC)
    pipeline[0] = pipeline[1]
    pipeline[1] = pipeline[2]
}

@(private="file")
cpu_reg_get :: proc(reg: Regs) -> u32 {
    switch(reg) {
    case Regs.SPSR:
        mode := CPSR.Mode
        if(mode == Modes.M_USER || mode == Modes.M_SYSTEM) {
            return u32(CPSR)
        } else {
            return regs[reg][u32(mode) - 16]
        }
    case Regs.SP, Regs.LR:
        mode := CPSR.Mode
        if(mode == Modes.M_USER || mode == Modes.M_SYSTEM) {
            return regs[reg][0]
        } else {
            return regs[reg][u32(mode) - 16]
        }
    case Regs.PC:
        if(CPSR.Thumb) {
            return PC - 2
        } else {
            return PC
        }
    case Regs.R8..=Regs.R12:
        mode := CPSR.Mode
        if(mode == Modes.M_FIQ) {
            return regs[reg][u32(Modes.M_FIQ) - 16]
        } else {
            return regs[reg][0]
        }
    case Regs.R0..=Regs.R7:
        return regs[reg][0]
    }
    return 0
}

@(private="file")
cpu_reg_set :: proc(reg: Regs, value: u32) {
    switch(reg) {
    case Regs.SPSR:
        mode := CPSR.Mode
        if(mode == Modes.M_USER || mode == Modes.M_SYSTEM) {
            //Do nothing
        } else {
            if(u8(mode) >= 16) {
                regs[reg][u32(mode) - 16] = value
            }
        }
    case Regs.SP, Regs.LR:
        mode := CPSR.Mode
        if(mode == Modes.M_USER || mode == Modes.M_SYSTEM) {
            regs[reg][0] = value
        } else {
            if(u8(mode) >= 16) {
                regs[reg][u32(mode) - 16] = value
            }
        }
    case Regs.PC:
        if(CPSR.Thumb) {
            PC = value & 0xFFFFFFFE
            refetch = true
        } else {
            PC = value
            refetch = true
        }
    case Regs.R8..=Regs.R12:
        mode := CPSR.Mode
        if(mode == Modes.M_FIQ) {
            regs[reg][u32(Modes.M_FIQ) - 16] = value
        } else {
            regs[reg][0] = value
        }
    case Regs.R0..=Regs.R7:
        regs[reg][0] = value
    }
}

@(private="file")
cpu_reg_raw :: proc(reg: Regs, mode: Modes) -> u32 {
    if(reg == Regs.PC) {
        return PC
    } else { 
        return regs[reg][u32(mode) - 16]
    }
}

@(private="file")
cpu_exec_irq :: proc() {
    //Handle interrupts
    if(utils_bit_get32(bus_get32(IO_IME), 0) && !CPSR.IRQ) { //IEs enabled
        if(bus_get32(IO_IE) & bus_get32(IO_IF) > 0) { //IE triggered
            regs[17][2] = u32(CPSR)     //Store cpsr in IRQ bank
            CPSR.Mode = Modes.M_IRQ
            if(CPSR.Thumb) {
                cpu_reg_set(Regs.LR, PC) //Store PC
            } else {
                cpu_reg_set(Regs.LR, PC - 4) //Store PC
            }
            PC = 0x18 //Go to interurupt handler
            cpu_refetch32()
            CPSR.Thumb = false
            CPSR.IRQ = true

            halt = false
            stop = false
        }
    }
}

reset :: proc(pc: u32) {
    halt = false
    stop = false
    regs = {}
    pipeline = {}
    PC = pc
    CPSR = Flags(0)
    refetch = false
    cpu_init()
}

step :: proc() -> u32 {
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

stop :: proc() {
    stop = true
}

halt :: proc() {
    halt = true
}

get_stop :: proc() -> bool {
    return stop
}

reg_get :: proc(reg: Regs) -> u32 {
    return cpu_reg_get(reg)
}

reg_raw :: proc(reg: Regs, mode: Modes) -> u32 {
    return regs[reg][u16(mode) - 16]
}

get_cpsr :: proc() -> Flags {
    return CPSR
}

get_instruction :: proc(idx: u32) -> u32 {
    if(CPSR.Thumb) {
        return u32(pipeline[idx] & 0xFFFF)
    } else {
        return pipeline[idx]
    }
}

init_no_bios :: proc() {
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
        if((opcode & 0xFFFFFD0) == 0x12FFF10) {
            retval = cpu_bx(opcode)
        } else if((opcode & 0xFFF0FF0) == 0x16F0F10) {
            retval = cpu_clz(opcode)
        } else if((opcode & 0xFB00FF0) == 0x1000090) {
            retval = cpu_swap(opcode)
        } else if((opcode & 0xF900FF0) == 0x1000050) {
            retval = cpu_qaddsub(opcode)
        } else if((opcode & 0xFC000F0) == 0x0000090) {
            retval = cpu_mul_mla(opcode)
        } else if((opcode & 0xF8000F0) == 0x0800090) {
            retval = cpu_mull_mlal(opcode)
        } else if((opcode & 0xF900090) == 0x1000080) {
            retval = cpu_mulh(opcode)
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
        if(cond == 0xF0000000) {
            retval = cpu_blx(opcode)
        } else {
            retval = cpu_b_bl(opcode)
        }
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
    op := (opcode >> 4) & 3
    pc := PC
    if(thumb) {
        CPSR.Thumb = true
        cpu_reg_set(Regs.PC, (value & 0xFFFFFFFE))
    } else {
        cpu_reg_set(Regs.PC, value)
    }
    if(op == 3) { //BLX
        cpu_reg_set(Regs.LR, pc + 4)
    }
    return 3
}

@(private="file")
cpu_mulh :: proc(opcode: u32) -> u32 {
    Op := opcode & 0x600000
    Rd := Regs((opcode & 0xF0000) >> 16)
    Rn := Regs((opcode & 0xF000) >> 12)
    Rs := Regs((opcode & 0xF00) >> 8)
    y := utils_bit_get32(opcode, 6)
    x := utils_bit_get32(opcode, 5)
    Rm := Regs(opcode & 0xF)
    HalfRm: i16
    if(x) {
        HalfRm = i16(cpu_reg_get(Rm) >> 16)
    } else {
        HalfRm = i16(cpu_reg_get(Rm) & 0xFFFF)
    }
    HalfRs: i16
    if(y) {
        HalfRs = i16(cpu_reg_get(Rs) >> 16)
    } else {
        HalfRs = i16(cpu_reg_get(Rs) & 0xFFFF)
    }
    PC += 4

    switch(Op) {
    case 0x000000:  //SMLAxy
        mul_res := u32(HalfRm) * u32(HalfRs)
        res, flag := intrinsics.overflow_add(i32(mul_res), i32(cpu_reg_get(Rn)))
        cpu_reg_set(Rd, u32(res))
        CPSR.Q = flag
    case 0x200000:
        if(x) {     //SMULWy
            res := u32(i32(cpu_reg_get(Rm)) * i32(HalfRs) >> 16)
            cpu_reg_set(Rd, res)
        } else {    //SMLAW
            mul_res := i32(cpu_reg_get(Rm)) * i32(HalfRs)
            res, flag := intrinsics.overflow_add(mul_res >> 16, i32(cpu_reg_get(Rn)))
            cpu_reg_set(Rd, u32(res))
            CPSR.Q = flag
        }
    case 0x400000:  //SMLALxy
        RdHiLo := (i64(cpu_reg_get(Rd)) << 32) | i64(cpu_reg_get(Rn))
        RdHiLo += i64(HalfRm) * i64(HalfRs)
        cpu_reg_set(Rd, u32(RdHiLo >> 32))
        cpu_reg_set(Rn, u32(RdHiLo))
    case 0x600000:  //SMULxy
        cpu_reg_set(Rd, u32(HalfRm) * u32(HalfRs))
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
        case 0x40:
            fmt.println("LDRD")
        case 0x60:
            fmt.println("STRD")
        }
    }
    return cycles
}

@(private="file")
cpu_mrc_mcr :: proc(opcode: u32) -> u32 {
    Op := utils_bit_get32(opcode, 20)
    CRn := (opcode & 0xF0000) >> 16
    Rd := Regs((opcode & 0xF000) >> 12)
    Pn := (opcode & 0xF00) >> 8
    CP := (opcode & 0xE0) >> 5
    CRm := opcode & 0xF
    PC += 4
    if(Pn == 15) {
        if(Op) {
            cpu_reg_set(Rd, cp15_read(CRn, CRm, CP))
        } else {
            cp15_write(CRn, CRm, CP, cpu_reg_get(Rd))
        }
        
    }
    return 3
}

@(private="file")
cpu_clz :: proc(opcode: u32) -> u32 {
    Rd := Regs((opcode & 0xF000) >> 12)
    Rm := Regs(opcode & 0xF)

    count := intrinsics.count_leading_zeros(cpu_reg_get(Rm))
    cpu_reg_set(Rd, count)
    return 1
}

@(private="file")
cpu_qaddsub :: proc(opcode: u32) -> u32 {
    Rn := Regs((opcode & 0xF0000) >> 16)
    Rd := Regs((opcode & 0xF000) >> 12)
    Rm := Regs(opcode & 0xF)
    op := (opcode >> 20) & 0xF
    a := i64(i32(cpu_reg_get(Rn)))
    b := i64(i32(cpu_reg_get(Rm)))

    qflag := CPSR.Q
    PC += 4

    if(op == 0x4 || op == 0x6) {
        doubled := a * 2
        if(doubled > i64(0x7FFFFFFF)) {
            a = i64(0x7FFFFFFF)
            qflag = true
        } else if(doubled < i64(-2147483648)) {
            a = i64(-2147483648)
            qflag = true
        } else {
            a = doubled
        }
    }

    sum: i64
    if(op == 0x2 || op == 0x6) {
        sum = b - a
    } else {
        sum = b + a
    }

    if(sum > i64(0x7FFFFFFF)) {
        cpu_reg_set(Rd, u32(0x7FFFFFFF))
        qflag = true
    } else if(sum < i64(-2147483648)) {
        cpu_reg_set(Rd, u32(0x80000000))
        qflag = true
    } else {
        cpu_reg_set(Rd, u32(i32(sum)))
    }
    CPSR.Q = qflag
    return 1
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
            if(Rd == Regs.PC) {
                CPSR.Thumb = bool(data & 1)
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
            if(i == Regs.PC) {
                CPSR.Thumb = bool(data & 1)
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
cpu_mul_mla :: proc(opcode: u32) -> u32 {
    //TODO: Calculate proper timings
    A := utils_bit_get32(opcode, 21)
    S := utils_bit_get32(opcode, 20)
    Rd := Regs((opcode & 0xF0000) >> 16)
    Rn := Regs((opcode & 0xF000) >> 12)
    Rs := Regs((opcode & 0xF00) >> 8)
    Rm := Regs(opcode & 0xF)
    res: u32
    PC += 4

    if(A) { //MLA
        res = cpu_reg_get(Rm) * cpu_reg_get(Rs) + cpu_reg_get(Rn)
        cpu_reg_set(Rd, res)
    } else { //MUL
        res = cpu_reg_get(Rm) * cpu_reg_get(Rs)
        cpu_reg_set(Rd, res)
    }
    if(S) {
        CPSR.Z = (res == 0)
        CPSR.N = bool(res >> 31)
        //C not affected
        //V not affected
    }
    return 2
}

@(private="file")
cpu_mull_mlal :: proc(opcode: u32) -> u32 {
    //TODO: Calculate proper timings
    Op := opcode & 0x600000
    S := utils_bit_get32(opcode, 20)
    RdHi := Regs((opcode & 0xF0000) >> 16)
    RdLo := Regs((opcode & 0xF000) >> 12)
    Rs := Regs((opcode & 0xF00) >> 8)
    Rm := Regs(opcode & 0xF)
    PC += 4

    switch(Op) {
    case 0x000000: //UMULL
        res := u64(cpu_reg_get(Rm)) * u64(cpu_reg_get(Rs))
        cpu_reg_set(RdLo, u32(res))
        cpu_reg_set(RdHi, u32(res >> 32))
        if(S) {
            CPSR.Z = res == 0
            CPSR.N = utils_bit_get64(res, 63)
            //C not affected
            //V not affected
        }
        break
    case 0x200000: //UMLAL
        hi_reg := u64(cpu_reg_get(RdHi))
        add := u64(cpu_reg_get(RdLo)) + (hi_reg << 32)
        res := u64(cpu_reg_get(Rm)) * u64(cpu_reg_get(Rs)) + add
        cpu_reg_set(RdLo, u32(res))
        cpu_reg_set(RdHi, u32(res >> 32))
        if(S) {
            CPSR.Z = res == 0
            CPSR.N = utils_bit_get64(res, 63)
            //C not affected
            //V not affected
        }
        break
    case 0x400000: //SMULL
        a := i32(cpu_reg_get(Rm))
        b := i32(cpu_reg_get(Rs))
        res2 := i64(a) * i64(b)
        cpu_reg_set(RdLo, u32(res2))
        cpu_reg_set(RdHi, u32(res2 >> 32))
        if(S) {
            CPSR.Z = res2 == 0
            CPSR.N = utils_bit_get64(u64(res2), 63)
            //C not affected
            //V not affected
        }
        break
    case 0x600000: //SMLAL
        a := i32(cpu_reg_get(Rm))
        b := i32(cpu_reg_get(Rs))
        hi_reg := i64(cpu_reg_get(RdHi))
        add := i64(cpu_reg_get(RdLo)) + (hi_reg << 32)
        res2 := i64(a) * i64(b) + add
        cpu_reg_set(RdLo, u32(res2))
        cpu_reg_set(RdHi, u32(res2 >> 32))
        if(S) {
            CPSR.Z = res2 == 0
            CPSR.N = utils_bit_get64(u64(res2), 63)
            //C not affected
            //V not affected
        }
        break
    }
    return 3
}

@(private="file")
cpu_swap :: proc(opcode: u32) -> u32 {
    B := utils_bit_get32(opcode, 22)
    Rn := Regs((opcode & 0xF0000) >> 16)
    Rd := Regs((opcode & 0xF000) >> 12)
    Rm := Regs(opcode & 0xF)
    PC += 4
    Rm_val := cpu_reg_get(Rm)
    address := cpu_reg_get(Rn)

    if(B) {
        data := bus_read8(address)
        bus_write8(address, u8(Rm_val))
        cpu_reg_set(Rd, u32(data))
    } else {
        data := bus_read32(address)
        data = cpu_ror32(data, (address & 0x3) * 8)
        bus_write32(address, Rm_val)
        cpu_reg_set(Rd, data)
    }
    return 3
}

@(private="file")
cpu_arm_alu :: proc(opcode: u32, I: bool) -> u32 {
    op := opcode & 0x1E00000
    S := utils_bit_get32(opcode, 20)
    R := utils_bit_get32(opcode, 4)
    Rn := Regs((opcode & 0xF0000) >> 16)
    Rd := Regs((opcode & 0xF000) >> 12)
    res :u32= 0
    Op2: u32
    Rn_reg := cpu_reg_get(Rn)
    logic_carry := CPSR.C
    carry: bool

    if(I) {
        Op2 = opcode & 0xFF
        Is := u8((opcode & 0xF00) >> 8)
        if(Is != 0) {
            logic_carry = utils_bit_get32(Op2, (Is * 2) - 1)
            Op2 = cpu_ror32(Op2, u32(Is * 2))
        }
    } else {
        Op2 = cpu_reg_shift(opcode, &logic_carry)
        if(R && Rn == Regs.PC) {
            Rn_reg += 4
        }
    }
    PC += 4

    switch(op) {
    case 0x0000000: //AND
        res = Rn_reg & Op2
        if(S) {
            CPSR.C = logic_carry
            //V not affected
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x0200000: //EOR
        res = Rn_reg ~ Op2
        if(S) {
            CPSR.C = logic_carry
            //V not affected
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x0400000: //SUB
        res = Rn_reg - Op2
        if(S) {
            CPSR.C = Rn_reg >= Op2
            CPSR.V = bool(((Rn_reg ~ Op2) & (Rn_reg ~ res)) >> 31)
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x0600000: //RSB
        res = Op2 - Rn_reg
        if(S) {
            CPSR.C = Op2 >= Rn_reg
            CPSR.V = bool(((Rn_reg ~ Op2) & (Op2 ~ res)) >> 31)
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x0800000: //ADD
        res, carry = intrinsics.overflow_add(Rn_reg, Op2)
        if(S) {
            CPSR.C = carry
            CPSR.V = bool((~(Rn_reg ~ Op2) & (Op2 ~ res)) >> 31)
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x0A00000: //ADC
        res = Rn_reg + Op2 + u32(CPSR.C)
        if(S) {
            CPSR.C = bool(u64(u64(Rn_reg) + u64(Op2) + u64(CPSR.C)) & 0x100000000)
            CPSR.V = bool((~(Rn_reg ~ Op2) & (Op2 ~ res)) >> 31)
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x0C00000: //SBC
        res = Rn_reg - Op2 + u32(CPSR.C) - 1
        if(S) {
            CPSR.C = (Rn_reg >= Op2) & ((Rn_reg - Op2) >= u32(!CPSR.C))
            CPSR.V = bool(((Rn_reg ~ Op2) & (Rn_reg ~ res)) >> 31)
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x0E00000: //RSC
        carry := 1 - u32(CPSR.C)
        res = Op2 - Rn_reg - carry
        sres := i64(i32(Op2)) - i64(i32(Rn_reg)) - i64(i32(carry))
        if(S) {
            CPSR.C = (Op2 >= Rn_reg) & ((Op2 - Rn_reg) >= u32(carry))
            CPSR.V = i64(i32(res)) != sres
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x1000000:
        if(S) { //TST
            res = Rn_reg & Op2
            if(S) {
                CPSR.C = logic_carry
                //V not affected
                cpu_setZNArmAlu(Rd, res)
            }
        } else { //MRS CPSR
            cpu_msr_mrs(opcode, u32(Rd))
        }
        break
    case 0x1200000:
        if(S) { //TEQ
            res = Rn_reg ~ Op2
            if(S) {
                CPSR.C = logic_carry
                //V not affected
                cpu_setZNArmAlu(Rd, res)
            }
        } else { //MSR CPSR
            cpu_msr_mrs(opcode, Op2)
        }
        break
    case 0x1400000:
    {
        if(S) { //CMP
            res = Rn_reg - Op2
            if(S) {
                CPSR.C = Rn_reg >= Op2
                CPSR.V = bool(((Rn_reg ~ Op2) & (Rn_reg ~ res)) >> 31)
                cpu_setZNArmAlu(Rd, res)
            }
        } else { //MRS SPSR
            cpu_msr_mrs(opcode, u32(Rd))
        }
        break
    }
    case 0x1600000:
        if(S) { //CMN
            res, carry = intrinsics.overflow_add(Rn_reg, Op2)
            if(S) {
                CPSR.C = carry
                CPSR.V = bool((~(Rn_reg ~ Op2) & (Op2 ~ res)) >> 31)
                cpu_setZNArmAlu(Rd, res)
            }
        } else { //MSR SPSR
            cpu_msr_mrs(opcode, Op2)
        }
        break
    case 0x1800000: //ORR
        res = Rn_reg | Op2
        if(S) {
            CPSR.C = logic_carry
            //V not affected
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x1A00000: //MOV
        res = Op2
        if(S) {
            CPSR.C = logic_carry
            //V not affected
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x1C00000: //BIC
        res = Rn_reg & ~Op2
        if(S) {
            CPSR.C = logic_carry
            //V not affected
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x1E00000: //MVN
        res = ~Op2
        if(S) {
            CPSR.C = logic_carry
            //V not affected
            cpu_setZNArmAlu(Rd, res)
        }
        cpu_reg_set(Rd, res)
        break
    }
    p := u32(Rd == Regs.PC && (op < 0x1000000 || op > 0x1600000))
    r := u32(!I && R)
    return (1 + p) + r + p
}

@(private="file")
cpu_msr_mrs :: proc(opcode: u32, op2: u32) {
    spsr := utils_bit_get32(opcode, 22)
    reg := spsr ? cpu_reg_get(Regs.SPSR) : u32(CPSR)
    msr := utils_bit_get32(opcode, 21)

    if(msr) {
        mask: u32
        if(utils_bit_get32(opcode, 19)) {
            mask |= 0xFF000000
        }
        if(utils_bit_get32(opcode, 18) && CPSR.Mode != Modes.M_USER) {
            mask |= 0x00FF0000
        }
        if(utils_bit_get32(opcode, 17) && CPSR.Mode != Modes.M_USER) {
            mask |= 0x0000FF00
        }
        if(utils_bit_get32(opcode, 16) && CPSR.Mode != Modes.M_USER) {
            mask |= 0x000000FF
        }
        if(spsr) {
            reg &= ~mask
            reg |= (op2 & mask)
            cpu_reg_set(Regs.SPSR, reg)
        } else {
            op2 := op2
            if((mask & 0xFF) > 0) {
                op2 |= 0x10
            }
            reg &= ~mask
            reg |= (op2 & mask)
            CPSR = Flags(reg)
        }
    } else {
        op2 := Regs(op2)
        if(op2 == Regs.PC) {
            PC = reg + 4
        } else {
            cpu_reg_set(op2, reg)
        }
    }
}

@(private="file")
cpu_b_bl :: proc(opcode: u32) -> u32 {
    offset := (opcode & 0xFFFFFF) << 2
    offset = utils_sign_extend32(offset, 26)
    L := utils_bit_get32(opcode, 24)

    if(L) { //BL
        cpu_reg_set(Regs.LR, PC - 4)
        cpu_reg_set(Regs.PC, u32(i32(PC) + i32(offset)))
    } else { //B
        cpu_reg_set(Regs.PC, u32(i32(PC) + i32(offset)))
    }
    return 3
}

@(private="file")
cpu_blx :: proc(opcode: u32) -> u32 {
    offset := (opcode & 0xFFFFFF) << 2
    offset = utils_sign_extend32(offset, 26)
    H := u32(utils_bit_get32(opcode, 24))

    cpu_reg_set(Regs.LR, PC - 4)
    cpu_reg_set(Regs.PC, u32(i32(PC) + i32(offset)) + H * 2)
    CPSR.Thumb = true
    return 3
}

@(private="file")
cpu_unknown_irq :: proc() {
    cpsr := CPSR
    CPSR.Mode = Modes.M_UNDEFINED
    cpu_reg_set(Regs.LR, PC - 4)
    cpu_reg_set(Regs.PC, 0x04)
    cpu_reg_set(Regs.SPSR, u32(cpsr))
    CPSR.Thumb = false  //ARM mode
    CPSR.IRQ = true     //Disable interrupts
}

@(private="file")
cpu_ldc_stc :: proc(opcode: u32) -> u32 {
    cpu_unknown_irq()
    return 1
}

@(private="file")
cpu_cdp :: proc(opcode: u32) -> u32 {
    cpu_unknown_irq()
    return 3
}

@(private="file")
cpu_swi :: proc() -> u32 {
    regs[17][3] = u32(CPSR)
    CPSR.Mode = Modes.M_SUPERVISOR
    CPSR.Thumb = false  //ARM mode
    CPSR.IRQ = true     //Disable interrupts
    cpu_reg_set(Regs.LR, PC - 4)
    cpu_reg_set(Regs.PC, 0x08)
    return 3
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
    case 0xE800,
         0xF000,
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
        pc := PC
        CPSR.Thumb = thumb
        if(thumb) {
            cpu_reg_set(Regs.PC, (value & 0xFFFFFFFE))
        } else {
            cpu_reg_set(Regs.PC, value)
        }
        if(bool(H1)) { //BLX
            cpu_reg_set(Regs.LR, pc + 4)
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
        if(!utils_bit_get16(opcode, 12)) {
            CPSR.Thumb = false
        }
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
            CPSR.Thumb = bool(pc & 1)
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

@(private="file")
cpu_shift :: proc(opcode: u16) -> u32 {
    op := opcode & 0x1800
    imm := u32((opcode & 0x07C0) >> 6)
    Rs := cpu_reg_get(Regs((opcode & 0x0038) >> 3))
    Rd := Regs(opcode & 0x0007)
    res :u32= 0
    carry := CPSR.C

    switch(op) {
    case 0x0000: //LSL
        res = cpu_lsl(imm, Rs, &carry)
        cpu_reg_set(Rd, res)
        break
    case 0x0800: //LSR
        if(imm == 0) {
            res = cpu_lsr(32, Rs, &carry)
        } else {
            res = cpu_lsr(imm, Rs, &carry)
        }
        cpu_reg_set(Rd, res)
        break
    case 0x1000: //ASR
        if(imm == 0) {
            res = cpu_asr(32, Rs, &carry)
        } else {
            res = cpu_asr(imm, Rs, &carry)
        }
        cpu_reg_set(Rd, res)
        break
    }
    CPSR.Z = res == 0
    CPSR.N = bool(res >> 31)
    CPSR.C = carry
    //No V
    return 1
}

@(private="file")
cpu_add_sub :: proc(opcode: u16) -> u32 {
    Op := (opcode & 0x0600) >> 9
    Rn := u32((opcode & 0x01C0) >> 6)
    RnReg := cpu_reg_get(Regs(Rn))
    Rs := Regs((opcode & 0x0038) >> 3)
    RsReg := cpu_reg_get(Rs)
    Rd := Regs(opcode & 0x0007)
    res: u32
    carry: bool

    switch(Op) {
    case 0: //ADD
        res, carry = intrinsics.overflow_add(RsReg, RnReg)
        cpu_reg_set(Rd, res)
        CPSR.C = carry
        CPSR.V = bool((~(RsReg ~ RnReg) & (RnReg ~ res)) >> 31)
        break
    case 1: //SUB
        res = RsReg - RnReg
        cpu_reg_set(Rd, res)
        CPSR.C = RsReg >= RnReg
        CPSR.V = bool(((RsReg ~ RnReg) & (RsReg ~ res)) >> 31)
        break
    case 2: //ADD
        res, carry = intrinsics.overflow_add(RsReg, Rn)
        cpu_reg_set(Rd, res)
        CPSR.C = carry
        CPSR.V = bool((~(RsReg ~ Rn) & (Rn ~ res)) >> 31)
        break
    case 3: //SUB
        res = RsReg - Rn
        cpu_reg_set(Rd, res)
        CPSR.C = RsReg >= Rn
        CPSR.V = bool(((RsReg ~ Rn) & (RsReg ~ res)) >> 31)
        break
    }
    CPSR.Z = res == 0
    CPSR.N = bool(res >> 31)
    return 1
}

@(private="file")
cpu_mcas_imm :: proc(opcode: u16) -> u32 {
    op := opcode & 0x1800
    Rd := Regs((opcode & 0x0700) >> 8)
    RdReg := cpu_reg_get(Rd)
    nn := u32(opcode & 0x00FF)
    res: u32

    switch(op) {
    case 0x0000: //MOV
        res = nn
        cpu_reg_set(Rd, res)
        //C not affected
        //V not affected
        break
    case 0x0800: //CMP
        res = RdReg - nn
        CPSR.C = RdReg >= nn
        CPSR.V = bool(((RdReg ~ nn) & (RdReg ~ res)) >> 31)
        break
    case 0x1000: //ADD
        carry: bool
        res, carry = intrinsics.overflow_add(RdReg, nn)
        cpu_reg_set(Rd, res)
        CPSR.C = carry
        CPSR.V = bool((~(RdReg ~ nn) & (nn ~ res)) >> 31)
        break
    case 0x1800: //SUB
        res = RdReg - nn
        cpu_reg_set(Rd, res)
        CPSR.C = RdReg >= nn
        CPSR.V = bool(((RdReg ~ nn) & (RdReg ~ res)) >> 31)
        break
    }
    CPSR.Z = res == 0
    CPSR.N = bool(res >> 31)
    return 1
}

@(private="file")
cpu_alu :: proc(opcode: u16) -> u32 {
    Op := (opcode & 0x03C0) >> 6
    Rs := Regs((opcode & 0x0038) >> 3)
    RsReg := cpu_reg_get(Rs)
    Rd := Regs((opcode & 0x0007))
    RdReg := cpu_reg_get(Rd)
    res: u32
    carry := CPSR.C

    switch(Op) {
    case 0: //AND
        res = RdReg & RsReg
        cpu_reg_set(Rd, res)
        break
    case 1: //EOR
        res = RdReg ~ RsReg
        cpu_reg_set(Rd, res)
        break
    case 2: //LSL
        res = cpu_lsl(RsReg & 0xFF, RdReg, &carry)
        cpu_reg_set(Rd, res)
        CPSR.C = carry
        //V not affected
        break
    case 3: //LSR
        if(RsReg == 0) {
            res = cpu_lsl(RsReg & 0xFF, RdReg, &carry)
        } else {
            res = cpu_lsr(RsReg & 0xFF, RdReg, &carry)
        }
        cpu_reg_set(Rd, res)
        CPSR.C = carry
        //V not affected
        break
    case 4: //ASR
        if(RsReg == 0) {
            res = cpu_lsl(RsReg & 0xFF, RdReg, &carry)
        } else {
            res = cpu_asr(RsReg & 0xFF, RdReg, &carry)
        }
        cpu_reg_set(Rd, res)
        CPSR.C = carry
        //V not affected
        break
    case 5: //ADC
        res = RdReg + RsReg + u32(CPSR.C)
        cpu_reg_set(Rd, res)
        CPSR.C = ((0xFFFFFFFF - RdReg) < RsReg) | ((0xFFFFFFFF-(RdReg + RsReg)) < u32(CPSR.C))
        CPSR.V = bool((~(RdReg ~ RsReg) & (RsReg ~ res)) >> 31)
        break
    case 6: //SBC
        res = RdReg - RsReg - u32(!CPSR.C)
        cpu_reg_set(Rd, res)
        CPSR.C = (RdReg >= RsReg) & ((RdReg - RsReg) >= u32(!CPSR.C))
        CPSR.V = bool(((RdReg ~ RsReg) & (RdReg ~ res)) >> 31)
        break
    case 7: //ROR
        if(RsReg == 0) {
            res = cpu_lsl(RsReg & 0xFF, RdReg, &carry)
        } else {
            res = cpu_ror(RsReg & 0xFF, RdReg, &carry)
        }
        cpu_reg_set(Rd, res)
        CPSR.C = carry
        //V not affected
        break
    case 8: //TST
        res = RdReg & RsReg
        break
    case 9: //NEG
        res = -RsReg
        cpu_reg_set(Rd, res)
        CPSR.C = 0 >= RsReg
        CPSR.V = bool(((0 ~ RsReg) & (0 ~ res)) >> 31)
        break
    case 10: //CMP
        res = RdReg - RsReg
        CPSR.C = RdReg >= RsReg
        CPSR.V = bool(((RdReg ~ RsReg) & (RdReg ~ res)) >> 31)
        break
    case 11: //CMN
        res = RdReg + RsReg
        CPSR.C = (0xFFFFFFFF - RdReg) < RsReg
        CPSR.V = bool((~(RdReg ~ RsReg) & (RsReg ~ res)) >> 31)
        break
    case 12: //ORR
        res = RdReg | RsReg
        cpu_reg_set(Rd, res)
        break
    case 13: //MUL
        res = RdReg * RsReg
        cpu_reg_set(Rd, res)
        break
    case 14: //BIC
        res = RdReg & ~RsReg
        cpu_reg_set(Rd, res)
        break
    case 15: //MVN
        res = ~RsReg
        cpu_reg_set(Rd, res)
        break
    }
    CPSR.Z = res == 0
    CPSR.N = bool(res >> 31)
    return 1
}

@(private="file")
cpu_ld_pc :: proc(opcode: u16) -> u32 {
    Rd := Regs((opcode & 0x0700) >> 8)
    imm := u32((opcode & 0x00FF) << 2)
    pc := (PC - 2) & 0xFFFFFFFC
    cpu_reg_set(Rd, bus_read32(pc + imm))
    return 3
}

@(private="file")
cpu_ls_ext :: proc(opcode: u16) -> u32 {
    Op := opcode & 0x0C00
    Ro := Regs((opcode & 0x01C0) >> 6)
    Rb := Regs((opcode & 0x0038) >> 3)
    Rd := Regs(opcode & 0x0007)
    cycles :u32= 3
    address := cpu_reg_get(Rb) + cpu_reg_get(Ro)

    switch(Op) {
    case 0x000: //STRH
        bus_write16(address, u16(cpu_reg_get(Rd)))
        cycles = 2
        break
    case 0x400: //LDRSB
        value := bus_read8(address)
        cpu_reg_set(Rd, u32(i32(i8(value))))
        break
    case 0x800: //LDRH
        shift := address & 0x1
        data := u32(bus_read16(address))
        if(shift == 1) {
            data = cpu_ror32(data, 8)
        }
        cpu_reg_set(Rd, data)
        break
    case 0xC00: //LDRSH
        shift := address & 0x1
        value := i16(bus_read16(address))
        if(shift == 1) {
            value = i16(cpu_ror32(u32(value), 8))
        }
        cpu_reg_set(Rd, u32(i32(value)))
        break
    }
    return cycles
}

@(private="file")
cpu_ls_reg :: proc(opcode: u16) -> u32 {
    Op := opcode & 0x0C00
    Ro := Regs((opcode & 0x01C0) >> 6)
    Rb := Regs((opcode & 0x0038) >> 3)
    Rd := Regs((opcode & 0x0007))
    cycles :u32= 3
    address := cpu_reg_get(Rb) + cpu_reg_get(Ro)

    switch(Op) {
    case 0x000: //STR
        bus_write32(address, cpu_reg_get(Rd))
        cycles = 2
        break
    case 0x400: //STRB
        bus_write8(address, u8(cpu_reg_get(Rd)))
        cycles = 2
        break
    case 0x800: //LDR
        shift := address & 0x3
        data := bus_read32(address)
        data = cpu_ror32(data, shift * 8)
        cpu_reg_set(Rd, data)
        break
    case 0xC00: //LDRB
        cpu_reg_set(Rd, u32(bus_read8(address)))
        break
    }
    return cycles
}

@(private="file")
cpu_ls_imm :: proc(opcode: u16) -> u32 {
    Op := opcode & 0x1800
    imm := u32((opcode & 0x07C0) >> 6)
    Rb := Regs((opcode & 0x0038) >> 3)
    Rd := Regs((opcode & 0x0007))
    cycles :u32= 3

    switch(Op) {
    case 0x0000: //STR
        bus_write32(cpu_reg_get(Rb) + (imm << 2), cpu_reg_get(Rd))
        cycles = 2
        break
    case 0x0800: //LDR
        address := cpu_reg_get(Rb) + (imm << 2)
        shift := address & 0x3
        data := bus_read32(address)
        data = cpu_ror32(data, shift * 8)
        cpu_reg_set(Rd, data)
        break
    case 0x1000: //STRB
        bus_write8(cpu_reg_get(Rb) + imm, u8(cpu_reg_get(Rd)))
        cycles = 2
        break
    case 0x1800: //LDRB
        cpu_reg_set(Rd, u32(bus_read8(cpu_reg_get(Rb) + imm)))
        break
    }
    return cycles
}

@(private="file")
cpu_ls_hw :: proc(opcode: u16) -> u32 {
    L := utils_bit_get16(opcode, 11)
    imm := u32(((opcode & 0x07C0) >> 6) << 1)
    Rb := Regs((opcode & 0x0038) >> 3)
    Rd := Regs(opcode & 0x0007)
    cycles :u32= 3

    if(L) { //LDRH
        address := cpu_reg_get(Rb) + imm
        shift := address & 0x1
        data := u32(bus_read16(address))
        if(shift == 1) {
            data = cpu_ror32(data, 8)
        }
        cpu_reg_set(Rd, data)
    } else { //STRH
        bus_write16(cpu_reg_get(Rb) + imm, u16(cpu_reg_get(Rd)))
        cycles = 2
    }
    return cycles
}

@(private="file")
cpu_ls_sp :: proc(opcode: u16) -> u32 {
    L := utils_bit_get16(opcode, 11)
    Rd := Regs((opcode & 0x0700) >> 8)
    imm := u32((opcode & 0x00FF) << 2)
    cycles :u32= 3

    if(L) { //LDR
        address := cpu_reg_get(Regs.SP) + imm
        shift := address & 0x3
        data := bus_read32(address)
        data = cpu_ror32(data, shift * 8)
        cpu_reg_set(Rd, data)
    } else { //STR
        bus_write32(cpu_reg_get(Regs.SP) + imm, cpu_reg_get(Rd))
        cycles = 2
    }
    return cycles
}

@(private="file")
cpu_ld :: proc(opcode: u16) -> u32 {
    sp := utils_bit_get16(opcode, 11)
    Rd := Regs((opcode & 0x0700) >> 8)
    imm := u32((opcode & 0x00FF) << 2)
    data: u32

    if(sp) { //SP
        data = cpu_reg_get(Regs.SP) + imm
    } else {   //PC
        bit1 := utils_bit_get32(PC, 1)
        pc := PC & 0xFFFFFFFD
        if(!bit1) {
            data = pc - 4 + imm
        } else {
            data = pc + imm
        }
    }
    cpu_reg_set(Rd, data)
    return 1
}

@(private="file")
cpu_sp_ofs :: proc(opcode: u16) -> u32 {
    S := utils_bit_get16(opcode, 7)
    offset := i32((opcode & 0x007F) << 2)
    if(S) {
        offset = -offset
    }
    cpu_reg_set(Regs.SP, u32(i32(cpu_reg_get(Regs.SP)) + offset))
    return 1
}

@(private="file")
cpu_ls_mp :: proc(opcode: u16) -> u32 {
    L := utils_bit_get16(opcode, 11)
    Rb := Regs((opcode & 0x0700) >> 8)
    rlist := u32(opcode & 0x00FF)
    oaddr := cpu_reg_get(Rb)
    addr := oaddr
    cycles :u32= 2

    for i :u8= 0; i < 8; i += 1 {
        i := Regs(i)
        if(utils_bit_get32(rlist, u8(i))) {
            if(L) { //LDMIA
                cpu_reg_set(i, bus_read32(addr))
            } else { //STMIA
                value := cpu_reg_get(i)
                bus_write32(addr, value)
                if(utils_bit_get32(rlist, u8(Rb))) {
                    cpu_reg_set(Rb, oaddr + (intrinsics.count_ones(rlist) * 4))
                }
            }
            addr += 4
            cycles += 1
        }
    }
    if(rlist == 0) {
        if(L) {
            PC = bus_read32(addr)
            refetch = true
        } else {
            bus_write32(addr, PC)
        }
        addr += 0x40
    }
    if(!L || !utils_bit_get32(rlist, u8(Rb))) {
        cpu_reg_set(Rb, addr)
    }
    return cycles
}

@(private="file")
cpu_b_cond :: proc(opcode: u16) -> u32{
    Op := (opcode & 0x0F00) >> 8
    offset := u32((opcode & 0x00FF) << 1)
    do_jump := false

    switch(Op) {
    case 0: //BEQ
        do_jump = CPSR.Z
        break
    case 1: //BNE
        do_jump = !CPSR.Z
        break
    case 2: //BCS
        do_jump = CPSR.C
        break
    case 3: //BCC
        do_jump = !CPSR.C
        break
    case 4: //BMI
        do_jump = CPSR.N
        break
    case 5: //BPL
        do_jump = !CPSR.N
        break
    case 6: //BVS
        do_jump = CPSR.V
        break
    case 7: //BVC
        do_jump = !CPSR.V
        break
    case 8: //BHI
        do_jump = CPSR.C && !CPSR.Z
        break
    case 9: //BLS
        do_jump = !CPSR.C || CPSR.Z
        break
    case 10: //BGE
        do_jump = (CPSR.N && CPSR.V) || (!CPSR.N && !CPSR.V)
        break
    case 11: //BLT
        do_jump = (CPSR.N && !CPSR.V) || (!CPSR.N && CPSR.V)
        break
    case 12: //BGT
        do_jump = !CPSR.Z && ((CPSR.N && CPSR.V) || (!CPSR.N && !CPSR.V))
        break
    case 13: //BLE
        do_jump = CPSR.Z || ((CPSR.N && !CPSR.V) || (!CPSR.N && CPSR.V))
        break
    case 14:
        do_jump = true
    case 15: //SWI
        return cpu_swi()
    }
    if(do_jump) {
        offset = utils_sign_extend32(offset, 9)
        cpu_reg_set(Regs.PC, u32(i32(PC) + i32(offset) - 2))
    }
    return 3
}

@(private="file")
cpu_b_uncond :: proc(opcode: u16) -> u32 {
    offset := u32((opcode & 0x7FF) << 1)
    offset = utils_sign_extend32(offset, 12)
    cpu_reg_set(Regs.PC, u32(i32(PC) + i32(offset) - 2))
    return 3
}

@(private="file")
cpu_setZNArmAlu :: proc(Rd: Regs, res: u32) {
    if(Rd == Regs.PC) {
        mode := CPSR.Mode
        if(mode == Modes.M_USER || mode == Modes.M_SYSTEM) {
            CPSR.Z = res == 0
            CPSR.N = bool(res >> 31)
            return
        }
        CPSR = Flags(cpu_reg_get(Regs.SPSR))
    } else {
        CPSR.Z = res == 0
        CPSR.N = bool(res >> 31)
    }
}

@(private="file")
cpu_reg_shift :: proc(opcode: u32, logic_carry: ^bool) -> u32 {
    shift_type := opcode & 0x60
    shift_reg := utils_bit_get32(opcode, 4)
    Rm := Regs(opcode & 0xF)
    Rm_reg := cpu_reg_get(Rm)
    shift: u32
    res: u32

    if(shift_reg) {
        Rs := Regs((opcode & 0xF00) >> 8)
        shift = cpu_reg_get(Rs)
        shift &= 0xFF
        if(shift == 0) {
            shift_type = 0
        }
        if(Rm == Regs.PC) {
            Rm_reg += 4
        }
    } else {
        shift = (opcode & 0xF80) >> 7
    }

    switch(shift_type) {
    case 0x00: //LSL
        res = cpu_lsl(shift, Rm_reg, logic_carry)
        break
    case 0x20: //LSR
        res = cpu_lsr(shift, Rm_reg, logic_carry)
        break
    case 0x40: //ASR
        res = cpu_asr(shift, Rm_reg, logic_carry)
        break
    case 0x60: //ROR
        res = cpu_ror(shift, Rm_reg, logic_carry)
        break
    }
    return res
}

@(private="file")
cpu_lsl :: proc(shift: u32, value: u32, logic_carry: ^bool) -> u32 {
    res: u32

    if(shift == 0) {
        res = value
    } else {
        res = value << shift
        logic_carry^ = utils_bit_get32(value, u8(32 - shift))
    }
    return res
}

@(private="file")
cpu_lsr :: proc(shift: u32, value: u32, logic_carry: ^bool) -> u32 {
    res: u32

    if(shift == 0) {
        if(!CPSR.Thumb) {
            logic_carry^ = (value & 0x80000000) > 0
            res = 0
        } else {
            res = value
        }
    } else {
        res = value >> shift
        logic_carry^ = utils_bit_get32(value, u8(shift - 1))
    }
    return res
}

@(private="file")
cpu_asr :: proc(shift: u32, value: u32, logic_carry: ^bool) -> u32 {
    res: u32

    if(shift == 0) {
        if(!CPSR.Thumb) {
            logic_carry^ = (value & 0x80000000) > 0
            if(logic_carry^) {
                res = 0xFFFFFFFF
            } else {
                res = 0
            }
        } else {
            res = value
        }
    } else if(shift < 32) {
        logic_carry^ = utils_bit_get32(value, u8(shift - 1))
        res = u32(i32(value) >> shift)
    } else {
        logic_carry^ = (value & (1<<31)) > 0
        res = u32((i32(value)) >> 31)
    }
    return res
}

@(private="file")
cpu_ror :: proc(shift: u32, value: u32, logic_carry: ^bool) -> u32 {
    res: u32

    if(shift == 0) {
        if(!CPSR.Thumb) {
            res = (value >> 1) | (u32(CPSR.C) << 31)
            logic_carry^ = bool(value & 0x1)
        } else {
            res = value
        }
    } else {
        shift2 := shift % 32
        if(shift2 == 0) {
            res = value
            logic_carry^ = (value & 0x80000000) > 0
        } else {
            res = cpu_ror32(value, shift2)
            logic_carry^ = utils_bit_get32(value, u8(shift2 - 1))
        }
        
    }
    return res
}

@(private="file")
cpu_ror32 :: proc(number: u32, count: u32) -> u32 {
    lower := number >> count
    upper := number << (32 - count)
    return lower | upper
}

@(private="file")
utils_bit_get16 :: proc(value: u16, bit: u8) -> bool {
    return bool((value >> bit) & 1)
}

@(private="file")
utils_bit_get32 :: proc(value: u32, bit: u8) -> bool {
    return bool((value >> bit) & 1)
}

@(private="file")
utils_bit_get64 :: proc(value: u64, bit: u8) -> bool {
    return bool((value >> bit) & 1)
}

@(private="file")
utils_bit_clear32 :: proc(value: u32, bit: u8) -> u32 {
    return value & ~(1 << bit)
}

@(private="file")
utils_sign_extend32 :: proc(data: u32, bits: u32) -> u32 {
    m := u32(1) << (bits - 1)
    return (data ~ m) - m
}
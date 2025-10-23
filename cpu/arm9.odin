package cpu

import "core:fmt"
import "base:intrinsics"

IO_IME :u32: 0x4000208
IO_IE :u32: 0x4000210
IO_IF :u32: 0x4000214

cp15_read: proc(CRn: u32, CRm: u32, CP: u32) -> u32
cp15_write: proc(CRn: u32, CRm: u32, CP: u32, value: u32)

arm9_reset :: proc(pc: u32) {
    halt = false
    stop = false
    regs = {}
    pipeline = {}
    PC = pc
    CPSR = Flags(0)
    refetch = false
    cpu_init()
}

arm9_step :: proc() -> u32 {
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

arm9_stop :: proc() {
    stop = true
}

arm9_halt :: proc() {
    halt = true
}

arm9_get_stop :: proc() -> bool {
    return stop
}

arm9_reg_get :: proc(reg: Regs) -> u32 {
    return cpu_reg_get(reg)
}

arm9_reg_raw :: proc(reg: Regs, mode: Modes) -> u32 {
    return regs[reg][u16(mode) - 16]
}

arm9_get_cpsr :: proc() -> Flags {
    return CPSR
}

arm9_get_instruction :: proc(idx: u32) -> u32 {
    if(CPSR.Thumb) {
        return u32(pipeline[idx] & 0xFFFF)
    } else {
        return pipeline[idx]
    }
}

arm9_init_no_bios :: proc() {
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
        } else if((opcode & 0xFFF0FF0) == 0x16F0F10) {
            retval = cpu_clz(opcode)
        //} else if ((opcode & 0xF900FF0) == 0x1000050) {
        //    retval = cpu_qaddsub(opcode)
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
    fmt.println("QADD/SUB")
    Rn := Regs((opcode & 0xF0000) >> 16)
    Rd := Regs((opcode & 0xF000) >> 12)
    Rm := Regs(opcode & 0xF)
    op := (opcode >> 20) & 0xF
    a := i64(i32(cpu_reg_get(Rn)))
    b := i64(i32(cpu_reg_get(Rm)))

    if(op == 0x2 || op == 0x6) {
        b = -b
    }
    qflag := CPSR.Q

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
    sum := a + b

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
            fmt.println("BLX!")
            CPSR.Thumb = false
        }
        return 3
    }
}
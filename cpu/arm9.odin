package cpu

import "core:fmt"

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
    case 0x1000000:
        if((opcode & 0xFFF0FF0) == 0x16F0F10) {
            retval = cpu_clz(opcode)
        } else {
            retval = cpu_qaddsub(opcode)
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
# The Sv39 shims (T6.1): the two privileged instructions the kernel's
# page tables need — the satp write and sfence.vma — each a leaf the
# boot stub calls with a table's physical address, and from T6.2 the
# context switch and the trampoline. The division of labor is the
# gate's: Emo builds and reads the tables (sv39.emo, raw memory through
# peek/poke); the CSR write and the fence, which no Emo spelling
# reaches, are the shim's.

    .section .text

# emo_os_satp_switch: a0 = the root table's physical address. The
# fence before the write lets every store into the table retire before
# the hardware may walk it; the one after drops whatever the old table
# left in the TLB. The answer is the satp written — MODE 8 (Sv39),
# ASID 0, the root's PPN.
    .globl emo_os_satp_switch
emo_os_satp_switch:
    srli a0, a0, 12
    li t0, 1
    slli t0, t0, 63
    or a0, a0, t0
    sfence.vma zero, zero
    csrw satp, a0
    sfence.vma zero, zero
    ret

# emo_os_sfence: the whole TLB, every address space — the fence a
# mapping change needs before the hardware may see it. The kernel's
# table never changes after boot in T6.1; the per-process tables (T6.2)
# and the unmap at a death are the callers.
    .globl emo_os_sfence
emo_os_sfence:
    sfence.vma zero, zero
    ret

# The Sv39 page: the kernel's root table (its kernel address, written
# by sv39.emo's boot) and the satp the stub read back from the switch,
# at the fixed address the kernel's linker script gives the section.
# The program's own check reads both through peek/poke; named here so
# the forensics can read them.
    .section .emo_sv39, "aw", @nobits
    .globl emo_os_sv39_root
emo_os_sv39_root:
    .zero 8
    .globl emo_os_sv39_satp
emo_os_sv39_satp:
    .zero 8

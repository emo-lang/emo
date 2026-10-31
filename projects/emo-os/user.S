# The user image rides in the kernel (T4.1): the ELF the user profile
# built, embedded verbatim. The boot stub parks its bounds in the
# handoff page at boot, and the kernel's own Emo loader (user.emo)
# parses and copies it — the kernel loads the user, it does not execute
# from the blob. The path is resolved by the assembler's include search
# (`-I` with this tree), so the build runs from wherever it wants: the
# recipe builds hello first, then the kernel beside it.
#
#   (cd hello && emo build main.emo --target riscv64 --profile user \
#        -o ../hello.elf)
#   emo build main.emo --target riscv64

    .section .rodata
    .globl emo_os_user_blob
emo_os_user_blob:
    .incbin "hello.elf"
    .globl emo_os_user_blob_end
emo_os_user_blob_end:

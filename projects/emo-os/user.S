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
#
# The disk ELFs (emo-desktop A11.1) ride beside it: the three apps'
# images, embedded the same way, their bounds parked at the handoff
# page's free tail. The first boot writes each onto the volume through
# the filesystem service when a probe says the file is missing — the
# machine installs its own apps — and every exec after loads the image
# from the disk.

    .section .rodata
    .globl emo_os_user_blob
emo_os_user_blob:
    .incbin "hello.elf"
    .globl emo_os_user_blob_end
emo_os_user_blob_end:

    .globl emo_os_user_blob_c
emo_os_user_blob_c:
    .incbin "counter.elf"
    .globl emo_os_user_blob_c_end
emo_os_user_blob_c_end:

    .globl emo_os_user_blob_f
emo_os_user_blob_f:
    .incbin "files.elf"
    .globl emo_os_user_blob_f_end
emo_os_user_blob_f_end:

    .globl emo_os_user_blob_e
emo_os_user_blob_e:
    .incbin "editor.elf"
    .globl emo_os_user_blob_e_end
emo_os_user_blob_e_end:


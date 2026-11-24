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
# page's free tail — and, since T8.21, the spinner's, the busy app the
# preemption proof execs. The first boot writes each onto the volume
# through the filesystem service when a probe says the file is missing
# — the machine installs its own apps — and every exec after loads the
# image from the disk.

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

    .globl emo_os_user_blob_s
emo_os_user_blob_s:
    .incbin "spin.elf"
    .globl emo_os_user_blob_s_end
emo_os_user_blob_s_end:

    .globl emo_os_user_blob_w
emo_os_user_blob_w:
    .incbin "wallpaper.rle"
    .globl emo_os_user_blob_w_end
emo_os_user_blob_w_end:

    # The C door's first image (EmoOS plan B, M0): a program built by
    # the cross C compiler, linked in the Emo user image's window and
    # installed on the volume like every other app. It proves the
    # toolchain contract before the libc work begins.
    .globl emo_os_user_blob_x
emo_os_user_blob_x:
    .incbin "chello.elf"
    .globl emo_os_user_blob_x_end
emo_os_user_blob_x_end:

    # The emosh boot shell (T3.2): the Emo shell's C build, installed
    # on the volume when the image carries it. An empty placeholder
    # leaves the length zero and the kernel skips the install.
    .globl emo_os_user_blob_m
emo_os_user_blob_m:
    .incbin "emosh.elf"
    .globl emo_os_user_blob_m_end
emo_os_user_blob_m_end:

    # dash (T4.1): the first real POSIX program, installed like the
    # apps and exec'd by the root's shell stage when present.
    .globl emo_os_user_blob_d
emo_os_user_blob_d:
    .incbin "dash.elf"
    .globl emo_os_user_blob_d_end
emo_os_user_blob_d_end:

    # dash's acceptance script: the shell's own features over the T1
    # gate's fd surface.
    .globl emo_os_user_blob_t
emo_os_user_blob_t:
    .incbin "dash-test.sh"
    .globl emo_os_user_blob_t_end
emo_os_user_blob_t_end:

    # The first core-utilities corpus (T4.2): one applet binary, the
    # acceptance its own selftest.
    .globl emo_os_user_blob_u
emo_os_user_blob_u:
    .incbin "uutils.elf"
    .globl emo_os_user_blob_u_end
emo_os_user_blob_u_end:

    # TCC (T4.5): the self-hosted C compiler, its runtime helpers, the
    # guest link inputs (the TCC-facing crt and the sysroot's libc),
    # and the acceptance source. An empty placeholder leaves the
    # length zero and the kernel skips the install.
    .globl emo_os_user_blob_cc
emo_os_user_blob_cc:
    .incbin "tcc.elf"
    .globl emo_os_user_blob_cc_end
emo_os_user_blob_cc_end:

    .globl emo_os_user_blob_cl
emo_os_user_blob_cl:
    .incbin "tcc-libtcc1.a"
    .globl emo_os_user_blob_cl_end
emo_os_user_blob_cl_end:

    .globl emo_os_user_blob_cr
emo_os_user_blob_cr:
    .incbin "tcc-crt0.o"
    .globl emo_os_user_blob_cr_end
emo_os_user_blob_cr_end:

    .globl emo_os_user_blob_ca
emo_os_user_blob_ca:
    .incbin "tcc-libc.a"
    .globl emo_os_user_blob_ca_end
emo_os_user_blob_ca_end:

    .globl emo_os_user_blob_ct
emo_os_user_blob_ct:
    .incbin "tcc-test.c"
    .globl emo_os_user_blob_ct_end
emo_os_user_blob_ct_end:


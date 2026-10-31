# A plain package source: assembled beside the program into the image,
# it contributes data the program reaches through raw memory. The boot
# stub hands the program this word's address (the pointer parked at
# 0x87000008).

    .section .data
    .globl extra_word
extra_word:
    .quad 4660

# Single-thread LED counter. LED_ADDR sits in Vortex's uncached IO window, so
# every store goes straight out of the memory port to the board's LED register.
    .section .text.init, "ax"
    .globl _start
_start:
    li   t0, 0xFF00
    li   t1, 0
1:
    addi t1, t1, 1
    srli t2, t1, 16
    sw   t2, 0(t0)
    j    1b

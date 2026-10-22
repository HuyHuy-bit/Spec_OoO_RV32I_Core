# Reset entry: the bench zero-fills RAM; registers are zeroed because the reference
# rejects reads of never-written registers (main's prologue saves callee-saved ones).
# main's return lands in a self-loop the runner uses as the terminal PC.
    .section .text.init
    .globl _start
_start:
    .irp reg, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li x\reg, 0
    .endr
    la sp, _stack_top
    call main
    .globl coremark_done
coremark_done:
    j coremark_done

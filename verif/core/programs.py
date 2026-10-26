"""Directed and seeded instruction streams for core bring-up."""
import random
import struct


def i(rd, rs, value, f3=0, op=0x13):
    return ((value & 4095) << 20) | (rs << 15) | (f3 << 12) | (rd << 7) | op


def r(rd, a, b, f3=0, alternate=0):
    return (alternate << 25) | (b << 20) | (a << 15) | (f3 << 12) | (rd << 7) | 0x33


def store(a, b, value, f3):
    value &= 4095
    return ((value >> 5) << 25) | (b << 20) | (a << 15) | (f3 << 12) | ((value & 31) << 7) | 0x23


def branch(a, b, offset, f3=0):
    v = offset & 8191
    return ((v >> 12) << 31) | (((v >> 5) & 63) << 25) | (b << 20) | (a << 15) | (f3 << 12) | (((v >> 1) & 15) << 8) | (((v >> 11) & 1) << 7) | 0x63


def jal(rd, offset):
    v = offset & 0x1fffff
    return ((v >> 20) << 31) | (((v >> 1) & 1023) << 21) | (((v >> 11) & 1) << 20) | (((v >> 12) & 255) << 12) | (rd << 7) | 0x6f


def csr(rd, src, addr, f3):
    return (addr << 20) | (src << 15) | (f3 << 12) | (rd << 7) | 0x73


def constant(rd, value):
    return [((value+0x800) & 0xfffff000) | (rd << 7) | 0x37, i(rd, rd, value)]


def random_alu(seed, count):
    rng = random.Random(seed)
    words = []
    for _ in range(count):
        rd, a, b, f3 = (rng.randrange(32), rng.randrange(32), rng.randrange(32), rng.randrange(8))
        if rng.randrange(2):
            alternate = 32 if f3 in (0, 5) and rng.randrange(2) else 0
            words.append(r(rd, a, b, f3, alternate))
        else:
            imm = rng.randrange(4096)
            if f3 in (1, 5): imm = rng.randrange(32) | (1024 if f3 == 5 and rng.randrange(2) else 0)
            words.append(i(rd, a, imm, f3))
    return words


def program(seed, mode='normal'):
    words = [i(reg, 0, reg*13-512) for reg in range(1,32)]
    if mode in ('load_fault', 'protocol_error', 'reserved_status', 'wrong_id', 'reset_data', 'payload_error'):
        words += constant(1, 0x900) + [i(2, 1, 0, 2, 3)]
    elif mode == 'store_fault':
        words += constant(1, 0x8000) + [store(1, 0, 0, 2)]
    elif mode == 'fetch_fault':
        words += constant(1, 0x300) + [i(0, 1, 0, 0, 0x67)]
    else:
        words += [i(1, 0, -1), i(2, 0, 1), i(3, 0, 0)]
        for f3 in (0,1,4,5,6,7):
            for a,b in ((1,2),(2,1),(1,1)):
                words += [branch(a,b,8,f3), i(4,4,1)]
        words += [jal(5,8), i(6,6,1), 0x00000397]
        target = 0x400 + (len(words)+3)*4
        words += constant(5, target) + [i(5,5,1,0,0x67)]
        words += constant(28,0x8000) + constant(27,0x89abcdef)
        for size, offsets in ((0,range(4)),(1,(0,2)),(2,(0,))):
            for offset in offsets:
                words += [store(28,27,offset,size), i(9,28,offset,size,3)]
                if size < 2: words += [i(10,28,offset,size+4,3)]
        words += [i(0,28,0,2,3)]
        for base in (0x10000000,0x10001000):
            words += constant(28,base) + [store(28,27,1,0), i(11,28,1,4,3)]
        words += constant(28,0x8000)
        words += [i(7,28,1,2,3), store(28,27,1,1)]
        words += constant(28,0x20000000) + [i(7,28,0,2,3),store(28,27,0,2)]
        words += [jal(5,2), branch(1,1,2), branch(1,2,2), i(5,0,2), i(5,5,1,0,0x67)]
        words += [0, 0x02001013, 0x02000033, 0x73, 0x100073, 0x10500073, 0x0000000f, 0x0000100f]
        words += constant(16,0x12345678)
        for f3 in (1,2,3,5,6,7):
            words += [csr(17,16,0x340,f3), csr(18,0,0x340,f3), csr(0,16,0x340,f3)]
        for addr in (0x301,0x304,0x310,0x344,0xf11,0xf12,0xf13,0xf14,0xf15):
            words += [csr(19,0,addr,2), csr(20,16,addr,1)]
        words += [csr(20,0,0xfff,2), csr(0,8,0x300,5), 0x73]
        words += [csr(20,0,0xb02,2), csr(0,0,0xb02,5), csr(20,0,0xb02,2), csr(0,4,0x320,5),csr(20,0,0xb02,2),csr(0,0,0x320,5)]
        words += constant(28,0x200) + constant(27,i(10,0,77))
        words += [store(28,27,0,2),0x100f,i(1,28,0,0,0x67)]
        words += random_alu(seed,1000)
    words += [branch(0,0,0)]
    image = bytearray(0x400+len(words)*4)
    struct.pack_into('<I',image,0,jal(0,0x400))
    handler = [csr(30,0,0x341,2),i(30,30,4),csr(0,30,0x341,1),0x30200073]
    for n, word in enumerate(handler): struct.pack_into('<I',image,0x100+4*n,word)
    struct.pack_into('<II',image,0x200,i(10,0,0),i(0,1,0,0,0x67))
    for n, word in enumerate(words): struct.pack_into('<I',image,0x400+4*n,word)
    return bytes(image)


STORE_BUFFER_PROGRAMS = ('store_miss_drains_under_load_hits', 'store_burst_does_not_block_loads',
                         'dirty_eviction_while_store_drains', 'sb_youngest_wins_same_byte',
                         'partial_overlap_reads_after_drain', 'mmio_store_after_cacheable_stores_order',
                         'uart_read_after_store_burst', 'fence_i_waits_for_sb')


def data_cache_program(name):
    """Directed fetched-core programs for the data cache: (image, boot, end_pc), code at 0x400.
    Store-buffer programs: 0x8560 is a line no program touches before, so a store to it is a write miss
    that holds the store buffer's head for a refill while younger stores queue behind it. A dependent addi
    chain delays a load until older stores have retired into the buffer. Where a witness needs the load inside
    the refill at 50-cycle latency, the load sits in the fence's fetch line or the next one: the fetch unit holds
    both while the fence blocks dispatch, and a later line would arrive only after the refill."""
    words = []
    chain = lambda rd, n: [i(rd,0,0)] + [i(rd,rd,0)]*n
    fence = 0xf
    if name == 'store_miss_drains_under_load_hits':
        # Loads to resident lines B=0x8020 and C=0x8040 hit while the write miss's refill is outstanding.
        words += constant(1,0x8000)+constant(6,0x11223344)+[i(10,1,0x20,2,3), i(11,1,0x40,2,3), i(0,0,0), i(0,0,0)]
        words += [fence, store(1,6,0x560,2)] + chain(20,8) + [r(21,1,20)]
        words += [i(12,21,0x24,2,3), i(13,21,0x48,2,3), i(14,21,0x2c,2,3), i(15,21,0x50,2,3), i(16,1,0x560,2,3), fence]
    elif name == 'store_burst_does_not_block_loads':
        # Eight stores to a resident line between loads of another: each store looks up once.
        words += constant(1,0x8000)+constant(3,0x8020)+constant(6,0x55667788)
        words += [i(10,1,0,2,3), i(11,3,0,2,3), fence]
        for k in range(8): words += [store(1,6,4*k,2), i(12+k,3,4*k,2,3)]
        words += [fence, i(20,1,28,2,3)]
    elif name == 'dirty_eviction_while_store_drains':
        # A dirty in way 0, B in way 1, A least recent (the first fence lands A before B's load); C misses in that
        # set and evicts A while the store to A+4 waits behind the write miss, so that store misses again.
        words += constant(1,0x8000)+constant(6,0x0badf00d)+constant(7,0x13579bdf)
        words += [store(1,6,0,2), fence, i(10,1,0x200,2,3), fence, store(1,6,0x560,2), store(1,7,4,2)] + chain(20,8)
        words += [r(21,1,20), i(11,21,0x400,2,3), i(12,1,4,2,3), i(13,1,0,2,3), fence]
    elif name == 'sb_youngest_wins_same_byte':
        # Three buffered stores write byte 1 of A, absent, so the first holds the buffer for its refill; loads
        # behind the chain (which yields A) take every byte from the buffer and must take the youngest (sh).
        words += constant(1,0x8000)+[i(6,0,0x11), i(7,0,0x22)]+constant(9,0x4455)+[i(0,0,0), i(0,0,0)]
        words += [fence, store(1,6,1,0), store(1,7,1,0), store(1,9,0,1)] + [i(21,1,0)] + [i(21,21,0)]*8
        words += [i(11,21,1,4,3), i(12,21,0,5,3), i(13,21,1,0,3), fence, i(14,1,0,2,3)]
    elif name == 'partial_overlap_reads_after_drain':
        # Word and half loads overlap a buffered byte store only in part: they wait for it to land, then read it.
        words += constant(1,0x8000)+constant(6,0x01020304)+[i(7,0,0x7e), store(1,6,0,2), i(0,0,0), i(0,0,0)]
        words += [fence, store(1,6,0x560,2), store(1,7,2,0)] + [i(21,1,0)] + [i(21,21,0)]*8
        words += [i(11,21,0,2,3), i(12,21,2,5,3), fence]
    elif name == 'mmio_store_after_cacheable_stores_order':
        # The UART store reaches the device only after both older cacheable stores have landed.
        words += constant(1,0x8000)+constant(5,0x8560)+constant(9,0x10000000)+constant(6,0x31415926)+[i(8,0,0x41)]
        words += [i(10,1,0,2,3), fence, store(5,6,0,2), store(1,6,0,2), store(9,8,1,0), i(11,9,1,4,3)]
        words += [i(12,1,0,2,3), fence]
    elif name == 'uart_read_after_store_burst':
        # The UART read waits until the burst behind the write miss has drained; the burst overfills the buffer.
        words += constant(1,0x8000)+constant(5,0x8560)+constant(9,0x10000000)+constant(6,0x27182818)+[i(8,0,0x42)]
        words += [store(9,8,1,0), i(10,1,0,2,3), fence, store(5,6,0,2)]
        words += [store(1,6,0,2), store(1,6,4,2), store(1,6,8,2), store(1,6,12,2), i(11,9,1,4,3), fence]
    elif name == 'fence_i_waits_for_sb':
        # The store that patches the next instruction is the third buffered store when fence.i reaches the head:
        # a clean started in the gap between two landings would miss it.
        words += constant(5,0x8560)+constant(6,0x600d)+constant(7,i(20,0,77))+[0, 0]
        patch = len(words)-2
        words += [i(20,0,1), store(5,6,0,2), store(5,6,4,2), store(8,7,0,2), 0x100f, i(20,0,1), fence]
        words[patch:patch+2] = constant(8,0x400+4*(len(words)-2))
    elif name == 'fence_i_after_store':
        # Two patched words, each new only in a dirty data-cache line at fence.i: sub's first word, whose line the
        # instruction cache holds from the first call, and the word after fence.i, which ends its line so fetch
        # has prefetched the next one. The second call and the fall-through must execute the new words.
        words += [jal(0,12), i(20,0,1), i(0,1,0,0,0x67)]
        words += constant(5,0x404)+constant(7,i(20,0,77))+constant(8,0)+constant(9,i(21,0,99))
        patch = len(words)-4
        words += [jal(1,0x404-(0x400+4*len(words))), store(5,7,0,2)]
        while len(words)%8 != 6: words.append(i(0,0,0))
        words += [store(8,9,0,2), 0x100f, i(21,0,1)]
        words[patch:patch+2] = constant(8,0x400+4*(len(words)-1))
        words += [jal(1,0x404-(0x400+4*len(words))), r(22,20,21)]
    elif name == 'recovery_during_load_miss':
        # Both ways of set 2 are dirty; a cold load feeds a cold taken branch, so the not-taken prediction
        # sends a load into set 2 that misses on a dirty victim and is squashed while its miss is outstanding.
        words += constant(1,0x8040)+constant(3,0x8440)+constant(4,0x8840)+constant(5,0x9000)+constant(6,0x11223344)
        words += [store(1,6,0,2), store(3,6,4,2), 0xf, i(2,5,0,2,3), branch(2,0,12), i(7,4,0,2,3), i(8,7,1)]
        words += [i(9,4,0,2,3), i(10,1,0,2,3), i(11,3,4,2,3)]
    elif name == 'mmio_bypasses_dcache':
        # Two reads of one UART byte: each must reach the device, never the cache.
        words += constant(1,0x10000000)+[i(2,0,0x5a), store(1,2,1,0), i(3,1,1,4,3), i(4,1,1,4,3)]
    else: raise ValueError(f'unknown program {name}')
    words += [branch(0,0,0)]
    image = bytearray(0x400+4*len(words))
    struct.pack_into('<I',image,0,jal(0,0x400))
    for n, word in enumerate(words): struct.pack_into('<I',image,0x400+4*n,word)
    return bytes(image), [jal(0,0x400)], 0x400+4*(len(words)-1)

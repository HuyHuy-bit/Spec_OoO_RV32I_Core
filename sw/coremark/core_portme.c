/* CoreMark port for the fetched core. The bench counts cycles, so the timer reads a
   fixed tick count: reading mcycle would make RTL and reference traces differ.
   Adapted from EEMBC CoreMark barebones/core_portme.c (Apache-2.0). */
#include "coremark.h"
#include "core_portme.h"

volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* ee_printf output; the runner reads it from memory after the run. */
char coremark_log[2048];
static unsigned log_used;

void uart_send_char(char c)
{
    if (log_used < sizeof(coremark_log) - 1)
        coremark_log[log_used++] = c;
}

void start_time(void) {}
void stop_time(void) {}
/* Ten "seconds" passes core_main's minimum-runtime rule; the printed score is meaningless. */
CORE_TICKS get_time(void) { return 10; }
secs_ret time_in_secs(CORE_TICKS ticks) { return ticks; }

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p) { p->portable_id = 0; }

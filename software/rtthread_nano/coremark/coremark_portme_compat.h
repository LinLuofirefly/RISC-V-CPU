#ifndef COREMARK_EXTERNAL_PORTME_COMPAT_H
#define COREMARK_EXTERNAL_PORTME_COMPAT_H

#include <stddef.h>

/* The selected external CoreMark port calls read_csr(mcycle), but this CPU
 * intentionally exposes elapsed time through the independent 50 MHz MMIO
 * counter.  Keep the external port source unchanged and bind that call to the
 * board counter here. */
unsigned long long coremark_portme_read_counter(void);
void coremark_printf(const char *format, ...);
#define read_csr(reg) coremark_portme_read_counter()

#endif

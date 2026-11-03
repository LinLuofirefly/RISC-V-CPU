#include <stdint.h>

#include "board.h"

unsigned long long coremark_portme_read_counter(void)
{
    static uint32_t previous_low;
    static uint64_t wrap_base;
    static int initialized;
    uint32_t current_low;
    unsigned int index;

    if (!initialized)
    {
        BSP_MMIO32(BSP_COUNTER_ADDR) = BSP_COUNTER_START_CMD;

        /* Allow the enable and Gray-coded counter value to cross the two
         * synchronizers before taking the first timestamp. */
        for (index = 0u; index < 32u; index++)
        {
            current_low = BSP_MMIO32(BSP_COUNTER_ADDR);
        }
        previous_low = current_low;
        initialized = 1;
        return (unsigned long long)current_low;
    }

    current_low = BSP_MMIO32(BSP_COUNTER_ADDR);
    if (current_low < previous_low)
    {
        wrap_base += (UINT64_C(1) << 32);
    }
    previous_low = current_low;

    return (unsigned long long)(wrap_base | (uint64_t)current_low);
}

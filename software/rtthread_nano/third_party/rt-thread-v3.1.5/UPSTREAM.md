# RT-Thread upstream source

- Project: RT-Thread
- Official repository: `https://github.com/RT-Thread/rt-thread.git`
- Version: `v3.1.5`
- Source path retained here: `include/`, Nano kernel files from `src/`, and `LICENSE`

`port-reference/` is this CPU's maintained RV32 machine-mode port. It is kept
beside the versioned kernel source so the existing bare-metal Makefiles remain
self-contained; it is not claimed to be an unmodified upstream v3.1.5 file.

Nano compatibility patch: upstream v3.1.5 includes `rtlibc.h` for every GCC
target. `include/rtdef.h` guards that include with `RT_USING_LIBC` here because
this freestanding image deliberately does not provide newlib/POSIX headers.

Startup trace patch: `src/components.c` emits initialization milestones only
when `RT_USING_STARTUP_TRACE` is enabled by the application configuration.

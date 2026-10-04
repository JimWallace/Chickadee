// CProcessHardening/ProcessHardening.c
//
// See include/CProcessHardening.h.

#include "CProcessHardening.h"

#ifdef __linux__
#include <sys/prctl.h>
#endif

int chickadee_refuse_process_inspection(void) {
#ifdef __linux__
    return prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
#else
    return 0;
#endif
}

int chickadee_process_inspection_allowed(void) {
#ifdef __linux__
    int dumpable = prctl(PR_GET_DUMPABLE, 0, 0, 0, 0);
    return dumpable < 0 ? -1 : (dumpable != 0);
#else
    return -1;
#endif
}

#include <sys/ioctl.h>

#if defined(__linux__)
#include <linux/vt.h>
#include <linux/kd.h>
#elif defined(__FreeBSD__)
#include <sys/consio.h>
#endif

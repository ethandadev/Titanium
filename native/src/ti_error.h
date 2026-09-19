/* Error and logging hooks shared by the Objective-C++ core and the pure C++
 * shader translator. Deliberately free of Objective-C so ti_translate.cpp can
 * include it without dragging Metal headers into a C++ translation unit. */
#ifndef TITANIUM_TI_ERROR_H
#define TITANIUM_TI_ERROR_H
#include "titanium/ti_api.h"

#if defined(__cplusplus)
extern "C" {
#endif
void     ti_set_error(const char *fmt, ...) __attribute__((format(printf,1,2)));
void     ti_log(TiLogLevel lvl, const char *fmt, ...) __attribute__((format(printf,2,3)));
TiResult ti_fail(TiResult r, const char *fmt, ...) __attribute__((format(printf,2,3)));
#if defined(__cplusplus)
}
#endif
#endif

#ifndef CRUCIBLE_H
#define CRUCIBLE_H

#ifdef __cplusplus__
extern "C" {
#endif //__cplusplus__

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

void crucible_assume(uint8_t x, const char *file, int line);
void crucible_assert(uint8_t x, const char *file, int line);

int8_t   crucible_int8_t   (const char *name);
int16_t  crucible_int16_t  (const char *name);
int32_t  crucible_int32_t  (const char *name);
int64_t  crucible_int64_t  (const char *name);

size_t   crucible_size_t   (const char *name);

#define crucible_uint8_t(n)  ((uint8_t)crucible_int8_t(n))
#define crucible_uint16_t(n)  ((uint16_t)crucible_int16_t(n))
#define crucible_uint32_t(n)  ((uint32_t)crucible_int32_t(n))
#define crucible_uint64_t(n)  ((uint64_t)crucible_int64_t(n))

#define assuming(e) crucible_assume(e, __FILE__, __LINE__)
#define check(e) crucible_assert(e, __FILE__, __LINE__)


// API for SV-COMP
void __VERIFIER_assume(int);
void __VERIFIER_error(void);
unsigned int __VERIFIER_nondet_uint(void);
char __VERIFIER_nondet_char(void);

#ifdef __cplusplus__
}
#endif //__cplusplus__

#endif

/* The QUADPACK vendored types: the f2c translation's own vocabulary,
   spelled here so no libf2c is needed. `integer` is f2c's 32-bit
   integer, `doublereal` its double, and D_fp the integrand's calling
   convention — f2c renders every integrand call as `(*f)(&x)`. The
   abs/min/max macros are f2c's exact arithmetic ones: each is a plain
   comparison or negation, no library call, so the adaptive walk is
   bit-identical on every host. */

#ifndef EMO_QUADPACK_H
#define EMO_QUADPACK_H

#include <math.h>
#include <stdint.h>

typedef int32_t integer;
typedef double doublereal;
typedef int logical;
typedef double (*D_fp)(double *);

#define TRUE_ (1)
#define FALSE_ (0)

#define abs(x) ((x) >= 0 ? (x) : -(x))
#define min(a, b) ((a) <= (b) ? (a) : (b))
#define max(a, b) ((a) >= (b) ? (a) : (b))

/* The vendored entry points: f2c's transliteration of the Fortran
   names (trailing underscore), exact signatures. */
int dqags_(D_fp f, doublereal *a, doublereal *b, doublereal *epsabs,
           doublereal *epsrel, doublereal *result, doublereal *abserr,
           integer *neval, integer *ier, integer *limit, integer *lenw,
           integer *last, integer *iwork, doublereal *work);
int dqagi_(D_fp f, doublereal *bound, integer *inf, doublereal *epsabs,
           doublereal *epsrel, doublereal *result, doublereal *abserr,
           integer *neval, integer *ier, integer *limit, integer *lenw,
           integer *last, integer *iwork, doublereal *work);

#endif

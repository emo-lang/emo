/* The C glue of the quad package: one exact-ABI wrapper over the
   vendored QUADPACK translation (native/dq*.c). The build compiles
   this file with -I .emo-build, and emo_defs.h is the compiler's own
   declaration of the package's `foreign def`: the returned tuple's
   struct typedef (emo_shape1) and the callback pair land there, so a
   signature that drifts — here or in internal/ffi.emo — breaks at cc
   time, in both directions. (The shape number is the first struct
   shape this program registers; a program that registers another
   shape before quad's shifts it, and the mismatch fails here, loudly,
   at cc time.) */

#include <stdint.h>

#include "emo_defs.h"

#include "native/quadpack.h"

/* The workspace: the shim owns it, so the Emo side never sees one. The
   limit is the package's own — 500 subintervals, the subdivision cap
   ier = 1 reports — and both arrays live on the stack of the call:
   500 integers and 2000 doubles, 16 KB. */

#define EMO_QUAD_LIMIT 500

/* The integrand's home. The callback contract crosses the interface as
   (trampoline, userdata), but QUADPACK's Fortran function pointer
   carries no state, so the pair parks in this file-scope slot for the
   length of one call and the adapter below reads it. The c runtime is
   one OS thread (CHECK.md), so the slot has no contention; the guard
   refuses a nested integrate — an integrand that called back into
   quad.integrate would overwrite its own slot — with the shim's own
   ier = 7, which quad.emo words. */

static double (*g_at_cb)(double, void *);
static void *g_at_data;
static int g_inside = 0;

static double emo_quad_integrand(double *x) {
  return g_at_cb(*x, g_at_data);
}

emo_shape1 emo_quad_integrate(double a, double b, double epsabs,
                              double epsrel,
                              double (*at_cb)(double, void *),
                              void *at_data) {
  emo_shape1 out;
  integer iwork[EMO_QUAD_LIMIT];
  doublereal work[EMO_QUAD_LIMIT * 4];
  integer limit = EMO_QUAD_LIMIT;
  integer lenw = EMO_QUAD_LIMIT * 4;
  integer last;
  integer neval;
  integer ier;
  if (g_inside) {
    out.__f0 = 0.0;
    out.__f1 = 0.0;
    out.__f2 = 0;
    out.__f3 = 7;
    return out;
  }
  g_inside = 1;
  g_at_cb = at_cb;
  g_at_data = at_data;
  dqags_(emo_quad_integrand, &a, &b, &epsabs, &epsrel, &out.__f0, &out.__f1,
         &neval, &ier, &limit, &lenw, &last, iwork, work);
  g_inside = 0;
  out.__f2 = neval;
  out.__f3 = ier;
  return out;
}

/* The infinite-range entry: the same workspace, the same integrand
   slot, dqagi's (bound, inf) pair — inf is netlib's own code, 1 for
   [bound, +∞), -1 for (−∞, bound], 2 for the whole line. */

emo_shape1 emo_quad_integrate_infinite(double bound, int64_t inf,
                                       double epsabs, double epsrel,
                                       double (*at_cb)(double, void *),
                                       void *at_data) {
  emo_shape1 out;
  integer iwork[EMO_QUAD_LIMIT];
  doublereal work[EMO_QUAD_LIMIT * 4];
  integer limit = EMO_QUAD_LIMIT;
  integer lenw = EMO_QUAD_LIMIT * 4;
  integer last;
  integer neval;
  integer ier;
  integer code = (integer)inf;
  if (g_inside) {
    out.__f0 = 0.0;
    out.__f1 = 0.0;
    out.__f2 = 0;
    out.__f3 = 7;
    return out;
  }
  g_inside = 1;
  g_at_cb = at_cb;
  g_at_data = at_data;
  dqagi_(emo_quad_integrand, &bound, &code, &epsabs, &epsrel, &out.__f0,
         &out.__f1, &neval, &ier, &limit, &lenw, &last, iwork, work);
  g_inside = 0;
  out.__f2 = neval;
  out.__f3 = ier;
  return out;
}

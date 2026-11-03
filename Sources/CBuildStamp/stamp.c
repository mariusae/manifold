#include "buildstamp.h"

// generated.h is written by scripts/stamp-build.sh (as build-app.sh and
// build-linux.sh build), not kept in git; a plain `swift build` has none.
#if __has_include("generated.h")
#include "generated.h"
#endif
#ifndef MANIFOLD_REVISION
#define MANIFOLD_REVISION ""
#endif
#ifndef MANIFOLD_BUILT
#define MANIFOLD_BUILT 0
#endif

const char *manifold_build_revision(void) { return MANIFOLD_REVISION; }
long long manifold_build_time(void) { return MANIFOLD_BUILT; }

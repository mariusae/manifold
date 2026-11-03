#ifndef MANIFOLD_BUILDSTAMP_H
#define MANIFOLD_BUILDSTAMP_H

/// What this build was made from: its git revision (with "-dirty" and a
/// hash of the changes when the tree had any), and when that was first
/// built (seconds since 1970) — "" and 0 for a build without a stamp.
const char *manifold_build_revision(void);
long long manifold_build_time(void);

#endif

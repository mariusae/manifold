#ifndef MANIFOLD_VT_H
#define MANIFOLD_VT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// The host's terminal emulator (libmanifoldvt, from vendor/ghostty's
// src/manifold_vt.zig): the same emulator the app draws with, kept for
// each shell and written out as a snapshot for a terminal that attaches.
typedef struct mvt_terminal mvt_terminal;

mvt_terminal *mvt_new(uint16_t cols, uint16_t rows, size_t max_scrollback);
void mvt_free(mvt_terminal *t);
void mvt_feed(mvt_terminal *t, const uint8_t *bytes, size_t len);
void mvt_resize(mvt_terminal *t, uint16_t cols, uint16_t rows);
bool mvt_alternate(mvt_terminal *t);
// Escape sequences that make the terminal again, with the last `history`
// rows of history (all, if negative); freed with mvt_free_bytes.
uint8_t *mvt_snapshot(mvt_terminal *t, ptrdiff_t history, size_t *out_len);
void mvt_free_bytes(uint8_t *bytes, size_t len);

#endif

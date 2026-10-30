// Default compatibility settings
#ifndef HADRON_FEATS_DEFAULTS_H
#define HADRON_FEATS_DEFAULTS_H

#include <stddef.h>
#include <stdint.h>

#define NP_DEFAULTS_ROSETTA 0
#define NP_DEFAULTS_FEX     1

#define NP_DEFAULTS_TEXT_MAX   1024

int np_defaults_save(uint32_t runner, const char *text);

int np_defaults_save_build(const char *build, uint32_t runner, const char *text);

// Returns -1 if the defaults saved but some runtimes kept their own settings.
int np_defaults_apply_build(const char *build, uint32_t runner);

// Returns 0 if the file is there but can't be read.
int np_defaults_read(uint32_t runner, char *out, size_t size);

// Returns 0 if the version has no settings of its own, -1 if they can't be read.
int np_defaults_read_build(const char *build, uint32_t runner, char *out, size_t size);

#endif // HADRON_FEATS_DEFAULTS_H

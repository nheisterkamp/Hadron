// Enables Steam Play in the UI/enables the Compatibility tab in game properties
#ifndef HADRON_FEATS_WEBPATCH_H
#define HADRON_FEATS_WEBPATCH_H

#include <stddef.h>
#include <stdint.h>

int np_webpatch_should_patch(const char *path);

// Sets the default picker fallback for this thread. Names with characters outside
// letters, digits, '_', '$', '.' and '-' are dropped.
void np_webpatch_set_fallback_tool(const char *name);

#define NP_WEBPATCH_FEX_TOOLS_MAX 16

// Sets the tools this thread's options panel treats as FEX, which run arm64 Wine. Names
// the fallback would drop are skipped, as is anything past NP_WEBPATCH_FEX_TOOLS_MAX.
void np_webpatch_set_fex_tools(const char *const *names, size_t count);

// The compat UIs, named so a caller can compare against the table rather than a literal
// of its own that a rename would leave behind. forcetool calls SpecifyCompatTool straight
// out; selecttool reads its list from the CompatManager routes.
#define NP_SHAPE_FORCETOOL  "forcetool"
#define NP_SHAPE_SELECTTOOL "selecttool"

// `out_shape` is optional and names the compat UI the chunk carried, so a caller can tell
// which page it just served without probing the bytes a second time. It is set whenever a
// shape is identified, including the drifted case that returns NULL.
char *np_webpatch_transform(const uint8_t *src, size_t src_len, size_t *out_len,
                            const char **out_shape);

#endif // HADRON_FEATS_WEBPATCH_H

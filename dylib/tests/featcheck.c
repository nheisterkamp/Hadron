#include "../feats/webpatch.c"

#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>

int   np_log_level = NP_LVL_WARN;
FILE *np_log_file;

char *np_nativeplatform_javascript(void) {
    return NULL;
}

static int g_failed;
static char g_home[1024];
static char g_featdir[1200];

static void ok(int cond, const char *what) {
    printf("  %s  %s\n", cond ? "ok  " : "FAIL", what);
    if (!cond) g_failed++;
}

static void shout(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

static void write_desc(const char *name, const char *body) {
    char path[2048];
    FILE *f;
    snprintf(path, sizeof(path), "%s/%s", g_featdir, name);
    if (!(f = fopen(path, "w"))) { shout("cannot write %s", path); g_failed++; return; }
    fputs(body, f);
    fclose(f);
}

static void clear_descs(void) {
    char cmd[2600];
    snprintf(cmd, sizeof(cmd), "rm -f '%s'/*.conf", g_featdir);
    if (system(cmd) != 0) { shout("cannot clear %s", g_featdir); g_failed++; }
}

static void make_asset(const char *rel) {
    char path[2048], cmd[2200];
    FILE *f;
    snprintf(path, sizeof(path), "%s/%s", g_home, rel);
    snprintf(cmd, sizeof(cmd), "mkdir -p \"$(dirname '%s')\"", path);
    if (system(cmd) != 0) { shout("cannot make dirs for %s", path); g_failed++; return; }
    if (!(f = fopen(path, "w"))) { shout("cannot write %s", path); g_failed++; return; }
    fclose(f);
}

static void rebuild(void) {
    g_feat_ready_done = 0;
    feat_build();
}

static char *ready_json(void) { rebuild(); return g_feat_ready; }
static char *feats_json(void) { rebuild(); return g_feat_rows; }

int main(void) {
    char tmpl[] = "/tmp/np-featcheck.XXXXXX";
    char cmd[2600];
    char *dir = mkdtemp(tmpl);

    if (!dir) { fputs("cannot make a temp directory\n", stderr); return 2; }
    snprintf(g_home, sizeof(g_home), "%s", dir);
    snprintf(g_featdir, sizeof(g_featdir),
             "%s/" NP_FEAT_DIR, g_home);
    snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", g_featdir);
    if (system(cmd) != 0) { fputs("cannot make the plugins folder\n", stderr); return 2; }
    setenv("HOME", g_home, 1);

    puts("== an empty plugins folder");
    ok(strcmp(feats_json(), "[]") == 0, "renders no rows");
    ok(strcmp(ready_json(), "{}") == 0, "reports no readiness");

    puts("== a plugin with an unmet requires");
    write_desc("10-a.conf",
               "key = HADRON_A\nlabel = Feature A\nsection = dev\n"
               "on = 1\noff = 0\nrequires = assets/a.dylib\n");
    ok(strstr(feats_json(),
              "{k:\"HADRON_A\",l:\"Feature A\",on:\"1\",off:\"0\",dep:\"\",d:\"\"}") != NULL,
       "renders with its label and values");
    ok(strcmp(ready_json(), "{\"HADRON_A\":0}") == 0, "is not ready");

    puts("== once the asset exists");
    make_asset("assets/a.dylib");
    ok(strcmp(ready_json(), "{\"HADRON_A\":1}") == 0, "is ready");

    puts("== repeated requires are any-of");
    clear_descs();
    write_desc("10-b.conf",
               "key = HADRON_B\nlabel = Feature B\nsection = dev\n"
               "requires = assets/missing-one.dylib\nrequires = assets/a.dylib\n");
    ok(strcmp(ready_json(), "{\"HADRON_B\":1}") == 0, "the second entry can satisfy it");

    puts("== a row that requires nothing");
    clear_descs();
    write_desc("10-c.conf", "key = HADRON_C\nlabel = Feature C\nsection = dev\n");
    ok(strcmp(ready_json(), "{\"HADRON_C\":1}") == 0,
       "is always offerable, having nothing that can be missing");
    ok(strstr(feats_json(), "on:\"1\"") != NULL, "defaults its on value to 1");

    puts("== file order decides row order");
    clear_descs();
    write_desc("30-z.conf", "key = HADRON_Z\nlabel = Zed\nsection = dev\n");
    write_desc("10-a.conf", "key = HADRON_A\nlabel = Ay\nsection = dev\n");
    write_desc("20-m.conf", "key = HADRON_M\nlabel = Em\nsection = dev\n");
    {
        const char *j = feats_json();
        const char *a = strstr(j, "HADRON_A");
        const char *m = strstr(j, "HADRON_M");
        const char *z = strstr(j, "HADRON_Z");
        ok(a && m && z && a < m && m < z, "rows follow the sorted file names");
    }

    puts("== rejections");
    clear_descs();
    write_desc("10-ok.conf", "key = HADRON_OK\nlabel = Fine\nsection = dev\n");
    write_desc("20-badsection.conf", "key = HADRON_BAD\nlabel = Bad\nsection = graphics\n");
    write_desc("30-nokey.conf", "label = No key\nsection = dev\n");
    write_desc("40-dup.conf", "key = HADRON_OK\nlabel = Again\nsection = dev\n");
    {
        const char *j = feats_json();
        ok(strstr(j, "HADRON_OK") != NULL, "a good plugin still loads");
        ok(strstr(j, "HADRON_BAD") == NULL, "an unknown section is refused");
        ok(strstr(j, "No key") == NULL, "a plugin with no key is refused");
        ok(strstr(j, "Again") == NULL, "a repeated key is refused");
    }
    clear_descs();
    write_desc("10-evil.conf", "key = HADRON_A:-}$(touch x)${X\nlabel = Evil\n");
    write_desc("20-lower.conf", "key = HADRON_low\nlabel = Lower\n");
    write_desc("30-bare.conf", "key = HADRON_\nlabel = Bare\n");
    write_desc("40-nolabel.conf", "key = HADRON_NOLABEL\n");
    ok(strcmp(feats_json(), "[]") == 0, "a key that is not a HADRON_ name is refused");
    ok(strcmp(ready_json(), "{}") == 0, "and so is a plugin with no label");

    puts("== a repeated field");
    clear_descs();
    write_desc("10-f.conf",
               "key = HADRON_F\nkey = HADRON_G\nlabel = First\nlabel = Second\n"
               "on = 2\non = 3\n");
    ok(strstr(feats_json(), "{k:\"HADRON_F\",l:\"First\",on:\"2\"") != NULL,
       "keeps its first value");

    puts("== limits shared with compat_run.sh");
    clear_descs();
    {
        char body[4096];
        memset(body, 'x', sizeof(body));
        memcpy(body, "key = HADRON_LONG\nlabel = L\n# ", 30);
        memcpy(body + 2100, "\n", 2);
        write_desc("10-line.conf", body);
    }
    write_desc("20-on.conf", "key = HADRON_ON\nlabel = On\non = 0123456789012345678901234567890123\n");
    ok(strcmp(feats_json(), "[]") == 0, "a line or value too long loses the file");
    clear_descs();
    make_asset("assets/fifth.dylib");
    write_desc("10-five.conf",
               "key = HADRON_FIVE\nlabel = Five\nrequires = m1\nrequires = m2\n"
               "requires = m3\nrequires = m4\nrequires = assets/fifth.dylib\n");
    ok(strcmp(ready_json(), "{\"HADRON_FIVE\":0}") == 0, "only the first four requires count");
    clear_descs();
    write_desc("10-vt.conf", "key\v= HADRON_VT\f\nlabel = Vt\n");
    ok(strstr(feats_json(), "k:\"HADRON_VT\"") != NULL, "any blank counts as space");
    clear_descs();
    for (int i = 0; i < NP_FEAT_MAX; i++) {
        char name[32], body[2048], fill[600];
        memset(fill, '"', sizeof(fill));
        snprintf(name, sizeof(name), "%02d.conf", i);
        snprintf(body, sizeof(body),
                 "key = HADRON_%0180d\nlabel = %.190s\ndescription = %.510s\n"
                 "on = %.31s\noff = %.31s\ndepends = %.190s\n",
                 i, fill, fill, fill, fill, fill);
        write_desc(name, body);
    }
    {
        const char *j = feats_json();
        int rows = 0;
        for (const char *p = j; (p = strstr(p, "{k:")); p++) rows++;
        ok(rows == NP_FEAT_MAX, "the most plugins at their longest all render");
    }

    puts("== a transform");
    rebuild();
    {
        size_t len = 0;
        free(np_webpatch_transform((const uint8_t *)"x", 1, &len, NULL));
    }
    ok(!g_feat_ready_done, "reads the plugins again");

    puts("== an optional description");
    clear_descs();
    write_desc("10-d.conf",
               "key = HADRON_D\nlabel = Dee\nsection = dev\n"
               "description = What this does, in a sentence.\n");
    ok(strstr(feats_json(), "d:\"What this does, in a sentence.\"") != NULL,
       "is carried through to the row");
    clear_descs();
    write_desc("10-e.conf", "key = HADRON_E\nlabel = Ee\nsection = dev\n");
    ok(strstr(feats_json(), "d:\"\"") != NULL,
       "is empty when the plugin omits it");

    puts("== a label cannot break the page it renders into");
    clear_descs();
    write_desc("10-q.conf",
               "key = HADRON_Q\nlabel = He said \"go\" \\ onwards\nsection = dev\n");
    ok(strstr(feats_json(), "l:\"He said \\\"go\\\" \\\\ onwards\"") != NULL,
       "quotes and backslashes are escaped");

    puts("== a missing plugins folder");
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_featdir);
    if (system(cmd) != 0) { shout("cannot remove %s", g_featdir); g_failed++; }
    ok(strcmp(feats_json(), "[]") == 0, "renders no rows, since nothing ships by default");
    ok(strcmp(ready_json(), "{}") == 0, "reports no readiness");

    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", g_home);
    if (system(cmd) != 0) shout("note: could not remove %s", g_home);

    if (g_failed) { printf("\n%d failure(s)\n", g_failed); return 1; }
    puts("\n==> featcheck: plugins load, rank, validate and report readiness");
    return 0;
}

/* Checks the runtime's steamclient redirect without Steam: load Valve's steamclient
 * from the current directory and confirm its exports jump into lsteamclient.
 * Build once per arch with mingw, run with the runtime's wine from a directory
 * holding steamclient.dll / steamclient64.dll. Exit 0 on success. */

#include <windows.h>
#include <stdio.h>

#ifdef _WIN64
#define STEAMCLIENT "steamclient64.dll"
#else
#define STEAMCLIENT "steamclient.dll"
#endif

static const char *exports[] = { "CreateInterface", "Steam_BGetCallback", "Steam_FreeLastCallback" };

static void *jump_target(const unsigned char *code)
{
    void *target;
#ifdef _WIN64
    if (code[0] != 0x48 || code[1] != 0xb8 || code[10] != 0xff || code[11] != 0xe0) return NULL;
    memcpy(&target, code + 2, sizeof(target));
#else
    if (code[0] != 0xb8 || code[5] != 0xff || code[6] != 0xe0) return NULL;
    memcpy(&target, code + 1, sizeof(target));
#endif
    return target;
}

int main(void)
{
    HMODULE sc = LoadLibraryA(STEAMCLIENT), ls;
    unsigned i, ok = 0;

    if (!sc)
    {
        printf("FAIL: could not load %s, error %lu\n", STEAMCLIENT, GetLastError());
        return 1;
    }
    if (!(ls = GetModuleHandleA("lsteamclient.dll")))
    {
        printf("FAIL: %s loaded but lsteamclient.dll did not\n", STEAMCLIENT);
        return 1;
    }
    for (i = 0; i < sizeof(exports) / sizeof(exports[0]); i++)
    {
        void *native = GetProcAddress(sc, exports[i]);
        void *wanted = GetProcAddress(ls, exports[i]);
        void *target = native ? jump_target(native) : NULL;

        printf("%-24s %s\n", exports[i],
               !native || !wanted ? "absent" : target == wanted ? "redirected" : "NOT redirected");
        if (native && wanted && target != wanted) return 1;
        if (target == wanted && target) ok++;
    }
    if (!ok)
    {
        printf("FAIL: no export was redirected\n");
        return 1;
    }
    printf("PASS: %s -> lsteamclient\n", STEAMCLIENT);
    return 0;
}

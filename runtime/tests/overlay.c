/* Checks which d3d11 a game gets through HADRON_DLL_OVERLAY: DXMT loads winemetal.dll,
 * DXVK loads Vulkan, and Wine's own d3d11 (on OpenGL here) loads neither.
 * Prints "dxmt", "dxvk" or "wine" and whether a hardware device could be created. Exit
 * 0 when the device was created. Build with mingw for x86_64, run with the runtime's wine. */

#include <windows.h>
#include <stdio.h>

typedef HRESULT (WINAPI *create_device_t)(void *adapter, UINT driver_type, HMODULE software, UINT flags,
                                          const UINT *levels, UINT count, UINT sdk, void **device,
                                          UINT *level, void **context);

int main(void)
{
    HMODULE d3d11 = LoadLibraryA("d3d11.dll");
    create_device_t create;
    void *device = NULL, *context = NULL;
    UINT level = 0;
    HRESULT hr;

    if (!d3d11)
    {
        printf("FAIL: d3d11.dll did not load, error %lu\n", GetLastError());
        return 1;
    }
    create = (create_device_t)GetProcAddress(d3d11, "D3D11CreateDevice");
    /* D3D_DRIVER_TYPE_HARDWARE = 1, D3D11_SDK_VERSION = 7 */
    hr = create ? create(NULL, 1, NULL, 0, NULL, 0, 7, &device, &level, &context) : E_FAIL;
    /* Checked after the device exists, since DXVK loads Vulkan only then. */
    printf("d3d11: %s\n", GetModuleHandleA("winemetal.dll") ? "dxmt"
           : GetModuleHandleA("vulkan-1.dll") || GetModuleHandleA("winevulkan.dll") ? "dxvk" : "wine");
    printf("D3D11CreateDevice: hr=%#lx feature level %#x\n", (unsigned long)hr, level);
    return SUCCEEDED(hr) ? 0 : 1;
}

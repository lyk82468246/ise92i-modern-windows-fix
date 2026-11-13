/* mpr_proxy.c
 *
 * Minimal stand-in for MPR.dll for Xilinx ISE 9.2i on Windows 10 (1903+) / Windows 11.
 *
 * Why this exists:
 *   ISE 9.2i startup (libPortability.dll / libGui_Framework.dll) enumerates the
 *   connected network drives via WNetOpenEnumA / WNetEnumResourceA to resolve
 *   drive letters to UNC paths. On modern Windows the Multiple Provider Router
 *   (MPR) also loads the "Plan 9 Network Provider" (p9np.dll - the WSL \\wsl$
 *   file-sharing provider, introduced long after ISE 9.2i was written).
 *   p9np.dll's NPEnumResource deadlocks, so ise.exe hangs forever before any
 *   window is created.
 *
 * How it works:
 *   The Windows loader resolves static DLL imports by searching the
 *   application directory FIRST. This DLL is placed in bin\nt (the directory
 *   of ise.exe), so it is loaded instead of C:\Windows\SysWOW64\MPR.dll.
 *   It makes the WNet enumeration fail gracefully - exactly the behaviour ISE
 *   shows on machines that simply have no mapped network drives.
 *
 * Build (VS2008 or any 32-bit-capable MSVC):
 *   cl /nologo /W4 /O2 /MT /LD mpr_proxy.c /link /def:mpr_proxy.def /out:MPR.dll
 */

#include <windows.h>

DWORD WINAPI WNetOpenEnumA(DWORD dwScope, DWORD dwType, DWORD dwUsage,
                           LPNETRESOURCEA lpRes, LPHANDLE lphEnum)
{
    (void)dwScope; (void)dwType; (void)dwUsage; (void)lpRes;
    if (lphEnum) *lphEnum = NULL;
    return ERROR_NO_NETWORK;          /* 1223: nothing to enumerate */
}

DWORD WINAPI WNetOpenEnumW(DWORD dwScope, DWORD dwType, DWORD dwUsage,
                           LPNETRESOURCEW lpRes, LPHANDLE lphEnum)
{
    (void)dwScope; (void)dwType; (void)dwUsage; (void)lpRes;
    if (lphEnum) *lphEnum = NULL;
    return ERROR_NO_NETWORK;
}

DWORD WINAPI WNetEnumResourceA(HANDLE hEnum, LPDWORD lpcCount,
                               LPVOID lpBuffer, LPDWORD lpBufferSize)
{
    (void)hEnum; (void)lpBuffer;
    if (lpcCount) *lpcCount = 0;
    if (lpBufferSize) *lpBufferSize = 0;
    return ERROR_NO_MORE_ITEMS;       /* 259 */
}

DWORD WINAPI WNetEnumResourceW(HANDLE hEnum, LPDWORD lpcCount,
                               LPVOID lpBuffer, LPDWORD lpBufferSize)
{
    (void)hEnum; (void)lpBuffer;
    if (lpcCount) *lpcCount = 0;
    if (lpBufferSize) *lpBufferSize = 0;
    return ERROR_NO_MORE_ITEMS;
}

DWORD WINAPI WNetCloseEnum(HANDLE hEnum)
{
    (void)hEnum;
    return NO_ERROR;
}

DWORD WINAPI WNetGetUserA(LPCSTR lpName, LPSTR lpUser, LPDWORD lpLen)
{
    (void)lpName; (void)lpUser;
    if (lpLen) *lpLen = 0;
    return ERROR_NOT_CONNECTED;       /* 2250 */
}

DWORD WINAPI WNetGetUserW(LPCWSTR lpName, LPWSTR lpUser, LPDWORD lpLen)
{
    (void)lpName; (void)lpUser;
    if (lpLen) *lpLen = 0;
    return ERROR_NOT_CONNECTED;
}

BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(hInst);
    return TRUE;
}

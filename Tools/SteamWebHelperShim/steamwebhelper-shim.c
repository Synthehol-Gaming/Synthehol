// SPDX-License-Identifier: MIT
// Based on notpop/steam-on-m1-wine's Steam WebHelper wrapper.
// Steam CEF's D3D11 ANGLE path fails under current macOS Wine translation
// layers. This delegates to Valve's preserved binary with software rendering.

#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>

#define EXTRA_FLAGS L"--disable-gpu --single-process"
#define REAL_BINARY L"steamwebhelper_real.exe"

static const wchar_t *arguments_after_image(void)
{
    const wchar_t *cursor = GetCommandLineW();
    int quoted = 0;
    while (cursor && *cursor) {
        if (*cursor == L'\"') quoted = !quoted;
        else if (*cursor == L' ' && !quoted) break;
        ++cursor;
    }
    while (cursor && *cursor == L' ') ++cursor;
    return cursor ? cursor : L"";
}

int wmain(void)
{
    wchar_t self[MAX_PATH];
    DWORD length = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (!length || length >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return 1;
    wcscpy(slash + 1, REAL_BINARY);

    const wchar_t *arguments = arguments_after_image();
    size_t capacity = wcslen(self) + wcslen(EXTRA_FLAGS) + wcslen(arguments) + 8;
    wchar_t *command = calloc(capacity, sizeof(wchar_t));
    if (!command) return 1;
    _snwprintf(command, capacity, L"\"%ls\" %ls %ls", self, EXTRA_FLAGS, arguments);

    STARTUPINFOW startup = { .cb = sizeof(startup) };
    PROCESS_INFORMATION process = {0};
    BOOL launched = CreateProcessW(
        self, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process
    );
    free(command);
    if (!launched) return 1;
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(process.hProcess, &code);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    return (int)code;
}

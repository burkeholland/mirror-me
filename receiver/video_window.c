// SPDX-License-Identifier: GPL-3.0-or-later
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include "video_window.h"

static const WCHAR video_title[] = L"MirrorMe - iPhone screen";
static HICON small_icon;
static HICON large_icon;
static gsize icons_initialized;
static gint warning_reported;

static void report_failure(DWORD error) {
    if (g_atomic_int_compare_and_exchange(&warning_reported, 0, 1)) {
        g_printerr("MIRRORME_RECEIVER_WARNING: Could not update the video window branding (Windows error %lu).\n", error);
    }
}

static void initialize_icons(void) {
    if (g_once_init_enter(&icons_initialized)) {
        HINSTANCE module = GetModuleHandleW(NULL);
        small_icon = (HICON) LoadImageW(module, MAKEINTRESOURCEW(101), IMAGE_ICON,
            GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED);
        if (!small_icon) report_failure(GetLastError());
        large_icon = (HICON) LoadImageW(module, MAKEINTRESOURCEW(101), IMAGE_ICON,
            GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_SHARED);
        if (!large_icon) report_failure(GetLastError());
        g_once_init_leave(&icons_initialized, 1);
    }
}

static gboolean is_video_window(HWND window) {
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    // The receiver owns no controls/tray window. Only its video sinks create
    // visible top-level captioned windows; never touch another process.
    return pid == GetCurrentProcessId() && IsWindowVisible(window) &&
        (GetWindowLongPtrW(window, GWL_STYLE) & WS_CAPTION) == WS_CAPTION;
}

static gboolean send_window_message(HWND window, UINT message, WPARAM parameter, LPARAM data, DWORD_PTR *result) {
    SetLastError(ERROR_SUCCESS);
    if (SendMessageTimeoutW(window, message, parameter, data, SMTO_ABORTIFHUNG | SMTO_BLOCK, 200, result)) {
        return TRUE;
    }
    DWORD error = GetLastError();
    if (IsWindow(window)) report_failure(error ? error : ERROR_TIMEOUT);
    return FALSE;
}

typedef struct {
    gboolean update;
    gboolean found;
    gboolean valid;
} window_check;

static BOOL CALLBACK visit_window(HWND window, LPARAM data) {
    if (!is_video_window(window)) return TRUE;
    window_check *check = (window_check *) data;
    check->found = TRUE;
    DWORD_PTR result = 0;
    if (check->update) {
        // A timed-out message may finish later. Only send static-lifetime
        // text across threads; never lend the renderer a stack buffer.
        if (!send_window_message(window, WM_SETTEXT, 0, (LPARAM) video_title, &result) || !result) {
            check->valid = FALSE;
        }
    } else {
        // Caption reads are only used by the bounded offline window probe.
        WCHAR title[128] = {0};
        GetWindowTextW(window, title, G_N_ELEMENTS(title));
        if (wcscmp(title, video_title) != 0) check->valid = FALSE;
    }
    const HICON icons[] = {small_icon, large_icon};
    const WPARAM kinds[] = {ICON_SMALL, ICON_BIG};
    for (unsigned int index = 0; index < G_N_ELEMENTS(icons); ++index) {
        if (!icons[index]) {
            check->valid = FALSE;
            continue;
        }
        if (!send_window_message(window, WM_GETICON, kinds[index], 0, &result)) {
            check->valid = FALSE;
        } else if ((HICON) result != icons[index]) {
            if (!check->update || !send_window_message(window, WM_SETICON, kinds[index], (LPARAM) icons[index], &result)) {
                check->valid = FALSE;
            }
        }
    }
    return TRUE;
}

void mirrorme_brand_video_windows(void) {
    initialize_icons();
    window_check check = {TRUE, FALSE, TRUE};
    if (!EnumWindows(visit_window, (LPARAM) &check)) report_failure(GetLastError());
}

gboolean mirrorme_video_windows_branded(void) {
    initialize_icons();
    window_check check = {FALSE, FALSE, TRUE};
    if (!EnumWindows(visit_window, (LPARAM) &check)) return FALSE;
    return check.found && check.valid;
}

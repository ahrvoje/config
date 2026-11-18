#include <windows.h>
#include <algorithm>
#include <climits>
#include <atomic>
#include <condition_variable>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>

using Stamp = ULONGLONG;
constexpr Stamp minute = 600000000;
constexpr ULONGLONG refreshMs = 5000;

struct PathLess {
    bool operator()(const std::wstring &a, const std::wstring &b) const {
        return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_LESS_THAN;
    }
};
using Times = std::map<std::wstring, Stamp, PathLess>;
struct DirectorySample {
    std::wstring containingDirectory;
    Stamp latestLocalWrite = 0;
    ULONGLONG checked = 0;
    int displayedBand = 2;
    bool queued = false;
};
static Times indexed;
static std::map<std::wstring, DirectorySample, PathLess> directorySamples;
static std::set<std::wstring, PathLess> pending;
static std::mutex cacheLock;
static bool running;
static std::atomic<bool> stopping;
static std::condition_variable wake;
extern "C" IMAGE_DOS_HEADER __ImageBase;

static Stamp ticks(FILETIME t) {
    return (static_cast<Stamp>(t.dwHighDateTime) << 32) | t.dwLowDateTime;
}

static int minutesSinceWrite(Stamp written) {
    if (!written) return INT_MAX;
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    Stamp t = ticks(now);
    return static_cast<int>((std::min)(t > written ? (t - written) / minute : 0, static_cast<Stamp>(INT_MAX)));
}

static std::wstring key(std::wstring path) {
    if (path.compare(0, 8, L"\\\\?\\UNC\\") == 0) path = L"\\\\" + path.substr(8);
    else if (path.compare(0, 4, L"\\\\?\\") == 0) path.erase(0, 4);
    while (!path.empty() && path.back() == L'\\') path.pop_back();
    return path;
}

static Stamp latestDirectFileWrite(const std::wstring &folder, Stamp &directoryWrite) {
    std::wstring mask = folder + L"\\";
    WIN32_FILE_ATTRIBUTE_DATA info;
    if (!GetFileAttributesExW(mask.c_str(), GetFileExInfoStandard, &info)) return 0;
    DWORD attrs = info.dwFileAttributes;
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY) ||
        (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) return 0;
    directoryWrite = ticks(info.ftLastWriteTime);
    mask += L'*';
    WIN32_FIND_DATAW entry;
    HANDLE search = FindFirstFileW(mask.c_str(), &entry);
    if (search == INVALID_HANDLE_VALUE) return 0;
    Stamp newest = 0;
    do {
        if (!(entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
            newest = (std::max)(newest, ticks(entry.ftLastWriteTime));
    } while (FindNextFileW(search, &entry));
    FindClose(search);
    return newest;
}

#include "everything_ipc.h"

// A Unicode Query2 reply contains a length-prefixed directory path and a UTC FILETIME per item.
constexpr DWORD fields = EVERYTHING_IPC_QUERY2_REQUEST_PATH | EVERYTHING_IPC_QUERY2_REQUEST_DATE_MODIFIED;
static Times decode(const std::vector<BYTE> &bytes) {
    Times result;
    EVERYTHING_IPC_LIST2 header;
    if (bytes.size() < sizeof(header)) return {};
    memcpy(&header, bytes.data(), sizeof(header));
    if (header.request_flags != fields ||
        header.numitems > (bytes.size() - sizeof(header)) / sizeof(EVERYTHING_IPC_ITEM2)) return {};
    for (DWORD i = 0; i < header.numitems; ++i) {
        EVERYTHING_IPC_ITEM2 item;
        memcpy(&item, bytes.data() + sizeof(header) + i * sizeof(item), sizeof(item));
        size_t offset = item.data_offset;
        constexpr size_t overhead = sizeof(DWORD) + sizeof(wchar_t) + sizeof(Stamp);
        if (offset > bytes.size() || bytes.size() - offset < overhead) return {};
        DWORD chars;
        memcpy(&chars, bytes.data() + offset, sizeof(chars));
        if (chars > (bytes.size() - offset - overhead) / sizeof(wchar_t)) return {};
        std::wstring folder(chars, L'\0');
        memcpy(folder.data(), bytes.data() + offset + sizeof(chars), chars * sizeof(wchar_t));
        Stamp stamp;
        memcpy(&stamp, bytes.data() + offset + sizeof(chars) + (chars + 1) * sizeof(wchar_t), sizeof(stamp));
        folder = key(std::move(folder));
        while (!folder.empty()) {
            auto &existing = result[folder];
            if (existing >= stamp) break;
            existing = stamp;
            auto slash = folder.rfind(L'\\');
            if (slash == std::wstring::npos || slash < 2) break;
            folder.resize(slash);
        }
    }
    return result;
}

static LRESULT CALLBACK receive(HWND window, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg != WM_COPYDATA) return DefWindowProcW(window, msg, wp, lp);
    const auto &data = *reinterpret_cast<const COPYDATASTRUCT *>(lp);
    if (data.dwData != 1 || !data.lpData || data.cbData < sizeof(EVERYTHING_IPC_LIST2)) return FALSE;
    auto &bytes = *reinterpret_cast<std::vector<BYTE> *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    const auto *begin = static_cast<const BYTE *>(data.lpData);
    bytes.assign(begin, begin + data.cbData);
    return TRUE;
}

static Times readIndex() {
    HWND server = FindWindowW(EVERYTHING_IPC_WNDCLASSW, nullptr);
    if (!server) server = FindWindowW(L"EVERYTHING_TASKBAR_NOTIFICATION_(1.5a)", nullptr);
    if (!server) return {};
    HWND reply = CreateWindowExW(0, L"STATIC", nullptr, 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr);
    if (!reply) return {};
    std::vector<BYTE> bytes;
    SetWindowLongPtrW(reply, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(&bytes));
    SetWindowLongPtrW(reply, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(receive));
    ChangeWindowMessageFilterEx(reply, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
    struct {
        EVERYTHING_IPC_QUERY2 header;
        wchar_t search[sizeof(L"file: dm:last60minutes") / sizeof(wchar_t)];
    } request = {{HandleToULong(reply), 1, 0, 0, EVERYTHING_IPC_ALLRESULTS, fields,
                  EVERYTHING_IPC_SORT_NAME_ASCENDING}, L"file: dm:last60minutes"};
    COPYDATASTRUCT data = {EVERYTHING_IPC_COPYDATA_QUERY2W, sizeof(request), &request};
    DWORD_PTR accepted = 0;
    if (SendMessageTimeoutW(server, WM_COPYDATA, reinterpret_cast<WPARAM>(reply),
            reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG | SMTO_BLOCK, 1000, &accepted) && accepted) {
        ULONGLONG deadline = GetTickCount64() + 3000;
        while (bytes.empty() && !stopping) {
            MSG msg;
            PeekMessageW(&msg, reply, WM_NULL, WM_NULL, PM_NOREMOVE); // dispatch sent messages
            if (!bytes.empty() || GetTickCount64() >= deadline) break;
            MsgWaitForMultipleObjectsEx(0, nullptr, 100, QS_SENDMESSAGE, MWMO_INPUTAVAILABLE);
        }
    }
    DestroyWindow(reply);
    return decode(bytes);
}
static Stamp lookup(const std::wstring &path, Stamp directWrite) {
    auto it = indexed.find(path);
    return it == indexed.end() ? directWrite : (std::max)(directWrite, it->second);
}

static BOOL CALLBACK findCommander(HWND window, LPARAM output) {
    DWORD pid;
    GetWindowThreadProcessId(window, &pid);
    wchar_t name[64];
    if (pid != GetCurrentProcessId() || !GetClassNameW(window, name, _countof(name)) ||
        wcscmp(name, L"TTOTAL_CMD") != 0) return TRUE;
    *reinterpret_cast<HWND *>(output) = window;
    return FALSE;
}

static DWORD_PTR panelInfo(HWND window, WPARAM id) {
    DWORD_PTR result = 0;
    SendMessageTimeoutW(window, WM_USER + 50, id, 0, SMTO_ABORTIFHUNG, 100, &result);
    return result;
}

struct Panel {
    HWND window = nullptr;
    DWORD_PTR side = 0;
    std::wstring path;
};
static bool samePath(const std::wstring &a, const std::wstring &b) {
    return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
}

static Panel activePanel() {
    Panel panel;
    EnumWindows(findCommander, reinterpret_cast<LPARAM>(&panel.window));
    if (!panel.window) return panel;
    panel.side = panelInfo(panel.window, 1000);
    if (panel.side != 1 && panel.side != 2) return panel;
    HWND label = reinterpret_cast<HWND>(panelInfo(panel.window, 8 + panel.side));
    wchar_t caption[32768];
    DWORD_PTR length = 0;
    if (label && SendMessageTimeoutW(label, WM_GETTEXT, _countof(caption),
            reinterpret_cast<LPARAM>(caption), SMTO_ABORTIFHUNG, 100, &length) && length) {
        std::wstring text(caption);
        size_t slash = text.rfind(L'\\');
        if (slash != std::wstring::npos) panel.path = key(text.substr(0, slash));
    }
    return panel;
}

static int colorBand(Stamp stamp) {
    int minutes = minutesSinceWrite(stamp);
    return minutes < 15 ? 0 : minutes < 60 ? 1 : 2;
}

static void CALLBACK update(PTP_CALLBACK_INSTANCE callback, void *module) {
    FreeLibraryWhenCallbackReturns(callback, static_cast<HMODULE>(module));
    Panel lastPanel;
    ULONGLONG nextPoll = 0;
    for (;;) {
        {
            std::lock_guard guard(cacheLock);
            if (stopping) { running = false; break; }
        }
        bool poll = GetTickCount64() >= nextPoll;
        Panel panel = poll ? activePanel() : lastPanel;
        bool switched = panel.side != lastPanel.side || !samePath(panel.path, lastPanel.path);
        if (poll) {
            Times next = readIndex();
            std::lock_guard guard(cacheLock);
            indexed.swap(next);
        }

        decltype(pending) batch;
        {
            std::lock_guard guard(cacheLock);
            pending.swap(batch);
            if (poll) {
                for (auto it = directorySamples.begin(); it != directorySamples.end();) {
                    if (samePath(it->second.containingDirectory, panel.path)) batch.insert(it->first);
                    else if (!it->second.queued && GetTickCount64() - it->second.checked > 60000) {
                        it = directorySamples.erase(it);
                        continue;
                    }
                    ++it;
                }
            }
        }
        bool repaint = false;
        for (const auto &path : batch) {
            if (stopping) break;
            Stamp directoryWrite = 0;
            Stamp directWrite = latestDirectFileWrite(path, directoryWrite);
            std::lock_guard guard(cacheLock);
            auto &entry = directorySamples[path];
            entry.latestLocalWrite = (std::max)(directoryWrite, directWrite);
            entry.checked = GetTickCount64();
            entry.queued = false;
            if (!panel.path.empty() && samePath(entry.containingDirectory, panel.path))
                repaint |= switched || entry.displayedBand != colorBand(lookup(path, entry.latestLocalWrite));
        }
        if (repaint && IsWindowEnabled(panel.window)) {
            Panel current = activePanel();
            if (samePath(current.path, panel.path) && current.side == panel.side &&
                !panelInfo(panel.window, 1004 + panel.side))
                PostMessageW(panel.window, WM_USER + 51, 540, 0); // cm_RereadSource
        }
        lastPanel = std::move(panel);
        if (poll) nextPoll = GetTickCount64() + refreshMs;
        std::unique_lock lock(cacheLock);
        auto now = GetTickCount64();
        wake.wait_for(lock, std::chrono::milliseconds(nextPoll > now ? nextPoll - now : 0),
                      [] { return stopping || !pending.empty(); });
    }
}

extern "C" void WINAPI ContentPluginUnloading() {
    std::lock_guard guard(cacheLock);
    stopping = true;
    wake.notify_one();
}
extern "C" int WINAPI ContentGetSupportedField(int index, char *name, char *units, int size) {
    if (index != 0) return 0;
    lstrcpynA(name, "Minutes since latest write", size);
    units[0] = 0;
    return 1; // ft_numeric_32
}

extern "C" int WINAPI ContentGetValueW(const wchar_t *path, int index, int, void *value, int, int) {
    if (index != 0) return -1;
    std::wstring folder = key(path);
    std::lock_guard guard(cacheLock);
    stopping = false;
    auto &entry = directorySamples[folder];
    if (entry.containingDirectory.empty()) entry.containingDirectory = folder.substr(0, folder.rfind(L'\\'));
    if (!entry.queued && (!entry.checked || GetTickCount64() - entry.checked >= refreshMs)) {
        entry.queued = true;
        pending.insert(folder);
        wake.notify_one();
    }
    if (entry.queued) {
        if (!running) {
            HMODULE module;
            if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                    reinterpret_cast<LPCWSTR>(&__ImageBase), &module)) {
                running = TrySubmitThreadpoolCallback(update, module, nullptr) != FALSE;
                if (!running) FreeLibrary(module);
            }
        }
    }
    Stamp stamp = lookup(folder, entry.latestLocalWrite);
    entry.displayedBand = colorBand(stamp);
    if (!stamp) return -3; // ft_fieldempty
    *static_cast<int *>(value) = minutesSinceWrite(stamp);
    return 1;
}

extern "C" int WINAPI ContentGetValue(const char *path, int index, int unit, void *value, int size, int flags) {
    int length = MultiByteToWideChar(CP_ACP, 0, path, -1, nullptr, 0);
    if (!length) return -2;
    std::vector<wchar_t> wide(length);
    if (!MultiByteToWideChar(CP_ACP, 0, path, -1, wide.data(), length)) return -2;
    return ContentGetValueW(wide.data(), index, unit, value, size, flags);
}

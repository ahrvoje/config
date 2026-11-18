#include <windows.h>
#include <algorithm>
#include <climits>
#include <future>
#include <map>
#include <mutex>
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
        while (bytes.empty()) {
            MSG msg;
            PeekMessageW(&msg, reply, WM_NULL, WM_NULL, PM_NOREMOVE); // dispatch sent messages
            if (!bytes.empty() || GetTickCount64() >= deadline) break;
            MsgWaitForMultipleObjectsEx(0, nullptr, 100, QS_SENDMESSAGE, MWMO_INPUTAVAILABLE);
        }
    }
    DestroyWindow(reply);
    return decode(bytes);
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
    static std::mutex cacheLock;
    static Times indexed, sampled;
    static ULONGLONG nextQuery = 0;
    std::lock_guard guard(cacheLock);
    if (GetTickCount64() >= nextQuery) {
        // Receive Everything's window messages on a worker, outside the caller's UI thread.
        indexed = std::async(std::launch::async, readIndex).get();
        sampled.clear();
        nextQuery = GetTickCount64() + refreshMs;
    }
    auto [it, inserted] = sampled.try_emplace(folder, 0);
    if (inserted) {
        Stamp directoryWrite = 0;
        Stamp directWrite = latestDirectFileWrite(folder, directoryWrite);
        it->second = (std::max)(directoryWrite, directWrite);
        auto hit = indexed.find(folder);
        if (hit != indexed.end()) it->second = (std::max)(it->second, hit->second);
    }
    Stamp stamp = it->second;
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

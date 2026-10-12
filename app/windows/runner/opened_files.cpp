#include "opened_files.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>

#include <filesystem>
#include <fstream>

#include "utils.h"

namespace {

// A calendar file, not a film.
constexpr size_t kMaxBytes = 10 * 1024 * 1024;

// Marks WM_COPYDATA from a second Famio start ("FAMI").
constexpr ULONG_PTR kOpenFile = 0x46414d49;

constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kProgId[] = L"Famio.ics";

std::wstring ExePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD n = ::GetModuleFileNameW(nullptr, path.data(),
                                         static_cast<DWORD>(path.size()));
    if (n == 0) return L"";
    if (n < path.size()) {
      path.resize(n);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

std::wstring ProcessPath(DWORD pid) {
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return L"";
  std::wstring path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  if (!::QueryFullProcessImageNameW(process, 0, path.data(), &size)) size = 0;
  ::CloseHandle(process);
  path.resize(size);
  return path;
}

bool SamePath(const std::wstring& a, const std::wstring& b) {
  return ::CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()),
                                b.c_str(), static_cast<int>(b.size()),
                                TRUE) == CSTR_EQUAL;
}

// A name for the folder Famio runs from: a Famio elsewhere (another version
// for testing) runs on its own.
std::wstring PathKey(std::wstring path) {
  ::CharLowerBuffW(path.data(), static_cast<DWORD>(path.size()));
  uint64_t hash = 14695981039346656037ull;
  for (const wchar_t c : path) {
    hash = (hash ^ static_cast<uint64_t>(c)) * 1099511628211ull;
  }
  wchar_t key[17];
  swprintf_s(key, L"%016llx", static_cast<unsigned long long>(hash));
  return key;
}

struct Search {
  std::wstring exe;
  HWND found = nullptr;
};

// The window of the other Famio from the same folder.
HWND FindFamioWindow(const std::wstring& exe) {
  Search search{exe};
  ::EnumWindows(
      [](HWND window, LPARAM param) -> BOOL {
        auto* search = reinterpret_cast<Search*>(param);
        wchar_t name[64];
        if (!::GetClassNameW(window, name, 64) ||
            wcscmp(name, kWindowClass) != 0) {
          return TRUE;
        }
        DWORD pid = 0;
        ::GetWindowThreadProcessId(window, &pid);
        if (pid == ::GetCurrentProcessId() ||
            !SamePath(ProcessPath(pid), search->exe)) {
          return TRUE;
        }
        search->found = window;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&search));
  return search.found;
}

std::wstring GetValue(const std::wstring& key, const wchar_t* name) {
  DWORD size = 0;
  if (::RegGetValueW(HKEY_CURRENT_USER, key.c_str(), name, RRF_RT_REG_SZ,
                     nullptr, nullptr, &size) != ERROR_SUCCESS) {
    return L"";
  }
  std::wstring value(size / sizeof(wchar_t), L'\0');
  if (::RegGetValueW(HKEY_CURRENT_USER, key.c_str(), name, RRF_RT_REG_SZ,
                     nullptr, value.data(), &size) != ERROR_SUCCESS) {
    return L"";
  }
  value.resize(wcsnlen(value.c_str(), value.size()));
  return value;
}

void SetValue(const std::wstring& key, const wchar_t* name,
              const std::wstring& value) {
  ::RegSetKeyValueW(HKEY_CURRENT_USER, key.c_str(), name, REG_SZ,
                    value.c_str(),
                    static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

}  // namespace

bool OpenedFiles::Receive(const std::wstring& path) {
  std::ifstream in(std::filesystem::path(path), std::ios::binary);
  if (!in) return false;
  std::vector<uint8_t> bytes;
  char buffer[64 * 1024];
  while (in) {
    in.read(buffer, sizeof buffer);
    bytes.insert(bytes.end(), buffer, buffer + in.gcount());
    if (bytes.size() > kMaxBytes) return false;
  }
  const size_t slash = path.find_last_of(L"\\/");
  const std::wstring name =
      slash == std::wstring::npos ? path : path.substr(slash + 1);
  pending_ = std::make_pair(Utf8FromUtf16(name.c_str()), std::move(bytes));
  return true;
}

void OpenedFiles::Register(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "famio/open_file",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "take") {
          result->NotImplemented();
          return;
        }
        if (!pending_) {
          result->Success();
          return;
        }
        flutter::EncodableMap file{
            {flutter::EncodableValue("name"),
             flutter::EncodableValue(pending_->first)},
            {flutter::EncodableValue("bytes"),
             flutter::EncodableValue(std::move(pending_->second))},
        };
        pending_.reset();
        result->Success(flutter::EncodableValue(std::move(file)));
      });
}

void OpenedFiles::Unregister() { channel_ = nullptr; }

bool OpenedFiles::HandleCopyData(const COPYDATASTRUCT* data) {
  if (!data || data->dwData != kOpenFile) return false;
  if (data->cbData > 0 && data->lpData) {
    const std::wstring path(static_cast<const wchar_t*>(data->lpData),
                            data->cbData / sizeof(wchar_t));
    if (Receive(path) && channel_) channel_->InvokeMethod("opened", nullptr);
  }
  return true;
}

std::wstring OpenedFileArgument() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (!argv) return L"";
  std::wstring file;
  for (int i = 1; i < argc; i++) {
    if (argv[i][0] != L'-') {
      file = argv[i];
      break;
    }
  }
  ::LocalFree(argv);
  return file;
}

bool HandToRunningFamio(const std::wstring& file) {
  const std::wstring exe = ExePath();
  if (exe.empty()) return false;
  // Held by the first Famio until it ends.
  HANDLE mutex = ::CreateMutexW(nullptr, FALSE,
                                (L"Local\\Famio-" + PathKey(exe)).c_str());
  if (!mutex || ::GetLastError() != ERROR_ALREADY_EXISTS) return false;
  // The other Famio may still be starting: up to five seconds for its window.
  for (int i = 0; i < 50; i++) {
    if (HWND window = FindFamioWindow(exe)) {
      DWORD pid = 0;
      ::GetWindowThreadProcessId(window, &pid);
      // This start came from the user, so it may hand the focus on.
      ::AllowSetForegroundWindow(pid);
      COPYDATASTRUCT data{kOpenFile,
                          static_cast<DWORD>(file.size() * sizeof(wchar_t)),
                          const_cast<wchar_t*>(file.c_str())};
      ::SendMessageTimeoutW(window, WM_COPYDATA, 0,
                            reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG,
                            5000, nullptr);
      return true;
    }
    ::Sleep(100);
  }
  return false;
}

void RegisterFileTypes() {
  const std::wstring exe = ExePath();
  if (exe.empty()) return;
  const std::wstring command = L"\"" + exe + L"\" \"%1\"";
  const std::wstring classes = L"Software\\Classes\\";
  const std::wstring prog_id = classes + kProgId;
  // Moved or newly installed Famio only.
  if (GetValue(prog_id + L"\\shell\\open\\command", nullptr) == command) {
    return;
  }
  SetValue(prog_id, nullptr, L"iCalendar");
  SetValue(prog_id + L"\\DefaultIcon", nullptr, exe + L",0");
  SetValue(prog_id + L"\\shell\\open\\command", nullptr, command);
  // Next to the other apps for .ics, not instead of them.
  ::RegSetKeyValueW(HKEY_CURRENT_USER,
                    (classes + L".ics\\OpenWithProgids").c_str(), kProgId,
                    REG_NONE, nullptr, 0);
  const std::wstring app = classes + L"Applications\\famio.exe";
  SetValue(app, L"FriendlyAppName", L"Famio");
  SetValue(app + L"\\shell\\open\\command", nullptr, command);
  SetValue(app + L"\\SupportedTypes", L".ics", L"");
  ::SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
}

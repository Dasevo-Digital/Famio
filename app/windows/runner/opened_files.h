#ifndef RUNNER_OPENED_FILES_H_
#define RUNNER_OPENED_FILES_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// Calendar files opened with Famio ("Öffnen mit" in the Explorer) for the
// channel `famio/open_file`: kept until Dart takes them.
class OpenedFiles {
 public:
  // The file Famio was started with, or one a second start handed over.
  // Returns false when it cannot be read.
  bool Receive(const std::wstring& path);

  void Register(flutter::BinaryMessenger* messenger);
  void Unregister();

  // WM_COPYDATA from a second start (see HandToRunningFamio). Returns false
  // for other data.
  bool HandleCopyData(const COPYDATASTRUCT* data);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::optional<std::pair<std::string, std::vector<uint8_t>>> pending_;
};

// The file in Famio's command line ("famio.exe" "C:\...\termine.ics"), or
// an empty string.
std::wstring OpenedFileArgument();

// One Famio per installation: when this one already runs, it gets |file|
// (may be empty) and comes to the front, and this start can end.
bool HandToRunningFamio(const std::wstring& file);

// Lists Famio under "Öffnen mit" for calendar files, for the current user
// and without changing the default app.
void RegisterFileTypes();

#endif  // RUNNER_OPENED_FILES_H_

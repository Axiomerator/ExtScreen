#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const HANDLE instance_mutex =
      CreateMutexW(nullptr, FALSE, L"Local\\ExtScreenFlutterDashboard");
  if (instance_mutex == nullptr) {
    return EXIT_FAILURE;
  }
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    for (int attempt = 0; attempt < 100; ++attempt) {
      const HWND window = FindWindowW(L"ExtScreenFlutterDashboard", nullptr);
      if (window != nullptr) {
        DWORD process_id = 0;
        GetWindowThreadProcessId(window, &process_id);
        AllowSetForegroundWindow(process_id);
        PostMessageW(window, WM_APP + 102, 0, 0);
        break;
      }
      Sleep(20);
    }
    CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(56, 56);
  Win32Window::Size size(1080, 760);
  if (!window.Create(L"ExtScreen", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 崩溃自动恢复（兜底）：进程被强杀时由 WER 重启本应用（带 --crashed），
  // Dart 侧据此跳过自动登录防循环、显示恢复提示；会话数据已持久化
  //（last_session），重启即恢复现场。根因排查见
  // docs/已知问题-Windows窗口resize崩溃.md。
  ::RegisterApplicationRestart(L"--crashed", RESTART_NO_PATCH);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // 渲染后端固定用 Skia（禁用 Impeller）。注意：这与本项目窗口 resize 被强杀
  // 的问题无关——那条根因在引擎无障碍桥（见
  // docs/已知问题-Windows窗口resize崩溃.md），上面曾引用的 issue 也都不是该崩溃；
  // 此处保留仅作为渲染后端选择。
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"\u8BFE\u821F", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

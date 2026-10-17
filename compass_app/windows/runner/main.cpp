#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 单实例：命名互斥量判定"是否已有本应用在跑"。已有实例时，把它的窗口
  // 唤回前台（可能正收在托盘里）后直接退出，不再开第二个窗口/进程。
  // 互斥量句柄故意保留到进程结束：进程一退出，句柄与对象自动释放。
  HANDLE single_instance_mutex = ::CreateMutexW(
      nullptr, TRUE, L"Local\\KeZhou.Compass.SingleInstance");
  const bool already_running = single_instance_mutex != nullptr &&
                               ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (already_running) {
    // 首次启动可能还没建好窗口：短暂等待，避免"第二次双击看起来没反应"。
    HWND existing_window = nullptr;
    for (int attempt = 0; attempt < 40 && existing_window == nullptr;
         ++attempt) {
      existing_window = ::FindWindowW(kKezhouWindowClassName, nullptr);
      if (existing_window == nullptr) {
        ::Sleep(50);  // 最多等约 2 秒
      }
    }
    if (existing_window != nullptr) {
      ::PostMessageW(existing_window, kKezhouActivateMessage, 0, 0);
    }
    ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

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
  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <shellapi.h>

#include <memory>

#include "win32_window.h"

// 窗口类名（与 win32_window.cpp 里的 kWindowClassName 保持一致）：
// main.cpp 靠它在单实例启动时找回已经运行的窗口。
constexpr const wchar_t kKezhouWindowClassName[] = L"KeZhou.Compass.MainWindow";

// 自定义窗口消息：第二个进程把已有窗口唤回前台 / 托盘图标回调。
constexpr UINT kKezhouActivateMessage = WM_APP + 1;
constexpr UINT kKezhouTrayMessage = WM_APP + 2;

// 托盘右键菜单的命令 ID。
constexpr UINT kKezhouMenuShow = 9001;
constexpr UINT kKezhouMenuQuit = 9002;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 把窗口从"隐藏/最小化"状态唤回前台。
  void ShowAndFocus();

  // 托盘图标：窗口隐藏时挂上，窗口重新显示时摘掉。
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  LRESULT HandleTrayMessage(LPARAM const lparam);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 首次显示过之后，再隐藏才挂托盘图标（避免启动瞬间闪一下图标）。
  bool window_shown_once_ = false;
  bool tray_icon_added_ = false;

  // 资源管理器重启后需要重新挂回托盘图标。
  UINT taskbar_created_message_ = 0;
  NOTIFYICONDATAW tray_icon_data_{};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
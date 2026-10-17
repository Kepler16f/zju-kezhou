#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

// 托盘提示与菜单文案（用 \u 转义，不受源文件编码影响）。
constexpr const wchar_t kTrayTip[] = L"\u8BFE\u821F";                    // 课舟
constexpr const wchar_t kMenuShowText[] = L"\u663E\u793A\u7A97\u53E3";   // 显示窗口
constexpr const wchar_t kMenuQuitText[] = L"\u9000\u51FA\u8BFE\u821F";   // 退出课舟

// 托盘用小图标：优先取应用图标，取不到时退回系统默认图标。
HICON LoadTrayIcon() {
  HICON icon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  if (icon == nullptr) {
    icon = ::LoadIconW(nullptr, IDI_APPLICATION);
  }
  return icon;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {
  // 资源管理器重启后会广播 "TaskbarCreated"，届时需要重挂托盘图标。
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // 对齐 PiliPlus：窗口显示由 Dart 侧 window_manager 接管
  //（引擎首帧回调显示路径与 window_manager 的异步显示冲突）
  // flutter_controller_->engine()->SetNextFrameCallback([&]() {
  //   this->Show();
  // });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowAndFocus() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || !::IsWindow(hwnd)) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::BringWindowToTop(hwnd);
  ::SetForegroundWindow(hwnd);
}

void FlutterWindow::AddTrayIcon() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || tray_icon_added_) {
    return;
  }

  NOTIFYICONDATAW data{};
  data.cbSize = static_cast<DWORD>(sizeof(NOTIFYICONDATAW));
  data.hWnd = hwnd;
  data.uID = 1;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kKezhouTrayMessage;
  data.hIcon = LoadTrayIcon();
  lstrcpynW(data.szTip, kTrayTip, ARRAYSIZE(data.szTip));

  tray_icon_data_ = data;
  if (::Shell_NotifyIconW(NIM_ADD, &tray_icon_data_)) {
    tray_icon_added_ = true;
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  ::Shell_NotifyIconW(NIM_DELETE, &tray_icon_data_);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  ::AppendMenuW(menu, MF_STRING, kKezhouMenuShow, kMenuShowText);
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kKezhouMenuQuit, kMenuQuitText);

  POINT cursor{};
  ::GetCursorPos(&cursor);

  // 弹菜单前必须把窗口设为前台，否则点菜单外部时菜单不会消失。
  ::SetForegroundWindow(hwnd);
  ::TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, cursor.x, cursor.y,
                   0, hwnd, nullptr);
  // 官方文档要求：TrackPopupMenu 之后补一条空消息，菜单才能正常收起。
  ::PostMessageW(hwnd, WM_NULL, 0, 0);

  ::DestroyMenu(menu);
}

LRESULT FlutterWindow::HandleTrayMessage(LPARAM const lparam) {
  switch (LOWORD(lparam)) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      ShowAndFocus();
      break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowTrayMenu();
      break;
    default:
      break;
  }
  return 0;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 单实例：第二次启动的进程发来唤醒消息（窗口可能正收在托盘里）。
  if (message == kKezhouActivateMessage) {
    ShowAndFocus();
    return 0;
  }

  // 托盘图标回调（经典语义：lparam 低字是鼠标消息）。
  if (message == kKezhouTrayMessage) {
    return HandleTrayMessage(lparam);
  }

  if (message == WM_COMMAND) {
    const UINT command_id = LOWORD(wparam);
    if (command_id == kKezhouMenuShow) {
      ShowAndFocus();
      return 0;
    }
    if (command_id == kKezhouMenuQuit) {
      RemoveTrayIcon();
      ::DestroyWindow(hwnd);
      return 0;
    }
  }

  // 首次显示后再隐藏 = 用户点了关闭且 Dart 侧选择"收起到托盘"。
  if (message == WM_SHOWWINDOW) {
    if (wparam == TRUE) {
      window_shown_once_ = true;
      RemoveTrayIcon();
    } else if (window_shown_once_) {
      AddTrayIcon();
    }
  }

  // 资源管理器（explorer.exe）重启会清空托盘区，这里把图标挂回去。
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_ &&
      tray_icon_added_) {
    tray_icon_added_ = false;
    AddTrayIcon();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }

    if (message == WM_FONTCHANGE) {
      flutter_controller_->engine()->ReloadSystemFonts();
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
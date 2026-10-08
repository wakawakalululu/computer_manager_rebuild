#include "child_window_style.h"

#include <flutter/flutter_engine.h>
#include <flutter/flutter_view_controller.h>
#include <shellscalingapi.h>
#include <windows.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "flutter_plugin_registrar.h"

namespace {

// 子引擎未使用 place 通道时的默认形态。
// ⚠ 这里原来写着"还原参考实现…窄长条(200x104)"，**那句注释是错的**：
//   2026-10-08 用 PrintWindow 直取正在运行的参考实现量到，它的加速球窗口是
//   **86x86 逻辑像素的圆**（`CLASS=FlutterMultiWindow`、`TITLE=accelerationBall`，
//   物理 108x108 @ dpi 120），不是窄长条。改成方形与之对齐；
//   托盘菜单/加速卡仍各自用 place 报自己的尺寸（见 #106）。
constexpr int kPanelLogicalWidth = 86;
constexpr int kPanelLogicalHeight = 86;
constexpr int kMarginRight = 24;
constexpr int kMarginTop = 24;

constexpr int kDefaultDpi = 96;

// ── 通道与文本协议 ─────────────────────────────────────────────────────────
// runner 只链接 flutter_wrapper_app，里面没有 PluginRegistrar / MethodChannel
// 的实现（它们在 flutter_wrapper_plugin，且与该 lib 共用 core 源文件，强行再链
// 会重复符号）。所以这里只用 C API 拿 messenger，消息体走 Dart 侧 StringCodec
//（= 裸 UTF-8 字节），字段用 '|' 分隔：
//   请求  place|槽位X|槽位Y|槽位W|槽位H|逻辑宽|逻辑高|菜单语义(1/0)|标题
//   应答  placed|X|Y|宽|高|缩放|菜单语义或    err|原因
constexpr char kChannelName[] = "cm/window_native";
constexpr char kFieldSep = '|';
constexpr char kPlaceMethod[] = "place";
constexpr char kRectMethod[] = "rect";
constexpr size_t kPlaceFieldCount = 9;

std::wstring Utf16(const std::string& utf8) {
  const int len =
      ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (len <= 1) return std::wstring();
  std::wstring out(static_cast<size_t>(len - 1), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &out[0], len);
  return out;
}

// _HAS_EXCEPTIONS=0，所以不用 std::stoi（它靠异常报错），自己看 endptr。
bool ParseNumber(const std::string& text, long* out) {
  if (text.empty()) return false;
  char* end = nullptr;
  const long value = std::strtol(text.c_str(), &end, 10);
  if (end == text.c_str()) return false;
  while (*end == ' ' || *end == '\t') ++end;
  if (*end != '\0') return false;
  *out = value;
  return true;
}

// 按 '|' 切成最多 count 段，最后一段保留原文（标题里可能有 '|'）。
std::vector<std::string> SplitFields(const std::string& line, size_t count) {
  std::vector<std::string> fields;
  size_t start = 0;
  while (fields.size() + 1 < count) {
    const size_t sep = line.find(kFieldSep, start);
    if (sep == std::string::npos) break;
    fields.push_back(line.substr(start, sep - start));
    start = sep + 1;
  }
  fields.push_back(line.substr(start));
  return fields;
}

struct ChildHook {
  WNDPROC original_proc = nullptr;
  // place 里声明的菜单语义：显示时尝试置前，失焦即收起。
  // 不置前就永远收不到 WM_ACTIVATE(WA_INACTIVE)，收起也就无从触发。
  bool is_menu = false;
};

// place 回调跑在子引擎自己的平台线程（desktop_multi_window 建引擎时用
// RunOnSeparateThread），而窗口过程跑在创建 HWND 的主线程，两个线程都会碰这张表。
std::mutex& HooksMutex() {
  static std::mutex mutex;
  return mutex;
}

std::map<HWND, ChildHook>& ChildHooks() {
  static std::map<HWND, ChildHook> hooks;
  return hooks;
}

LRESULT CALLBACK ChildWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  WNDPROC original = nullptr;
  bool is_menu = false;
  {
    const std::lock_guard<std::mutex> lock(HooksMutex());
    const auto it = ChildHooks().find(hwnd);
    if (it != ChildHooks().end()) {
      original = it->second.original_proc;
      is_menu = it->second.is_menu;
    }
  }
  if (original == nullptr) {
    return ::DefWindowProcW(hwnd, message, wparam, lparam);
  }
  if (is_menu && message == WM_SHOWWINDOW && wparam != 0) {
    // 菜单要能“点到别处就收起”，前提是它拿到前台。这里只是尽力而为：
    // 被系统的 foreground 锁拦下也不会报错，菜单照样能点，只是点外面不收起。
    ::SetForegroundWindow(hwnd);
  }
  if (is_menu && message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) {
    // 菜单语义：点到窗口之外（桌面、其它程序）就收起。子引擎里既没有
    // window_manager 也拿不到焦点事件，收起只能在原生侧直接隐藏。
    ::ShowWindow(hwnd, SW_HIDE);
  }
  const LRESULT result =
      ::CallWindowProcW(original, hwnd, message, wparam, lparam);
  if (message == WM_DESTROY) {
    const std::lock_guard<std::mutex> lock(HooksMutex());
    // 系统会复用 HWND，留着旧记录会误伤下一个窗口
    ChildHooks().erase(hwnd);
  }
  return result;
}

void SubclassWindowProc(HWND hwnd) {
  const std::lock_guard<std::mutex> lock(HooksMutex());
  auto& hooks = ChildHooks();
  if (hooks.find(hwnd) != hooks.end()) return;
  auto* original = reinterpret_cast<WNDPROC>(::SetWindowLongPtrW(
      hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(&ChildWindowProc)));
  if (original == nullptr || original == &ChildWindowProc) return;
  hooks[hwnd] = ChildHook{original, false};
}

// 按托盘槽位（物理像素）摆放菜单：右缘对齐槽位右缘、上沿贴着槽位上沿。
// DPI 换算与工作区夹取都在原生侧 —— 子引擎里没有 screen_retriever /
// window_manager 的 registrar，算不出目标显示器的缩放，也拿不到工作区。
std::string HandlePlaceRequest(HWND hwnd, const std::vector<std::string>& f) {
  long slot_x = 0;
  long slot_y = 0;
  long slot_w = 0;
  long slot_h = 0;
  long logical_w = kPanelLogicalWidth;
  long logical_h = kPanelLogicalHeight;
  long popup = 0;
  if (!ParseNumber(f[1], &slot_x) || !ParseNumber(f[2], &slot_y) ||
      !ParseNumber(f[3], &slot_w) || !ParseNumber(f[4], &slot_h) ||
      !ParseNumber(f[5], &logical_w) || !ParseNumber(f[6], &logical_h) ||
      !ParseNumber(f[7], &popup)) {
    return "err|place 参数不是整数";
  }

  const HMONITOR monitor = ::MonitorFromPoint(POINT{LONG(slot_x), LONG(slot_y)},
                                              MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    return "err|取不到托盘槽位所在的显示器";
  }

  UINT dpi_x = kDefaultDpi;
  UINT dpi_y = kDefaultDpi;
  ::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
  if (dpi_x == 0) dpi_x = kDefaultDpi;
  const double scale = static_cast<double>(dpi_x) / kDefaultDpi;
  const int width = static_cast<int>(logical_w * scale + 0.5);
  const int height = static_cast<int>(logical_h * scale + 0.5);

  // 越界先贴着工作区收；上方放不下（托盘在屏幕下沿，正常都在上方）就翻到槽位下方。
  const RECT work = info.rcWork;
  int left = static_cast<int>(slot_x) + static_cast<int>(slot_w) - width;
  int top = static_cast<int>(slot_y) - height;
  if (left + width > work.right) left = work.right - width;
  if (left < work.left) left = work.left;
  if (top < work.top) top = static_cast<int>(slot_y) + static_cast<int>(slot_h);
  if (top + height > work.bottom) top = work.bottom - height;

  // 别把菜单摆在指针底下：托盘在屏幕下沿时弹出位置正好是鼠标所在的那块，
  // 用户第一下点击会打在菜单上（点哪条都一样，等于随机选项）。命中就把菜单
  // 沿槽位水平方向推开——推不開（屏幕就那么宽）才认了，不做上下翻转免得更难预期。
  {
    POINT cursor{};
    if (::GetCursorPos(&cursor)) {
      const bool under_cursor =
          cursor.x >= left && cursor.x < left + width && cursor.y >= top &&
          cursor.y < top + height;
      if (under_cursor) {
        int shifted = left;
        if (cursor.x >= left + width / 2) {
          shifted = left - width; // 指针在右半边：菜单往左让
        } else {
          shifted = left + width; // 指针在左半边：菜单往右让
        }
        // 让完仍要留在工作区内，否则这次让位比压着指针更糟
        if (shifted >= work.left && shifted + width <= work.right) {
          left = shifted;
        }
      }
    }
  }

  // SWP_NOACTIVATE：菜单窗口不能抢焦点，否则主窗口失焦、任务栏闪一下。
  if (!::SetWindowPos(hwnd, HWND_TOPMOST, left, top, width, height,
                      SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
    return "err|SetWindowPos 失败 winErr=" +
           std::to_string(static_cast<unsigned long>(::GetLastError()));
  }

  const bool is_menu = popup != 0;
  {
    const std::lock_guard<std::mutex> lock(HooksMutex());
    const auto hook = ChildHooks().find(hwnd);
    if (hook != ChildHooks().end()) hook->second.is_menu = is_menu;
  }
  if (!f[8].empty()) {
    ::SetWindowTextW(hwnd, Utf16(f[8]).c_str());
  }

  char reply[160];
  const int written = ::snprintf(
      reply, sizeof(reply), "placed|%d|%d|%d|%d|%.4f|%d", left, top, width,
      height, scale, is_menu ? 1 : 0);
  if (written <= 0) return "err|应答构造失败";
  return std::string(reply, static_cast<size_t>(written));
}

// 请求  rect      应答  rect|X|Y|宽|高（物理像素）
//
// 子引擎里没有 screen_retriever / window_manager 的 registrar，窗口自己的屏幕
// 矩形只有原生知道。加速球的展开卡要贴着球摆，就得靠这条把矩形的真实位置
// 交给主引擎（Dart 侧算不出：球可能被拖过、也可能在第二块高 DPI 屏上）。
std::string HandleRectRequest(HWND hwnd) {
  RECT r{};
  if (!::GetWindowRect(hwnd, &r)) {
    return "err|GetWindowRect 失败 winErr=" +
           std::to_string(static_cast<unsigned long>(::GetLastError()));
  }
  char reply[96];
  const int written = ::snprintf(reply, sizeof(reply), "rect|%d|%d|%d|%d",
                                 static_cast<int>(r.left), static_cast<int>(r.top),
                                 static_cast<int>(r.right - r.left),
                                 static_cast<int>(r.bottom - r.top));
  if (written <= 0) return "err|应答构造失败";
  return std::string(reply, static_cast<size_t>(written));
}

std::string DispatchRequest(HWND hwnd, const std::string& request) {
  // 空字节不是文本协议的一部分，出现即说明 Dart 侧 codec 用错了
  if (request.find('\0') != std::string::npos) return "err|消息体含空字节";
  const auto fields = SplitFields(request, kPlaceFieldCount);
  if (fields.empty()) return "err|空请求";
  if (fields[0] == kRectMethod) return HandleRectRequest(hwnd);
  if (fields[0] != kPlaceMethod) return "err|未知方法 " + fields[0];
  if (fields.size() < kPlaceFieldCount) return "err|字段不足";
  return HandlePlaceRequest(hwnd, fields);
}

void HandleWindowNativeMessage(FlutterDesktopMessengerRef messenger,
                               const FlutterDesktopMessage* message,
                               void* user_data) {
  if (messenger == nullptr || message == nullptr) return;
  auto* hwnd = static_cast<HWND>(user_data);
  if (!::IsWindow(hwnd)) return;
  std::string request;
  if (message->message != nullptr && message->message_size > 0) {
    request.assign(reinterpret_cast<const char*>(message->message),
                   message->message_size);
  }
  const std::string reply = DispatchRequest(hwnd, request);
  // 只在对方用 send() 等结果时应答；response_handle 用完即废
  if (message->response_handle != nullptr) {
    ::FlutterDesktopMessengerSendResponse(
        messenger, message->response_handle,
        reinterpret_cast<const uint8_t*>(reply.data()), reply.size());
  }
}

void StripToPanelWindow(HWND hwnd) {
  // 去掉标题栏/边框/系统菜单 —— Flutter 内容铺满整个窗口
  const LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  ::SetWindowLongPtr(hwnd, GWL_STYLE,
                     style & ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
                               WS_MAXIMIZEBOX | WS_SYSMENU));
  // 置顶 + 不占任务栏与 Alt+Tab
  const LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ::SetWindowLongPtr(hwnd, GWL_EXSTYLE,
                     ex_style | WS_EX_TOPMOST | WS_EX_TOOLWINDOW);
}

void ApplyDefaultPanelGeometry(HWND hwnd) {
  // SetWindowPos 用物理像素，而 Flutter 侧按逻辑像素布局；按屏幕 DPI 换算，
  // 保证 125%/150% 缩放下面板内容与尺寸一致（否则内容会溢出小一号的窗口）。
  HDC dc = ::GetDC(nullptr);
  const int dpi = dc != nullptr ? ::GetDeviceCaps(dc, LOGPIXELSX) : kDefaultDpi;
  if (dc != nullptr) ::ReleaseDC(nullptr, dc);
  const double scale = dpi > 0 ? static_cast<double>(dpi) / kDefaultDpi : 1.0;

  const int width = static_cast<int>(kPanelLogicalWidth * scale + 0.5);
  const int height = static_cast<int>(kPanelLogicalHeight * scale + 0.5);
  const int margin_right = static_cast<int>(kMarginRight * scale + 0.5);
  const int margin_top = static_cast<int>(kMarginTop * scale + 0.5);

  RECT work = {0, 0, 1280, 720};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  ::SetWindowPos(hwnd, HWND_TOPMOST,
                 static_cast<int>(work.right) - width - margin_right,
                 static_cast<int>(work.top) + margin_top, width, height,
                 SWP_FRAMECHANGED | SWP_NOACTIVATE);

  ::SetWindowText(hwnd, Utf16("PC Manager · 资源悬浮窗").c_str());
}

}  // namespace

void OnChildWindowCreated(void* flutter_view_controller) {
  if (flutter_view_controller == nullptr) return;
  auto* controller =
      static_cast<flutter::FlutterViewController*>(flutter_view_controller);
  if (controller->view() == nullptr) return;

  // view 的 HWND 是挂在顶层窗口下的子视图，取根窗口即子窗口本身
  HWND hwnd = ::GetAncestor(controller->view()->GetNativeWindow(), GA_ROOT);
  if (hwnd == nullptr) return;

  StripToPanelWindow(hwnd);
  ApplyDefaultPanelGeometry(hwnd);
  SubclassWindowProc(hwnd);

  auto* engine = controller->engine();
  if (engine == nullptr) return;
  // 插件名随便取：引擎会给陌生的名字现造一个 registrar，messenger 与子引擎同生命周期
  FlutterDesktopPluginRegistrarRef registrar =
      engine->GetRegistrarForPlugin("CmChildWindowNative");
  if (registrar == nullptr) return;
  FlutterDesktopMessengerRef messenger =
      FlutterDesktopPluginRegistrarGetMessenger(registrar);
  if (messenger == nullptr) return;
  // user_data 里只放 HWND 这个值，不涉及所有权；子引擎销毁时回调随之失效
  ::FlutterDesktopMessengerSetCallback(messenger, kChannelName,
                                       &HandleWindowNativeMessage, hwnd);
}

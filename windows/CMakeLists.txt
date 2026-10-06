# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(computer_manager LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "computer_manager")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# ── flutter_rust_bridge：构建 rust_lib.dll 并随 bundle 分发 ──────────────────
# VS 生成器是多配置的（CMAKE_BUILD_TYPE 为空），若按配置切换 cargo profile 会
# 让 install 路径随配置变化而难以确定；这里统一产出 release 版 rust_lib.dll，
# Debug/Profile/Release 三种配置都复用它（GUI 侧只是调用 FFI，行为一致）。
set(RUST_DIR "${CMAKE_SOURCE_DIR}/../rust")
set(RUST_LIB_OUTPUT "${RUST_DIR}/target/release/rust_lib.dll")

add_custom_target(rust_lib ALL
  COMMAND cargo build --lib --release
  WORKING_DIRECTORY "${RUST_DIR}"
  COMMENT "构建 rust 核心 rust_lib.dll（cargo build --lib --release）"
  BYPRODUCTS "${RUST_LIB_OUTPUT}")

install(FILES "${RUST_LIB_OUTPUT}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# ── 常驻组件：cm_agent.exe / cm_keep_alive.exe ───────────────────────────────
# 参考实现进程模型（REVERSE_REPORT §2）：ComputerKeepAlive 服务守护常驻 agent，
# agent 以 exe 同目录为路径基准读 config.ini、写 logs\、缓存 agent_id，
# 所以两个 bin 必须与 computer_manager.exe 落在同一目录，不能只留在 target/。
set(RUST_AGENT_OUTPUT "${RUST_DIR}/target/release/cm_agent.exe")
set(RUST_KEEP_ALIVE_OUTPUT "${RUST_DIR}/target/release/cm_keep_alive.exe")

add_custom_target(cm_resident ALL
  COMMAND cargo build --release --bin cm_agent --bin cm_keep_alive
  WORKING_DIRECTORY "${RUST_DIR}"
  COMMENT "构建常驻组件 cm_agent.exe / cm_keep_alive.exe"
  BYPRODUCTS "${RUST_AGENT_OUTPUT}" "${RUST_KEEP_ALIVE_OUTPUT}")

install(FILES "${RUST_AGENT_OUTPUT}" "${RUST_KEEP_ALIVE_OUTPUT}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# 配置模板：agent/keep_alive 以 exe 同目录的 config.ini / keep_alive.ini 为准
#（仓库不硬编码网关域名，模板里只有占位符）。
# 用 install(FILES) 而不是自写 CODE：file(INSTALL) 只在目标不存在或比模板旧时才拷，
# 运维改过的真实配置时间戳更新，因此不会被每次构建覆盖。
# 注意：install(CODE) 里拿不到已求值的安装目录（CMAKE_INSTALL_PREFIX 是
# $<TARGET_FILE_DIR:...> 生成器表达式原样入串），所以不要在这里写 CODE。
install(FILES "${CMAKE_SOURCE_DIR}/../deploy/config.ini"
             "${CMAKE_SOURCE_DIR}/../deploy/keep_alive.ini"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# ── 清理规则库：rules/*.ini 随 bundle 分发 ────────────────────────────────────
# 深度清理按「exe 同目录 rules\<name>.ini」定位规则（rust/src/api/disk_scan.rs 的
# find_rule_file），只拷了 exe 和 config.ini 的话，打包版这一页永远停在
# 「未找到规则文件 DeepCleanCacheConfig.ini」。
# rules/*.ini 是参考实现安装副本里的素材，按 .gitignore 不入库（本地用
# scripts/fetch_assets.ps1 恢复），所以这里必须容错：素材缺失时跳过，
# clean-room 分支照样能构建，只是这一页给出「未找到规则文件」的空态。
set(RULES_DIR "${CMAKE_SOURCE_DIR}/../rules")
if(EXISTS "${RULES_DIR}")
  install(DIRECTORY "${RULES_DIR}/"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/rules"
    COMPONENT Runtime
    FILES_MATCHING PATTERN "*.ini")
endif()

# SPDX-License-Identifier: GPL-3.0-or-later
cmake_minimum_required(VERSION 3.24)
project(mirrorme_receiver VERSION 1.0.0 LANGUAGES C CXX)

if(NOT WIN32 OR NOT MINGW OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "Use a 64-bit MinGW-w64 UCRT compiler (not MSVC or MSVCRT).")
endif()

set(UXPLAY_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/receiver/libuxplay" CACHE PATH "Pinned, patched libuxplay source")
set(RECEIVER_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/receiver/sdk/ucrt64" CACHE PATH "Isolated UCRT development files")
set(RECEIVER_DNSSD_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/receiver/sdk/bonjour" CACHE PATH "Pinned Bonjour API header")
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(BUILD_SHARED_LIBS OFF)

foreach(header
    "${UXPLAY_SOURCE_DIR}/uxplay_api.h"
    "${RECEIVER_SDK_DIR}/include/gstreamer-1.0/gst/gst.h"
    "${RECEIVER_SDK_DIR}/include/glib-2.0/glib.h"
    "${RECEIVER_SDK_DIR}/lib/glib-2.0/include/glibconfig.h"
    "${RECEIVER_SDK_DIR}/include/plist/plist.h"
    "${RECEIVER_SDK_DIR}/include/openssl/opensslv.h"
    "${RECEIVER_DNSSD_INCLUDE_DIR}/dns_sd.h")
  if(NOT EXISTS "${header}")
    message(FATAL_ERROR "Missing development dependency: ${header}. Run scripts\\build-receiver.ps1 to restore the pinned local SDK.")
  endif()
endforeach()
file(STRINGS "${UXPLAY_SOURCE_DIR}/uxplay_api.h" lifecycle_api REGEX "uxplay_stop_requested")
if(NOT lifecycle_api)
  message(FATAL_ERROR "The MirrorMe lifecycle patch is missing. Run scripts\\build-receiver.ps1, not the pristine upstream CMake build.")
endif()

add_library(receiver_dependencies INTERFACE)
target_include_directories(receiver_dependencies INTERFACE
  "${RECEIVER_SDK_DIR}/include"
  "${RECEIVER_SDK_DIR}/include/gstreamer-1.0"
  "${RECEIVER_SDK_DIR}/include/glib-2.0"
  "${RECEIVER_SDK_DIR}/lib/glib-2.0/include"
  "${RECEIVER_DNSSD_INCLUDE_DIR}"
)
foreach(library gstreamer-1.0 gstapp-1.0 gstbase-1.0 gstvideo-1.0 gobject-2.0 glib-2.0 plist-2.0 crypto)
  set(import_library "${RECEIVER_SDK_DIR}/lib/lib${library}.dll.a")
  if(NOT EXISTS "${import_library}")
    message(FATAL_ERROR "Missing import library: ${import_library}")
  endif()
  target_link_libraries(receiver_dependencies INTERFACE "${import_library}")
endforeach()

add_compile_definitions(
  MIRRORME_RECEIVER WINVER=0x0A00 _WIN32_WINNT=0x0A00
  OPENSSL_API_COMPAT=0x10101000L
)
add_subdirectory("${UXPLAY_SOURCE_DIR}/lib/llhttp" llhttp)
add_subdirectory("${UXPLAY_SOURCE_DIR}/lib/playfair" playfair)

file(GLOB airplay_sources CONFIGURE_DEPENDS "${UXPLAY_SOURCE_DIR}/lib/*.c")
add_library(airplay STATIC ${airplay_sources})
target_include_directories(airplay PRIVATE
  "${UXPLAY_SOURCE_DIR}" "${UXPLAY_SOURCE_DIR}/lib/playfair" "${UXPLAY_SOURCE_DIR}/lib/llhttp")
target_compile_definitions(airplay PRIVATE
  STANDALONE __STDC_CONSTANT_MACROS __STDC_LIMIT_MACROS TARGET_POSIX
  _REENTRANT _LARGEFILE64_SOURCE _FILE_OFFSET_BITS=64 NOHOLD PLIST_210 PLIST_230)
target_link_libraries(airplay PUBLIC receiver_dependencies playfair llhttp pthread wsock32 iphlpapi ws2_32)

add_library(renderers STATIC
  "${CMAKE_CURRENT_SOURCE_DIR}/video_status.c"
  "${UXPLAY_SOURCE_DIR}/renderers/audio_renderer.c"
  "${UXPLAY_SOURCE_DIR}/renderers/video_renderer.c"
  "${UXPLAY_SOURCE_DIR}/renderers/mux_renderer.c")
target_link_libraries(renderers PUBLIC airplay)
target_include_directories(renderers PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")

add_library(uxplay STATIC "${UXPLAY_SOURCE_DIR}/uxplay.cpp")
target_link_libraries(uxplay PUBLIC renderers airplay)

# A console-subsystem executable, intentionally without Qt, WIN32, or a tray.
# The Go supervisor uses CREATE_NO_WINDOW and redirected standard handles.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/tests/blue-frame.h264" media_hex HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," media_bytes "${media_hex}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/media_fixture.h"
  "static const unsigned char media_fixture[] = {${media_bytes}};\n")
add_executable(mirrorme-receiver main.cpp media_probe.cpp)
target_include_directories(mirrorme-receiver PRIVATE "${UXPLAY_SOURCE_DIR}")
target_include_directories(mirrorme-receiver PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
target_compile_definitions(mirrorme-receiver PRIVATE
  RECEIVER_VERSION="${PROJECT_VERSION}"
  UXPLAY_COMMIT="437f37514257d9cb513ac7fbdee743b4da85852e")
target_link_options(mirrorme-receiver PRIVATE -municode -Wl,--no-insert-timestamp)
target_link_libraries(mirrorme-receiver PRIVATE uxplay)

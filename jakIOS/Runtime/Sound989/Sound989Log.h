#pragma once

// Stand-in for OpenGOAL's common/log/log.h in the 989snd sources copied from
// OpenGOAL/game/sound. Messages go to stderr, which reaches the Xcode console.

#ifndef FMT_HEADER_ONLY
#define FMT_HEADER_ONLY 1
#endif
#include <cstdio>
#include <utility>

#include "fmt/format.h"

namespace lg {
template <typename... Args>
void log989(const char* level, fmt::format_string<Args...> format, Args&&... args) {
  const std::string message = fmt::format(format, std::forward<Args>(args)...);
  fprintf(stderr, "[989snd %s] %s\n", level, message.c_str());
}

template <typename... Args>
void error(fmt::format_string<Args...> format, Args&&... args) {
  log989("error", format, std::forward<Args>(args)...);
}

template <typename... Args>
void warn(fmt::format_string<Args...> format, Args&&... args) {
  log989("warn", format, std::forward<Args>(args)...);
}

template <typename... Args>
void info(fmt::format_string<Args...> format, Args&&... args) {
  log989("info", format, std::forward<Args>(args)...);
}

template <typename... Args>
void debug(fmt::format_string<Args...>, Args&&...) {}
}  // namespace lg

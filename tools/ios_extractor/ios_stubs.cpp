// Stand-ins for the desktop-only parts of OpenGOAL's common library that the compiled sources reference
// but level extraction never calls. They replace common/repl/repl_wrapper.cpp (+ the replxx library) and
// common/util/term_util.cpp (system("clear") is unavailable on iOS).
#include "common/repl/repl_wrapper.h"
#include "common/util/term_util.h"

namespace REPL {

// Only used by goos::Reader::read_from_stdin.
const char* Wrapper::readline(const std::string&) {
  return nullptr;
}

void Wrapper::add_to_history(const std::string&) {}

}  // namespace REPL

namespace term_util {

void clear() {}

int row_count() {
  return 24;
}

int col_count() {
  return 80;
}

}  // namespace term_util

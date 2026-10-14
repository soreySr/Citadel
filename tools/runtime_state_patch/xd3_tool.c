// Minimal in-memory xdelta3 encoder/decoder for the runtime state patch
// (tools/runtime_state_patch/runtime_state_patch.py drives it).
//
// Build (from the repo root):
//   clang -O2 -IOpenGOAL tools/runtime_state_patch/xd3_tool.c -x c OpenGOAL/third-party/xdelta3/xdelta3.c \
//     -w -o tools/runtime_state_patch/xd3_tool
// Usage:
//   xd3_tool encode <source> <target> <patch>
//   xd3_tool decode <source> <patch> <output> <output-size>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "third-party/xdelta3/xdelta3.h"

static unsigned char *read_file(const char *path, size_t *size) {
  FILE *file = fopen(path, "rb");
  if (!file) return NULL;
  fseek(file, 0, SEEK_END);
  *size = (size_t)ftell(file);
  fseek(file, 0, SEEK_SET);
  unsigned char *bytes = malloc(*size ? *size : 1);
  if (bytes && fread(bytes, 1, *size, file) != *size) {
    free(bytes);
    bytes = NULL;
  }
  fclose(file);
  return bytes;
}

static int write_file(const char *path, const unsigned char *bytes, size_t size) {
  FILE *file = fopen(path, "wb");
  if (!file) return 0;
  const int ok = fwrite(bytes, 1, size, file) == size;
  fclose(file);
  return ok;
}

int main(int argc, char **argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: %s encode <source> <target> <patch> | decode <source> <patch> <output> <size>\n",
            argv[0]);
    return 2;
  }
  size_t source_size = 0, input_size = 0;
  unsigned char *source = read_file(argv[2], &source_size);
  unsigned char *input = read_file(argv[3], &input_size);
  if (!source || !input) {
    fprintf(stderr, "cannot read inputs\n");
    return 1;
  }
  size_t capacity = 0;
  if (strcmp(argv[1], "encode") == 0) {
    capacity = input_size + (1 << 20);
  } else if (strcmp(argv[1], "decode") == 0 && argc == 6) {
    capacity = (size_t)strtoull(argv[5], NULL, 10);
  } else {
    fprintf(stderr, "bad mode\n");
    return 2;
  }
  unsigned char *output = malloc(capacity);
  size_t output_size = 0;
  int result;
  if (argv[1][0] == 'e') {
    // No secondary compression: the patch's literal bytes stay inspectable by the bundle audit.
    // The packer deflates the whole patch afterwards.
    result = xd3_encode_memory(input, input_size, source, source_size, output, &output_size, capacity,
                               XD3_COMPLEVEL_9 | XD3_NOCOMPRESS);
  } else {
    result = xd3_decode_memory(input, input_size, source, source_size, output, &output_size, capacity, 0);
  }
  if (result != 0) {
    fprintf(stderr, "xdelta3 %s failed: %d\n", argv[1], result);
    return 1;
  }
  if (!write_file(argv[4], output, output_size)) {
    fprintf(stderr, "cannot write %s\n", argv[4]);
    return 1;
  }
  printf("%s: %zu bytes\n", argv[1], output_size);
  return 0;
}

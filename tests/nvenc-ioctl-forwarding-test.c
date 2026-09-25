#define dlsym nvenc_test_dlsym
#include "../nvenc-device-filter.c"

static void *captured_argument;

static int mock_ioctl(int fd, unsigned long request, ...) {
  (void)fd;
  (void)request;
  va_list args;
  va_start(args, request);
  captured_argument = va_arg(args, void *);
  va_end(args);
  return 0;
}

void *nvenc_test_dlsym(void *handle, const char *symbol) {
  (void)handle;
  if (strcmp(symbol, "ioctl") != 0) return NULL;
  return (void *)mock_ioctl;
}

int main(void) {
  int payload = 42;
  unsigned long request = _IO('T', 0x0e);
  if (_IOC_DIR(request) != _IOC_NONE || _IOC_SIZE(request) != 0) {
    fprintf(stderr, "regression test request must have zero encoded size\n");
    return 1;
  }

  if (ioctl(7, request, &payload) != 0 || captured_argument != &payload) {
    fprintf(stderr, "ioctl wrapper did not preserve the third argument\n");
    return 1;
  }

  puts("PASS ioctl argument forwarding for zero-size legacy request");
  return 0;
}

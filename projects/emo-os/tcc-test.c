int write(int fd, const void *buf, unsigned long n);

int main(void) {
  write(1, "tcc self-host ok\n", 17);
  return 42;
}

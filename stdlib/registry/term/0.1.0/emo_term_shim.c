/* The C glue of the term package: terminal input on stdin, behind
   exact-ABI wrappers.

   Two shapes of the host interface do not meet the FFI directly: the
   termios struct is opaque state, and a key is a (kind, code) pair. The
   wrappers below keep the struct in this file and pack a key into one
   int64_t — kind in the high 32 bits, code in the low 32. A negative
   result means failure and emo_term_error() carries the reason.

   The key kinds are the private contract between this file and
   term.emo; the numbers themselves are not part of the package's
   surface. */

#include <errno.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include "emo_defs.h"

enum {
  K_CHAR = 0,
  K_CTRL = 1,
  K_ENTER = 2,
  K_TAB = 3,
  K_BACK_TAB = 4,
  K_BACKSPACE = 5,
  K_ESCAPE = 6,
  K_UP = 7,
  K_DOWN = 8,
  K_LEFT = 9,
  K_RIGHT = 10,
  K_HOME = 11,
  K_END = 12,
  K_INSERT = 13,
  K_DELETE = 14,
  K_PAGE_UP = 15,
  K_PAGE_DOWN = 16,
  K_F1 = 17,
  K_F2 = 18,
  K_F3 = 19,
  K_F4 = 20,
  K_F5 = 21,
  K_F6 = 22,
  K_F7 = 23,
  K_F8 = 24,
  K_F9 = 25,
  K_F10 = 26,
  K_F11 = 27,
  K_F12 = 28,
  K_ALT = 29,
  K_UNKNOWN = 30,
  K_EOF = 31
};

/* Long enough for "term: operation: " plus strerror's text. */
static char emo_term_error_text[256] = "term: no error";

static void emo_term_set_error(const char *op, const char *detail) {
  snprintf(emo_term_error_text, sizeof emo_term_error_text, "term: %s: %s",
           op, detail);
}

static void emo_term_set_errno_error(const char *op) {
  snprintf(emo_term_error_text, sizeof emo_term_error_text, "term: %s: %s",
           op, strerror(errno));
}

/* ---- line mode ---- */

static char *emo_term_line_buf = NULL;
static size_t emo_term_line_len = 0;
static size_t emo_term_line_cap = 0;

static bool emo_term_line_push(unsigned char byte) {
  if (emo_term_line_len + 1 >= emo_term_line_cap) {
    size_t cap = emo_term_line_cap == 0 ? 128 : emo_term_line_cap * 2;
    char *grown = realloc(emo_term_line_buf, cap);
    if (grown == NULL) {
      return false;
    }
    emo_term_line_buf = grown;
    emo_term_line_cap = cap;
  }
  emo_term_line_buf[emo_term_line_len++] = (char)byte;
  emo_term_line_buf[emo_term_line_len] = '\0';
  return true;
}

/* 1 read, 0 end of input, -1 error. EINTR is retried: a signal is not
   the end of the stream. */
static int emo_term_read_one(unsigned char *out) {
  for (;;) {
    ssize_t n = read(STDIN_FILENO, out, 1);
    if (n == 1) {
      return 1;
    }
    if (n == 0) {
      return 0;
    }
    if (errno == EINTR) {
      continue;
    }
    return -1;
  }
}

/* 0: a line was collected; 1: end of input before any byte; -1: error.
   The terminator is kept, so "\n" and end of input stay distinct. */
int64_t emo_term_read_line(void) {
  emo_term_line_len = 0;
  if (emo_term_line_buf != NULL) {
    emo_term_line_buf[0] = '\0';
  }
  for (;;) {
    unsigned char byte;
    int r = emo_term_read_one(&byte);
    if (r < 0) {
      emo_term_set_errno_error("read_line");
      return -1;
    }
    if (r == 0) {
      return emo_term_line_len == 0 ? 1 : 0;
    }
    if (!emo_term_line_push(byte)) {
      emo_term_set_error("read_line", "out of memory");
      return -1;
    }
    if (byte == '\n') {
      return 0;
    }
  }
}

const char *emo_term_line(void) {
  return emo_term_line_buf != NULL ? emo_term_line_buf : "";
}

const char *emo_term_error(void) { return emo_term_error_text; }

/* ---- raw mode ---- */

static struct termios emo_term_saved;
static bool emo_term_raw = false;
static bool emo_term_atexit_registered = false;

/* The last chance to leave the terminal usable: a program that ends
   without an explicit restore() must not leave the shell in raw mode.
   A signal that kills the process bypasses this, as it bypasses every
   atexit handler. */
static void emo_term_restore_at_exit(void) {
  if (emo_term_raw) {
    tcsetattr(STDIN_FILENO, TCSANOW, &emo_term_saved);
    emo_term_raw = false;
  }
}

int64_t emo_term_enable_raw(void) {
  if (emo_term_raw) {
    return 0;
  }
  if (!isatty(STDIN_FILENO)) {
    emo_term_set_error("enable_raw", "not a terminal");
    return -1;
  }
  if (tcgetattr(STDIN_FILENO, &emo_term_saved) != 0) {
    emo_term_set_errno_error("enable_raw");
    return -1;
  }
  struct termios raw = emo_term_saved;
  cfmakeraw(&raw);
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) {
    emo_term_set_errno_error("enable_raw");
    return -1;
  }
  emo_term_raw = true;
  if (!emo_term_atexit_registered) {
    atexit(emo_term_restore_at_exit);
    emo_term_atexit_registered = true;
  }
  return 0;
}

int64_t emo_term_restore(void) {
  if (!emo_term_raw) {
    return 0;
  }
  if (tcsetattr(STDIN_FILENO, TCSANOW, &emo_term_saved) != 0) {
    emo_term_set_errno_error("restore");
    return -1;
  }
  emo_term_raw = false;
  return 0;
}

/* ---- keys ---- */

static int64_t emo_term_pack(int kind, uint32_t code) {
  return ((int64_t)kind << 32) | (int64_t)code;
}

/* 1 readable, 0 timed out, -1 error. */
static int emo_term_wait_readable(int timeout_ms) {
  struct pollfd p = {STDIN_FILENO, POLLIN, 0};
  for (;;) {
    int r = poll(&p, 1, timeout_ms);
    if (r > 0) {
      return 1;
    }
    if (r == 0) {
      return 0;
    }
    if (errno == EINTR) {
      continue;
    }
    return -1;
  }
}

/* A lone Esc and an escape sequence begin with the same byte. The short
   wait after Esc is what tells them apart; 50 ms is the conventional
   terminal timeout, and it is the only timing in this file. */
#define EMO_TERM_ESC_TIMEOUT_MS 50

/* UTF-8 continuation waits far less than a person could notice and far
   more than a terminal needs to deliver one sequence's bytes. */
#define EMO_TERM_UTF8_TIMEOUT_MS 100

static int64_t emo_term_read_ss3(void) {
  int w = emo_term_wait_readable(EMO_TERM_UTF8_TIMEOUT_MS);
  if (w < 0) {
    emo_term_set_errno_error("read_key");
    return -1;
  }
  unsigned char b = 0;
  if (w == 0 || emo_term_read_one(&b) <= 0) {
    return emo_term_pack(K_UNKNOWN, 0);
  }
  switch (b) {
  case 'A':
    return emo_term_pack(K_UP, 0);
  case 'B':
    return emo_term_pack(K_DOWN, 0);
  case 'C':
    return emo_term_pack(K_RIGHT, 0);
  case 'D':
    return emo_term_pack(K_LEFT, 0);
  case 'H':
    return emo_term_pack(K_HOME, 0);
  case 'F':
    return emo_term_pack(K_END, 0);
  case 'P':
    return emo_term_pack(K_F1, 0);
  case 'Q':
    return emo_term_pack(K_F2, 0);
  case 'R':
    return emo_term_pack(K_F3, 0);
  case 'S':
    return emo_term_pack(K_F4, 0);
  default:
    return emo_term_pack(K_UNKNOWN, b);
  }
}

static int64_t emo_term_csi_tilde(const char *params) {
  long n = strtol(params, NULL, 10);
  switch (n) {
  case 1:
  case 7:
    return emo_term_pack(K_HOME, 0);
  case 2:
    return emo_term_pack(K_INSERT, 0);
  case 3:
    return emo_term_pack(K_DELETE, 0);
  case 4:
  case 8:
    return emo_term_pack(K_END, 0);
  case 5:
    return emo_term_pack(K_PAGE_UP, 0);
  case 6:
    return emo_term_pack(K_PAGE_DOWN, 0);
  case 11:
    return emo_term_pack(K_F1, 0);
  case 12:
    return emo_term_pack(K_F2, 0);
  case 13:
    return emo_term_pack(K_F3, 0);
  case 14:
    return emo_term_pack(K_F4, 0);
  case 15:
    return emo_term_pack(K_F5, 0);
  case 17:
    return emo_term_pack(K_F6, 0);
  case 18:
    return emo_term_pack(K_F7, 0);
  case 19:
    return emo_term_pack(K_F8, 0);
  case 20:
    return emo_term_pack(K_F9, 0);
  case 21:
    return emo_term_pack(K_F10, 0);
  case 23:
    return emo_term_pack(K_F11, 0);
  case 24:
    return emo_term_pack(K_F12, 0);
  default:
    return emo_term_pack(K_UNKNOWN, '~');
  }
}

/* Control Sequence Introducer: Esc [ parameters final. Modifier
   parameters (the ";5" in Esc [ 1 ; 5 A) are accepted and ignored —
   the surface has no modifier bit yet, so Ctrl-Up reads as Up. */
static int64_t emo_term_read_csi(void) {
  char params[32];
  size_t len = 0;
  params[0] = '\0';
  for (;;) {
    int w = emo_term_wait_readable(EMO_TERM_UTF8_TIMEOUT_MS);
    if (w < 0) {
      emo_term_set_errno_error("read_key");
      return -1;
    }
    unsigned char b = 0;
    if (w == 0 || emo_term_read_one(&b) <= 0) {
      return emo_term_pack(K_UNKNOWN, 0);
    }
    if (b >= 0x40 && b <= 0x7e) {
      switch (b) {
      case 'A':
        return emo_term_pack(K_UP, 0);
      case 'B':
        return emo_term_pack(K_DOWN, 0);
      case 'C':
        return emo_term_pack(K_RIGHT, 0);
      case 'D':
        return emo_term_pack(K_LEFT, 0);
      case 'H':
        return emo_term_pack(K_HOME, 0);
      case 'F':
        return emo_term_pack(K_END, 0);
      case 'Z':
        return emo_term_pack(K_BACK_TAB, 0);
      case 'P':
        return emo_term_pack(K_F1, 0);
      case 'Q':
        return emo_term_pack(K_F2, 0);
      case 'R':
        return emo_term_pack(K_F3, 0);
      case 'S':
        return emo_term_pack(K_F4, 0);
      case '~':
        return emo_term_csi_tilde(params);
      default:
        return emo_term_pack(K_UNKNOWN, b);
      }
    }
    if (len + 1 < sizeof params) {
      params[len++] = (char)b;
      params[len] = '\0';
    }
  }
}

static int64_t emo_term_read_escape(void) {
  int w = emo_term_wait_readable(EMO_TERM_ESC_TIMEOUT_MS);
  if (w < 0) {
    emo_term_set_errno_error("read_key");
    return -1;
  }
  unsigned char b = 0;
  if (w == 0 || emo_term_read_one(&b) <= 0) {
    return emo_term_pack(K_ESCAPE, 0);
  }
  if (b == '[') {
    return emo_term_read_csi();
  }
  if (b == 'O') {
    return emo_term_read_ss3();
  }
  /* Esc followed by a byte is the terminal's spelling of Alt+key. */
  if (b < 0x80) {
    return emo_term_pack(K_ALT, b);
  }
  return emo_term_pack(K_UNKNOWN, b);
}

static bool emo_term_utf8_decode(unsigned char lead, uint32_t *code) {
  int len;
  uint32_t min;
  if (lead >= 0xc2 && lead <= 0xdf) {
    len = 2;
    *code = lead & 0x1f;
    min = 0x80;
  } else if (lead >= 0xe0 && lead <= 0xef) {
    len = 3;
    *code = lead & 0x0f;
    min = 0x800;
  } else if (lead >= 0xf0 && lead <= 0xf4) {
    len = 4;
    *code = lead & 0x07;
    min = 0x10000;
  } else {
    emo_term_set_error("read_key", "invalid UTF-8");
    return false;
  }
  for (int i = 1; i < len; i++) {
    if (emo_term_wait_readable(EMO_TERM_UTF8_TIMEOUT_MS) <= 0) {
      emo_term_set_error("read_key", "invalid UTF-8");
      return false;
    }
    unsigned char b = 0;
    if (emo_term_read_one(&b) <= 0 || (b & 0xc0) != 0x80) {
      emo_term_set_error("read_key", "invalid UTF-8");
      return false;
    }
    *code = (*code << 6) | (b & 0x3f);
  }
  if (*code < min || *code > 0x10ffff ||
      (*code >= 0xd800 && *code <= 0xdfff)) {
    emo_term_set_error("read_key", "invalid UTF-8");
    return false;
  }
  return true;
}

int64_t emo_term_read_key(void) {
  unsigned char b = 0;
  int r = emo_term_read_one(&b);
  if (r < 0) {
    emo_term_set_errno_error("read_key");
    return -1;
  }
  if (r == 0) {
    return emo_term_pack(K_EOF, 0);
  }
  if (b == 0x1b) {
    return emo_term_read_escape();
  }
  if (b == 0x0d || b == 0x0a) {
    return emo_term_pack(K_ENTER, 0);
  }
  if (b == 0x09) {
    return emo_term_pack(K_TAB, 0);
  }
  if (b == 0x7f || b == 0x08) {
    return emo_term_pack(K_BACKSPACE, 0);
  }
  if (b < 0x20) {
    return emo_term_pack(K_CTRL, b);
  }
  if (b < 0x80) {
    return emo_term_pack(K_CHAR, b);
  }
  uint32_t code = 0;
  if (!emo_term_utf8_decode(b, &code)) {
    return -1;
  }
  return emo_term_pack(K_CHAR, code);
}

/* ---- the terminal's size ---- */

static bool emo_term_size(int64_t *columns, int64_t *rows) {
  struct winsize ws;
  if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) != 0) {
    emo_term_set_errno_error("size");
    return false;
  }
  if (ws.ws_col == 0 || ws.ws_row == 0) {
    emo_term_set_error("size", "not a terminal");
    return false;
  }
  *columns = (int64_t)ws.ws_col;
  *rows = (int64_t)ws.ws_row;
  return true;
}

int64_t emo_term_columns(void) {
  int64_t columns = 0;
  int64_t rows = 0;
  return emo_term_size(&columns, &rows) ? columns : 0;
}

int64_t emo_term_rows(void) {
  int64_t columns = 0;
  int64_t rows = 0;
  return emo_term_size(&columns, &rows) ? rows : 0;
}

bool emo_term_is_tty(void) { return isatty(STDIN_FILENO) != 0; }

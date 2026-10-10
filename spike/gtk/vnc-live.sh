#!/bin/sh
# Open the GTK window live on this machine's screen: the app runs
# under Xvfb in the container, x11vnc streams the display, and macOS's
# built-in VNC client shows it. Window is interactive — click the
# button, screenshot freely.
#
#   Finder ⌘K (or open vnc://localhost:5901) to connect. No password
#   is set and the port only binds localhost.
set -e
cd "$(dirname "$0")"
EMO=${EMO:-../../_build/default/src/emo_cli/emo.exe}

[ -f .emo-build/emo_defs.h ] || { "$EMO" build main.emo -o gtk-spike || true; }

docker run --rm -p 127.0.0.1:5901:5901 -v "$PWD:/work" -w /work emo-gtk-build sh -c '
  set -e
  cc -O2 $(pkg-config --cflags gtk4) -I .emo-build -c shim.c -o shim.o
  cc -O2 .emo-build/main.c .emo-build/emo_c_runtime.c shim.o \
    -o gtk-spike $(pkg-config --cflags --libs gtk4)
  Xvfb :99 -screen 0 800x600x24 &
  sleep 1
  # A window manager draws the shell (titlebar, close buttons) — X11
  # decorations are the WM's job, and without one GTK maps a naked
  # client area at an arbitrary offset.
  DISPLAY=:99 openbox &
  sleep 1
  # -rfbport 5901 must match the published port (x11vnc defaults to
  # 5900); listen on all interfaces inside the container — Docker
  # Desktop''s proxy connects from the container IP, not its localhost,
  # and the host-side binding to 127.0.0.1 keeps it local. -passwd
  # because macOS Screen Sharing always shows a credential sheet for
  # plain VNC; the password is "emo".
  x11vnc -display :99 -passwd emo -forever -quiet -rfbport 5901 &
  echo ""
  echo "  open  vnc://localhost:5901  in Finder (⌘K)"
  echo "  password: emo"
  echo ""
  DISPLAY=:99 ./gtk-spike
'

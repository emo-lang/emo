# The `ui_gtk` gate's build and run environment: GTK 4's development
# package, a C compiler, pkg-config, and Xvfb — the corpus runs a real
# window on a virtual display, so the run needs no one at the keyboard.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgtk-4-dev xvfb gcc libc6-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

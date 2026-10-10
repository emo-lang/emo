FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgtk-4-dev xvfb gcc libc6-dev pkg-config \
      x11-apps x11-utils netpbm x11vnc openbox \
    && rm -rf /var/lib/apt/lists/*

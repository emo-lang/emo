# The wayland smoke leg's image: the paint demo's C compiled and run
# against a real compositor — headless sway — with grim the eye. No
# OCaml in the image: the host's compiler emits the C, this image
# only builds and drives it. The mirror line is the network's own
# medicine: deb.debian.org's CDN answered 502 for whole pools from
# here; TUNA answers.
FROM debian:bookworm-slim

RUN sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' \
      /etc/apt/sources.list.d/debian.sources \
 && apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      sway \
      grim \
 && apt-get clean \
 && useradd -m smoke

USER smoke
ENV XDG_RUNTIME_DIR=/tmp/xdg

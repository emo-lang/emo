# The dash 0.5.12 vendor

`third_party/dash/` is dash 0.5.12, unmodified.

- Source: the Debian orig tarball `dash_0.5.12.orig.tar.gz`; upstream
  is <https://git.kernel.org/pub/scm/utils/dash/dash.git>.
- SHA-256: `6a474ac46e8b0b32916c4c60df694c82058d3297d8b385b74508030ca4a8f28a`
- License: BSD-3-Clause; see `third_party/dash/COPYING`.

The tree sits at the repository root, not under `projects/emo-os/c/`:
the Emo package build assembles every `.S` under its project tree, and
dash's generated headers and generators are host build steps, not
kernel inputs. The overlay under `projects/emo-os/c/dash-port/` carries
no vendor file: its `build.sh` configures and builds in `.build/` and
copies the linked `src/dash` to `projects/emo-os/dash.elf`, the boot
tree's `dash.elf` slot. `dash-test.sh` is the acceptance script the
boot root hands the shell; the POSIX surface it needs lives in the
musl port (`projects/emo-os/c/musl-port/`).

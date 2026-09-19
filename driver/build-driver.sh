#!/bin/bash
# Builds the open-source SANE "brother_mfp" backend (with the HL-2280DW patch)
# and installs it, plus the scanimage tool, into <project>/sane-prefix.
#
# The backend is Ralph Little's in-progress brother_mfp branch of sane-backends:
#   https://gitlab.com/sane-project/backends/-/merge_requests/751
# Our patch adds the HL-2280DW model entry and fixes end-of-page parsing for
# this generation of Brother laser scanners.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$ROOT/sane-prefix"
SRC="$ROOT/driver/sane-backends-src"
PATCH="$ROOT/driver/brother_mfp-hl2280dw.patch"
COMMIT=641b75630dad5446e04c3927272b8b47e873d245
BREW_PREFIX="$(brew --prefix)"

echo "==> Checking Homebrew dependencies"
need=()
for f in libusb jpeg-turbo autoconf automake libtool autoconf-archive gettext pkgconf; do
  brew list --formula "$f" >/dev/null 2>&1 || need+=("$f")
done
if [ ${#need[@]} -gt 0 ]; then
  echo "    installing: ${need[*]}"
  brew install "${need[@]}"
fi

if [ ! -d "$SRC/.git" ]; then
  echo "==> Cloning sane-backends (brother_mfp_backend branch)"
  git clone --depth 1 -b brother_mfp_backend https://gitlab.com/sane-project/backends.git "$SRC"
fi
cd "$SRC"
if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  echo "==> Fetching pinned commit $COMMIT"
  git fetch --depth 1 origin "$COMMIT" && git checkout -q "$COMMIT" \
    || echo "    WARNING: could not pin to $COMMIT, building branch HEAD ($(git rev-parse --short HEAD))"
fi

echo "==> Applying HL-2280DW patch"
git checkout -q -- backend/brother_mfp
git apply "$PATCH"

echo "==> Bootstrapping build system"
echo "1.4.0" > .tarball-version   # shallow clone has no tags; give it a version
export PATH="$BREW_PREFIX/opt/gettext/bin:$BREW_PREFIX/opt/libtool/libexec/gnubin:$PATH"
./autogen.sh > autogen.log 2>&1

echo "==> Configuring (only the brother_mfp backend)"
BACKENDS="brother_mfp" \
CPPFLAGS="-I$BREW_PREFIX/include" \
LDFLAGS="-L$BREW_PREFIX/lib" \
./configure --prefix="$PREFIX" --without-snmp --disable-locking --with-usb > configure.log 2>&1

echo "==> Building"
make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1

echo "==> Installing into $PREFIX"
make install > install.log 2>&1
echo "brother_mfp" > "$PREFIX/etc/sane.d/dll.conf"

echo "==> Looking for the scanner"
"$PREFIX/bin/scanimage" -L

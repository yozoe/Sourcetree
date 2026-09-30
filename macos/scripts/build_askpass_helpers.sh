#!/bin/sh

set -eu

contents="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/MacOS"
mkdir -p "$contents"

arch_flags=""
for arch in ${ARCHS:-arm64}; do
  arch_flags="$arch_flags -arch $arch"
done

# Keep the helper architecture set aligned with the application bundle so a
# universal Release app can authenticate on both Apple Silicon and Intel Macs.
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror $arch_flags \
  "$PROJECT_DIR/AskPassHelper/main.c" \
  -o "$contents/git-desktop-askpass"
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror $arch_flags \
  "$PROJECT_DIR/AskPassBroker/main.c" \
  -o "$contents/git-desktop-askpass-broker"

# Xcode signs nested outputs after build phases. When a signing identity is
# already available, sign these generated executables with the same identity
# so Developer ID and ad-hoc builds do not leave linker-only signatures.
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    "$contents/git-desktop-askpass"
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    "$contents/git-desktop-askpass-broker"
fi

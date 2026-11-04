#!/bin/sh
# This switch controls only copying resources. It never opens the dormant host.
set -eu
case "${BEX_EMBED_NATIVE_WEB_RESOURCES:-NO}" in
  NO)
    # Refuse a reused product containing earlier opt-in outputs. Do not delete it.
    for item in BexWebUI native-resource-manifest.json; do
      candidate="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/$item"
      if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        printf '%s\n' 'error: Native resources remain in a disabled build. Use a separately authorized clean build.' >&2
        exit 1
      fi
    done
    exit 0
    ;;
  YES) ;;
  *) printf '%s\n' 'error: BEX_EMBED_NATIVE_WEB_RESOURCES must be exactly YES or NO.' >&2; exit 1 ;;
esac
case "${BEX_NATIVE_NODE_PATH:-}" in
  /*) ;;
  *) printf '%s\n' 'error: Set BEX_NATIVE_NODE_PATH to an existing canonical absolute Node executable.' >&2; exit 1 ;;
esac
if [ ! -x "$BEX_NATIVE_NODE_PATH" ]; then
  printf '%s\n' 'error: Selected Node executable is unavailable; no dependency installation is performed.' >&2
  exit 1
fi
# No eval, shell-expanded command string, package manager, PATH search or download.
NODE_OPTIONS= NODE_PATH= exec "$BEX_NATIVE_NODE_PATH" "${SRCROOT:?}/scripts/bex-embed-native-resources.mjs" --xcode-build-phase

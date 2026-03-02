#!/usr/bin/env bash
#
# Download zlib sources
#
set -e

ZLIB_VERSION=1.3.2

curl -o zlib.tar.gz https://www.zlib.net/zlib-${ZLIB_VERSION}.tar.gz

tar -xzf zlib.tar.gz

ZLIB_HOME=$(pwd)/zlib-${ZLIB_VERSION}

# if windows, turn /drive/path/to/zlib into
# drive:/path/to/zlib.
if [[ "$PLATFORM" == "windows"* ]]; then
  drive=$(echo "$ZLIB_HOME" | cut -d / -f 2)
  offset=$(expr ${#drive} + 2)
  ZLIB_HOME="${drive}:/${ZLIB_HOME:$offset}"
fi

echo "Setting ZLIB_HOME: $ZLIB_HOME"

# used by setup.py
echo "ZLIB_HOME=$ZLIB_HOME" >> "$GITHUB_ENV"

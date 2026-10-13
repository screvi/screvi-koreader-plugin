#!/bin/sh
# Runs the tests and packages screvi.koplugin as dist/screvi-koreader.zip,
# the asset attached to each GitHub release.
set -e
cd "$(dirname "$0")"
luajit spec/run.lua
out=dist/screvi-koreader.zip
mkdir -p dist
rm -f "$out"
COPYFILE_DISABLE=1 zip -qrX "$out" screvi.koplugin -x '*/.*'
unzip -l "$out"

#!/bin/sh
# Runs the tests and packages the plugin as dist/screvi-koreader.zip, the
# asset attached to each GitHub release. The zip holds a screvi.koplugin
# folder, ready to copy into KOReader's plugins folder.
set -e
cd "$(dirname "$0")"
luajit spec/run.lua
out=dist/screvi-koreader.zip
stage=dist/stage/screvi.koplugin
rm -rf dist
mkdir -p "$stage"
cp _meta.lua main.lua screvi_exporter.lua "$stage"/
(cd dist/stage && COPYFILE_DISABLE=1 zip -qrX ../screvi-koreader.zip screvi.koplugin)
rm -rf dist/stage
unzip -l "$out"

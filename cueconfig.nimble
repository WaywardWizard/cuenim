## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license

# Package
version       = "1.3.0"
author        = "Ben Tomlin"
description   = "Cue configuration with JSON fallback for Nim projects"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.6"

proc recListFiles*(dir: string, ext: string="nim"): seq[string] =
  result = @[]
  for f in dir.listFiles:
    if f.endsWith(ext):
      result.add(f)
  for d in listDirs(dir):
    result.add d.recListFiles(ext)

# `BINCFG`_ will be the folder containing the cached binary for the nim test
# when --outdir is not used. Because we want to test the runtime loading of cue
# files in the binaries folder we want control over where that folder is to
# write cue files to it.
task test, "Run tests":
  echo "Running tests..."
  for file in recListFiles("tests", "nim"):
    exec "nim --outdir:tests/bin r " & file

  echo "Running node.js tests..."
  for file in recListFiles("tests", "nim"):
    exec "nim -b:js -d:nodejs --outdir:tests/bin js -r " & file

  echo "Running browser js tests..."
  for file in recListFiles("tests", "nim"):
    exec "nim -b:js --outdir:tests/bin js -r " & file

## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
import std/[paths]
proc `/`*(a: Path, b: string): Path =
  result = a
  result.add(b.Path)

proc `/`*(a: string, b: Path): Path =
  result = a.Path
  result.add(b)

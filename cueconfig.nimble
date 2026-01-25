## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license

# Package
version       = "2.1.0"
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

task test, "Run tests for c backend":
  echo "Running tests..."
  for file in recListFiles("tests", "nim"):
    exec "nim --outdir:tests/bin r " & file

task testjs, "Run tests for js backend":
  echo "Running node.js tests..."
  for file in recListFiles("tests", "nim"):
    exec "nim -b:js -d:nodejs --outdir:tests/bin js -r " & file

  echo "Running browser js tests..."
  for file in recListFiles("tests", "nim"):
    exec "nim -b:js --outdir:tests/bin js -r " & file

const DOCFOLDER = "docs"
const SRCFOLDER = "src"
import std/[strformat,sequtils,sugar]
task docgen, "Generate documentation":

  template checkresult() =
    if result.exitCode != 0:
      echo "Documentation generation had some errors;"
      echo result.output
      quit(result.exitCode)

  echo "Generating documentation..."
  var q: seq[string]
  exec &"rm -rf {DOCFOLDER}/*"
  # --outdir is bugged, only works immediately before sub command...
  var result: tuple[output:string, exitCode:int]
  echo "Processing md files..."
  
  const cmd = "nim --colors:on --path:$projectDir {extraArgs} --outdir:{DOCFOLDER} {subcmd} {target}"
  
  # Accumulate md doc cmds
  var subcmd = "md2html"
  for target in recListFiles(SRCFOLDER, "md"):
    for extraArgs in ["--project --index:only", "--project --index:off"]:
      q.add fmt(cmd)
      
  # Accumulate nim doc cmds
  subcmd = "doc"
  const target = SRCFOLDER & "/*.nim"
  var extraArgsSet = collect:
    for ix in ["only","off"]:
      &"--index:{ix} --project --docInternal"
  for extraArgs in extraArgsSet:
    q.add fmt(cmd) 
    
  echo "Generating indices..."
  for theCmd in q.filterIt(it.contains("--index:only")):
    result = gorgeEx theCmd
    checkresult()
    
  echo "Generating html..."
  for theCmd in q.filterIt(not it.contains("--index:only")):
    result = gorgeEx theCmd
    checkresult()
    
  #  echo "Documentation generation had some errors;"
  #  # lines with "Error" in them
  #  echo ""
  #  echo result.output.splitLines().filterIt(it.contains "Error").join("\n")
  #  quit(result.exitCode)

task build, "Build the library":
  echo "Building library..."
  exec "nim c src/cueconfig.nim"

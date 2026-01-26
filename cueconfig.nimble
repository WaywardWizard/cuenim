## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license

# Package
version       = "2.4.0"
author        = "Ben Tomlin"
description   = "Cue, sops, json, env typesafe compile/runtime configuration library"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.4"

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
  var result: tuple[output:string, exitCode:int]
  
  # --outdir is bugged, only works immediately before sub command...
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
      &"--index:{ix} --project "
  for extraArgs in extraArgsSet:
    q.add fmt(cmd) 
    
  echo "Generating indices..."
  for theCmd in q.filterIt(it.contains("--index:only")):
    result = gorgeEx theCmd
    echo result.output
    checkresult()
    
  echo "Generating html..."
  for theCmd in q.filterIt(not it.contains("--index:only")):
    result = gorgeEx theCmd
    echo result.output
    checkresult()
    
  # need to have theindex.html for genearted links, and index.html for landing
  result = gorgeEx &"cp {DOCFOLDER}/theindex.html {DOCFOLDER}/index.html"
  checkResult()

task compatibility, "Check compatibility with older Nim versions":
  let getVersions:string = r"choosenim --noColor versions|awk '/.*\*?.*([0-9]+\.){2}[0-9]+/'|grep -Po '(\d|\.)+'|sort -V"
  let thisVersion = (gorgeEx r"""choosenim show | grep "*"|tr -d " *"""").output
  
  var versions = gorgeEx(getVersions).output.splitLines()
  echo &"Testing with nim versions : {versions}"
  
  var passedVersions = newSeq[string]()
  var testAll = false
  var result: tuple[output:string, exitCode:int]
  for ver in versions: # oldest first
    discard gorgeEx &"choosenim -y {ver}"
    for task in ["test","testjs","docgen"]:
      result = gorgeEx &"nimble {task}"
      if result.exitCode != 0:
        break
    if result.exitCode == 0:
      echo &"Checking compatibility with nim {ver}... PASSED"
      passedVersions.add ver
      if not testAll:
        break
    else:
      echo &"Checking compatibility with nim {ver}... FAILED"
  discard gorgeEx(&"choosenim {thisVersion}")
  echo &"Passed versions: {passedVersions}"
    
task build, "Build the library":
  echo "Building library..."
  exec "nim c src/config.nim"
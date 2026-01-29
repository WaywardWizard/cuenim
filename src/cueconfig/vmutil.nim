## Copyright (c) 2025 Ben Tomlin 
## Licensed under the MIT license
## 
## Extended filesystem utilities working on both the c backend *and* nimvm
## 
## In a case, we need these for the nimvm when compiling for js. Because when 
## conditional compilation can only have a simple when nimvm condition, we are
## unable to conditionally compile procs to be available for the nimvm but not 
## the target backend. Therefore, procs not supporting backends such as js will
## need to be compiled for the js backend but will raise a CodepathDefect
import std/[paths,sequtils,sugar,times,strutils]
import pathutil,exceptions
when nimvm:
  import std/[staticos,macros]
else:
  import std/[os]
  
proc realpath(path:string): string = staticExec("realpath " & path)
  
proc isAbsolute*(p: Path): bool =
  ## Check if path is absolute in both compiletime and runtime contexts
  ## 
  ## The javascript backend does not support isAbsolute correctly
  when not defined(js):
    result = paths.isAbsolute(p)
  else:
    # js backend is not detecting isAbsolute correctly
    result = startsWith($p,"/")
        
type 
  StaticPath* = tuple[kind:PathComponent,path: string]
proc listFilesRec(path: Path|string, relative:bool = true, followLinks:bool = true): seq[StaticPath] =
  ## List all files in directory and children, no order
  ## 
  ## followLinks will return links themselves as files if false or follow them
  result = @[]
  for file in staticWalkDir($path,false):
    case file.kind
    of pcFile:
      result.add file
    of pcLinkToFile:
      result.add if followLinks: (pcFile,realpath(file.path)) else: file
    of pcDir:
      result.add listFilesRec(file.path,false)
    of pcLinkToDir:
      result.add if followLinks: (pcDir,realpath(file.path)) else: file
  if relative:
    return collect(newSeq):
      for (ikind, ipath) in result:
        (ikind, ipath.relativePath($path))
    
iterator staticWalkDirRec*(path: Path|string, relative: bool, followLinks: bool=true): StaticPath = 
  for f in listFilesRec(path, relative, followLinks): yield f
  
proc getCurrentDir*(): string = 
  ## Working directory at runtime, project directory at compiletime.
  when nimvm:
    result = gorgeEx("pwd").output
  else:
    when not defined(js):
      result = os.getCurrentDir()
    else:
      raise CodepathDefect.newException("Not available for JS backend")

proc getContextDir*(): string =
  ## Return the working directory at runtime, project directory at compiletime.
  when nimvm:
    result = getProjectPath()
  else:
    when not defined(js): result = getCurrentDir()
    else: raise CodepathDefect.newException("Not available for JS backend")
  
proc extant*(p: Path): bool =
  ## Compiletime or runtime existence of path relative to the *context* directory
  ## 
  ## See [getContextDir]
  var path = p
  if not p.isAbsolute():
    path = getContextDir() / p
  when nimvm:
    result = staticos.staticFileExists($path)
  else:
    when not defined(js):
      result = fileExists($path)
    else:
      raise CodepathDefect.newException("Not available for JS backend")
      
proc getLastModificationTime*(file:string): Time = 
  ## Shim for the nimvm, does not support javascript backend
  ## 
  ## Useful when using from nimvm whilst compiling for js backend
  when nimvm:
    result = staticExec("stat -c %Y " & file).parseInt().fromUnix()
  else:
    when defined(js):
      raise CodepathDefect.newException("Not available for JS backend")
    else:
      result = os.getLastModificationTime(file)
## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
## 
## Logic for loading json from sops, cue and json files, iterating and accessing

import std/[json,sequtils,strutils,strformat,syncio,envvars,paths, re,
  times, algorithm, hashes]
# when nimvm:
#   import std/[staticos]
when not defined(js):
  import std/[os,osproc]
import util

type
  FileSelectorKind* = enum
    fskPath, fskRegex
  FileSelector* = object
    case discriminator: FileSelectorKind
    of fskPath:
      path: Path
    of fskRegex:
      searchspace: Path ## regex to apply over all files in this path and below
      patternStr: string ## original pattern string
      pattern: Regex ## matcher of *relative* paths in searchspace
    useJsonFallback*: bool = true ## for cue files only, if not loadable, try json of same name
  
  JsonSourceKind* = enum
    jsJson="json",jsCue="cue",jsSops="sops",jsEnv="env"
  JsonSource* = object
    case discriminator*: JsonSourceKind
    of jsJson, jsCue, jsSops:
      path*: Path ## path to source
    of jsEnv:
      prefix: string ## match env vars on prefix, ex: "NIM_"
      caseInsensitive: bool = true ## whether prefix matching is case insensitive
    jsonStr: string ## json string of content
    json: JsonNode  ## loaded json
  SerializedJsonSource* = tuple[kind,path,prefix,jsonStr:string,caseInsensitive:bool]
  
proc initFileSelector*(searchspace: Path, pattern: string, useJsonFallback=true): FileSelector = 
  ## Initialize a FileSelector from a searchspace path and regex pattern
  if pattern.len == 0:
    raise ValueError.newException("Pattern cannot be empty")
  result.discriminator = fskRegex
  result.searchspace = searchspace
  result.patternStr = pattern
  result.pattern = re(pattern)
proc initFileSelector*(path: Path, useJsonFallback=true): FileSelector = 
  ## Initialize a FileSelector from a file path
  result.discriminator = fskPath
  result.path = path

proc hash*(x: FileSelector): Hash =
  ## Hash a FileSelector for caching, equivalence checking
  ## May fail if `initFileSelector`_ was not called for construction
  doAssert x.patternStr != "" or x.discriminator == fskPath, "Improperly constructed FileSelector"
  var h: Hash
  case x.discriminator
  of fskPath: h = h !& hash($x.path)
  of fskRegex: 
    h = h !& hash($x.searchspace)
    h = h !& hash(x.patternStr)
  !$h
  
proc interpolate(s: FileSelector): FileSelector =
  ## Return a FileSelector with environment variable and cwd interpolation
  ## 
  ## Replaces `{VAR}` in the pattern with the value of the environment.
  ## Replace `{getCurrentDir()}` with the current working directory.
  result.discriminator = s.discriminator
  var pathStr: string
  var cwd = os.getCurrentDir()
  
  # cwd
  case s.discriminator
  of fskPath:
    pathStr = $s.path
    pathStr = pathStr.replace("{getCurrentDir()}", cwd)
  of fskRegex:
    pathStr = $s.patternStr
    pathStr = pathStr.replace("{getCurrentDir()}", cwd)
  
  # env
  let matcher = re(r"\{([A-Za-z0-9_]+)\}")
  var matches: array[1,string]
  while match(pathStr, matcher, matches):
    pathStr = pathStr.replace("{" & matches[0] & "}", getEnv(matches[0]))
      
  case s.discriminator
  of fskPath:
    result.path = pathStr.Path
  of fskRegex:
    result.searchspace = s.searchspace
    result.patternStr = s.patternStr
  
proc load(x:JsonSource): tuple[jsonStr:string,json:JsonNode]
proc initJsonSource*(path: Path, useJsonFallback=false): JsonSource = 
  ## Initialize a JsonFile from a file path, for a cue file fallback to json of
  ## same name with '\.cue$" changed to '.json' if cue binary missing or file missing.
  ## 
  ## Where cue/sops binaries are missing or the path does not exist and a fallback
  ## is not possible raise an exception.
  ## 
  ## .*\.sops\.(yaml|json) => jsSops
  ## .*\.cue               => jsCue
  ## .*\.json              => jsJson
  let pathSplit = ($path).split(".")
  var discriminant: JsonSourceKind
  if pathSplit.len >= 2 and pathSplit[^2].toLowerAscii() == "sops":
    discriminant = jsSops
  else:
    case pathSplit[^1].toLowerAscii()
    of "cue":
      discriminant = jsCue
    of "json":
      discriminant = jsJson
    else:
      raise newException(ValueError, "Unsupported file extension: " & pathSplit[^1])
  
  var extant: bool = extant(path)
  case discriminant
  of jsSops:
    if NO_SOPS: raise ValueError.newException("No sops binary available")
    if not extant: raise ValueError.newException("File does not exist: " & $path)
    result.path = path
    result.discriminator = discriminant
  of jsJson:
    if not extant: raise ValueError.newException("File does not exist: " & $path)
    result.path = path
    result.discriminator = discriminant
  of jsCue:
    # cue fallback to json
    if useJsonFallback:
      var usePath = path
      if (not extant or NO_CUE):
        discriminant = jsJson
        usePath = path.changeFileExt("json")
        extant = extant(usePath)
      if not extant:
          raise ValueError.newException("Cue file does not exist, no fallback json found: " & $path)
      result.path = usePath
    else: result.path = path
    if not extant: raise ValueError.newException("File does not exist: " & $path)
    result.discriminator = discriminant
    
  # never reached
  else: assert false
    
  (result.jsonStr, result.json) = result.load()
  
proc initJsonSource*(envprefix:string,caseInsensitive=true): JsonSource = 
  result = JsonSource(
    discriminator: jsEnv,
    prefix: envprefix,
    caseInsensitive: caseInsensitive,
  )
  (result.jsonStr, result.json) = result.load()

  
iterator items*(s: FileSelector, reverse=false): Path =
  ## Iterate over *extant* paths of a FileSelector. High to low precedence. 
  ## Dont follow symlinks. 
  ## 
  ## # fskPath
  ## - A maximum of one path for fskPath
  ## - Relative paths are returned as-is, and are relative to the pwd
  ## 
  ## # fskRegex
  ## - zero or more paths returned 
  ## - Paths are relative to their searchspace
  ## - An empty searchspace will be relative to the pwd
  ## 
  ## # Precedence
  ## Matched paths are returned in order with following precedence:
  ##    - Deepest in file hierachy, unless tied, then
  ##    - Newest mtime, unless tied, then
  ##    - Lexical order of relative pathe
  when defined(js): ValueError.newException("File access not supported on JS backend")
  type SortPath = tuple[path:Path,depth:int,mtime:Time]
  proc cmp(a,b:SortPath): int =
    if a.depth!=b.depth:
      -cmp(a.depth,b.depth) # deepest to shallowest
    elif a.mtime!=b.mtime:
      -cmp(b.mtime,a.mtime) # newest to oldest
    else:
      cmp($a.path,$b.path)
  
  case s.discriminator
  of fskPath:
    var extant: bool = extant(s.path)
    if extant: yield s.path
  of fskRegex:
    var items: seq[SortPath] = @[]
    # todo may need a nimvm implementation
    var searchspace = if $s.searchspace == "": paths.getCurrentDir() else: s.searchspace
    for itemx in walkDirRec($searchspace,relative=true):
      if itemx.match(s.pattern):
        items.add((itemx.Path, split($itemx.parentDir,'/').len, getLastModificationTime($itemx)))
      
    if reverse:
      items.sort(cmp, SortOrder.Descending)
    else:
      items.sort(cmp)
      
    for itemx in items:
      yield itemx.path

iterator interpolatedItems*(s: FileSelector,reverse=false): Path =
  for i in s.interpolate().items(reverse): yield i
  
proc initJsonSource*(s: FileSelector): seq[JsonSource] =
  ## Initialize a sequence of JsonSources from a FileSelector
  result = @[]
  for path in s.items():
    result.add path.initJsonSource()
 
proc `$`*(x:JsonSource): string =
  ## String representation of a JsonSource
  case x.discriminator
  of jsJson, jsCue, jsSops:
    result = &"{x.discriminator}({$x.path})"
  of jsEnv:
    result = &"{x.discriminator}(prefix={x.prefix},caseInsensitive={x.caseInsensitive})"
   
func serialize*(x: JsonSource): SerializedJsonSource =
  ## Serialize a JsonSource to a string for caching
  case x.discriminator
  of jsJson, jsCue, jsSops:
    result.path = $x.path
  of jsEnv:
    result.prefix = x.prefix
    result.caseInsensitive = x.caseInsensitive
  result.kind = $x.discriminator
  result.jsonStr = x.jsonStr

proc deserialize*(x: SerializedJsonSource): JsonSource =
  ## Deserialize a JsonSource from a string
  result.discriminator = parseEnum[JsonSourceKind](x.kind)
  case result.discriminator
  of jsJson, jsCue, jsSops:
    doAssert(x.prefix=="" and x.caseInsensitive==default(bool))
    result.path = x.path.Path
  of jsEnv:
    doAssert(x.path=="")
    result.prefix = x.prefix
    result.caseInsensitive = x.caseInsensitive
  result.jsonStr = x.jsonStr
  result.json = parseJson(result.jsonStr)
      
proc parse(x:string): JsonNode # forward declaration

proc pretty*(x: JsonSource,indent:int=2): seq[string] =
  x.json.pretty(indent).splitLines()
  
proc mergeIn(dest, src: JsonNode): void # forward declaration
proc load(x:JsonSource): tuple[jsonStr:string,json:JsonNode] =
  ## Load the content of a JsonSource as a JsonString.
  ## 
  ## Cue to json fallback implemented at higher level in stack
  case x.discriminator
  of jsJson, jsCue, jsSops:
    when defined(js): ValueError.newException("File access not supported on JS backend")
  else: discard
    
  case x.discriminator
  of jsJson:
    var jsonStr: string
    when nimvm: jsonStr= staticRead($x.path)
    else: jsonStr= readFile($x.path)
    (jsonStr, parseJson(jsonStr))
  of jsCue:
    if NO_CUE: raise ValueError.newException("No cue binary available")
    var cmd: tuple[output:string, exitCode:int]
    when nimvm:
      cmd = gorgeEx(&"cue export {x.path}")
    else:
      cmd = execCmdEx(&"cue export {x.path}")
    if cmd.exitCode != 0:
      raise newException(
        IOError,
        &"Cue export error for file {x.path};\n{cmd.output}",
      )
    (cmd.output, parseJson(cmd.output))
  of jsSops:
    if NO_SOPS: raise ValueError.newException("No sops binary available")
    var cmd: tuple[output:string, exitCode:int]
    when nimvm:
      cmd = gorgeEx(&"sops decrypt --output-type json {x.path}")
    else:
      cmd = execCmdEx(&"sops decrypt --output-type json {x.path}")
    if cmd.exitCode != 0:
      raise newException(
        IOError,
        &"Sops decrypt error for file {x.path};\n{cmd.output}",
      )
    (cmd.output,parseJson(cmd.output))
  of jsEnv:
    var
      rawEnv: seq[string]
      json: JsonNode = newJObject()
    for k,v in envPairs():
      let kprime = if x.caseInsensitive: k.toLowerAscii() else: k
      let xprefix = if x.caseInsensitive: x.prefix.toLowerAscii() else: x.prefix
      if kprime.startsWith(xprefix):
        let key = k[xprefix.len..^1]
        rawEnv.add(key & "=" & v)
        if kprime == xprefix: # top level json object merge ie "NIM_={...}"
          var topLevelJson: JsonNode = v.parse()
          json.mergeIn topLevelJson
        else:                        # nested path
          let path = key.split('_')
          var parent = json
          for part in path[0..^2]:   # make path
            if not parent.contains(part):
              parent[part]=newJObject()
            parent = parent[part] 
          parent[path[^1]]=v.parse() # insert
    (json.pretty(),json)
    
proc reload*(x: var JsonSource): void =
  ## Reload the content of a JsonSource
  (x.jsonStr, x.json) = x.load()
    
proc contains*(n: JsonNode, key: varargs[string]): bool =
  ## Determine if a nested key is present in a json node
  discard foldl(
    key,
    if not a.contains(b):
      return false
    else:
      a[b],
    n,
  )
  return true
  
proc contains*(n:JsonSource, key: varargs[string]): bool =
  ## Determine if a nested key is present in a JsonSource
  n.json.contains(key)
proc `{}`*(n:JsonSource, key: varargs[string]): JsonNode =
  ## Access a nested key in a JsonSource
  return n.json{key}
  
type Catenatable[T] = concept
  proc `&`(x,y: T): T
    
iterator cartesianProduct[T:Catenatable](a,b: openArray[T], op:proc(x,y:T):T): T=
  ## Compute the cartesian product of two sequences of strings
  for itemA in a:
    for itemB in b:
      yield(op(itemA,itemB))
      
iterator cartesianProduct[T:Catenatable](a,b: openArray[T]): T =
  for x in cartesianProduct(a,b,proc(x,y:T):T = x & y): yield x
    
proc mergeIn(dest, src: JsonNode): void =
  ## Merge src into dest, overwriting any existing keys in dest
  ## When an object value is found in src, and the corresponding key in dest is 
  ## also an object, the merge is done recursively retaining exclusive keys in 
  ## dest, clobbering common keys with those from src and adding exclusive keys 
  ## from src.
  ## When an array value is found in src, any corresponding key in dest is 
  ## overwritten with the array from src.
  for k,v in src:
    case v.kind
    of JObject:
      if dest.contains(k) and dest[k].kind == JObject:
        mergeIn(dest[k], v)
      else:
        dest[k] = v
    else:
      dest[k] = v

proc parse(x:string): JsonNode =
  ## Change string to JsonNode interpreting the following format;
  ##  [v1,v2,v3,...]   -> array of values, all of type inferred from first value
  ##  (+|-)\d+         -> integer
  ##  (+|-)?\d+\.\d+   -> float
  ##  (+|-)?(inf|nan)  -> float infinity or NAN
  ##  true|false       -> boolean
  ##  null             -> null
  ##  otherwise        -> string
  ## ^{.*}$            -> json string
  ## 
  ## Numbers may contains underscores for readability which are ignored
  ## Objects must be valid json
  var s=x.strip()
  var sLower = s.toLowerAscii()
  if s.len == 0:  return newJString("")
  if sLower == "null": return newJNull()
  if sLower in ["true", "false"]: return newJBool(sLower == "true")
  # take out sign only strings so not interpreted as int without number
  if sLower in ["+","-"]:  return newJString(s)
    
  if sLower[0] == '[' and sLower[^1] == ']': # Array
    result = newJArray()
    for element in s[1..^2].split(','): result.add(parse(element))
    return result
    
  if sLower in toSeq(cartesianProduct(["+","-",""],["nan","inf"])): # Float special
    return newJFloat(parseFloat(s))
    
  if sLower[0] in {'+','-','0'..'9','.','_'}: # Number possibly
    if sLower[1..^1].allCharsInSet({'0'..'9','_','.','e','+','-'}):
      case sLower.count('.')
      of 0: return newJInt(parseInt(s.replace("_")))
      of 1: return newJFloat(parseFloat(s.replace("_")))
      else: discard # continue and try as object or string
        
  if sLower[0] == '{' and sLower[^1] == '}': # Object (we trimmed whitespace)
    when defined(js): # JS backends std/json does not support raw numbers
      return parseJson(s)
    else:
      # raw*=false will convert to JInt/JFloat instead of JString for numbers
      return parseJson(s,rawIntegers=false, rawFloats=false)
    
  return newJString(s)
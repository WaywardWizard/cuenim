## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
##
## Logic for loading json from sops, cue and json files, serializing iterating 
## and accessing. Parsing env vars to json.
import
  std/[
    json, sequtils, strutils, strformat, envvars, paths, times, algorithm,
    hashes, pegs
  ]
when not defined(js):
  import std/[os, osproc,syncio]
  
import util

type
  FileSelectorKind* = enum
    fskPath
    fskPeg

  FileSelector* = object
    case discriminator: FileSelectorKind
    of fskPath:
      path: Path
    of fskPeg:
      searchspace: Path ## regex to apply over all files in this path and below
      peg: Peg
        ## matcher of *relative* paths in searchspace \
        ## The path string will be `searchspace / subpath`
    useJsonFallback*: bool = true
      ## for cue files only, if not loadable, try json of same name

  JsonSourceKind* = enum
    jsJson = "json"
    jsCue = "cue"
    jsSops = "sops"
    jsEnv = "env"

  JsonSource* = object
    case discriminator*: JsonSourceKind
    of jsJson, jsCue, jsSops:
      path*: Path ## path to source
    of jsEnv:
      prefix: string ## match env vars on prefix, ex: "NIM_"
      caseInsensitive: bool = true ## whether prefix matching is case insensitive
    jsonStr: string ## json string of content
    json: JsonNode ## loaded json

  SerializedJsonSource* =
    tuple[kind, path, prefix, jsonStr: string, caseInsensitive: bool]

proc `$`*(s:SerializedJsonSource): string =
  ## String representation of a SerializedJsonSource
  &"SerializedJsonSource(kind={s.kind},path={s.path},prefix={s.prefix},caseInsensitive={s.caseInsensitive})"
  
proc initFileSelector*(
    searchspace: Path, peg: string, useJsonFallback = true
): FileSelector =
  ## Initialize a FileSelector from a searchspace path and peg 
  if ($peg).len == 0: raise ValueError.newException("Peg cannot be empty")
  FileSelector(
    discriminator: fskPeg,
    searchspace: searchspace,
    peg: peg(peg),
    useJsonFallback: useJsonFallback,
  )

proc initFileSelector*(path: Path, useJsonFallback = true): FileSelector =
  ## Initialize a FileSelector from a file path
  FileSelector(discriminator: fskPath, path: path, useJsonFallback: useJsonFallback)

proc match*(x:FileSelector, path:string): bool = 
  x.discriminator == fskPath and $x.path == path
proc match*(x:FileSelector, path:string, peg: string): bool = 
  x.discriminator == fskPeg and $x.searchspace == path and $x.peg == peg
  
proc hash*(x: FileSelector): Hash =
  ## Hash a FileSelector for caching, equivalence checking
  ## May fail if `initFileSelector`_ was not called for construction
  doAssert x.discriminator == fskPath or $x.peg != "",
    "Improperly constructed FileSelector"
  var h: Hash
  case x.discriminator
  of fskPath:
    h = h !& hash($x.path)
  of fskPeg:
    h = h !& hash($x.searchspace)
    h = h !& hash($x.peg)
  !$h

proc hash*(x: JsonSource): Hash =
  ## Checksumming allows us to determine changes of configuration, hash on json
  ## field redundant so we implement a hash and dont use the default
  doAssert x.jsonStr != "", "JSON not loaded"
  var h:Hash = 0
  case x.discriminator
  of jsEnv: h= h !& x.prefix.hash !& hash(x.caseInsensitive.int)
  else: h= h !& x.path.hash
  h=h !& x.jsonStr.hash
  return h

proc interpolate(s: FileSelector): FileSelector =
  ## Return a FileSelector with environment variable and cwd interpolation
  ##
  ## Replaces `{VAR}` in the path or searchspace with the value of the environment.
  ## Replace `{getContextDir()}` with the current working directory at runtime
  ## and the project directory at compiletime.
  result = s # copy
  var pathStr: string
  var cxd = util.getContextDir()

  # cwd
  case s.discriminator
  of fskPath:
    pathStr = $s.path
  of fskPeg:
    pathStr = $s.searchspace
  pathStr = pathStr.replace("{getContextDir()}", cxd)

  # env replacements
  let matcher = peg"\{@@\}"
  var matches: array[1, string]
  while contains(pathStr, matcher, matches):
    let envval = envvars.getEnv(matches[0])
    if envval == "":
      raise ValueError.newException(&"Interplation env var {matches[0]} is empty")
    pathStr = pathStr.replace("{" & matches[0] & "}", envval)

  # update path
  case s.discriminator
  of fskPath:
    result.path = pathStr.Path
  of fskPeg:
    result.searchspace = pathStr.Path

proc load(x: JsonSource): tuple[jsonStr: string, json: JsonNode]
proc initJsonSource*(path: Path, useJsonFallback = false): JsonSource =
  ## Initialize a JsonFile from a file path
  ## 
  ## For a cue file fallback to json of same name with '\.cue$" changed to '.json' 
  ## if cue binary missing or file missing.
  ##
  ## Where cue/sops binaries are missing or the path does not exist and a fallback
  ## is not possible raise an exception.
  ## 
  ## Also load the file content into memory in json format
  ##
  ## `.*\.sops\.(yaml|json)` => jsSops
  ## `.*\.cue`               => jsCue
  ## `.*\.json`              => jsJson
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
  case discriminant # check path exists, fallback path if required
  of jsSops, jsJson:
    if not extant:
      raise ValueError.newException("File does not exist: " & $path)
    result.path = path
    result.discriminator = discriminant
  of jsCue:
    # cue fallback to json
    if useJsonFallback: # can we fallback
      var usePath = path
      if not extant:
        discriminant = jsJson
        usePath = path.changeFileExt("json")
        extant = extant(usePath)
      if not extant:
        raise ValueError.newException(
          "Cue file not available, no fallback json found: " & $path
        )
      result.path = usePath
    else:
      result.path = path
    if not extant:
      raise ValueError.newException("File does not exist: " & $path)
    result.discriminator = discriminant

  # never reached
  else:
    assert false

  try: # load content
    (result.jsonStr, result.json) = result.load()
  except IOError, OSError:
    if discriminant == jsCue and useJsonFallback: # no cue binary
      return initJsonSource(path.changeFileExt("json"))
    else:
      echo $getCurrentException().msg
      raise # no sops binary, caller to handle

proc initJsonSource*(envprefix: string, caseInsensitive = true): JsonSource =
  result = JsonSource(
    discriminator: jsEnv, prefix: envprefix, caseInsensitive: caseInsensitive
  )
  (result.jsonStr, result.json) = result.load()

proc depth(x:JsonSource): int =
  ## Depth of JsonSource in file hierarchy
  case x.discriminator
  of jsJson, jsCue, jsSops:
    result = split($x.path.parentDir, '/').len
  of jsEnv:
    raise ValueError.newException("No depth for env JsonSources")
proc mtime(x:JsonSource): Time =
  ## Last modification time of JsonSource, supported at compiletime
  case x.discriminator
  of jsJson, jsCue, jsSops:
    result = util.getLastModificationTime($x.path) # os @run, util @compile
  of jsEnv:
    raise ValueError.newException("No mtime for env JsonSources")
    
type SortKey = tuple[path: string, depth: int, mtime: Time]
proc sortKey(x: JsonSource): SortKey =
  ## Sort key for JsonSource
  case x.discriminator
  of jsJson, jsCue, jsSops: result = ( $x.path, x.depth(), x.mtime() )
  of jsEnv: raise ValueError.newException("No sortKey for env JsonSources")
    
proc cmp(a,b:SortKey): int =
  ## Comparator producing least to most precedent order
  if a.depth != b.depth: cmp(a.depth, b.depth)      # shallow to deep
  elif a.mtime != b.mtime: cmp(a.mtime, b.mtime)   # old to new
  else: -cmp($a.path, $b.path)                      # reverse alphabetical

proc cmpFiles*(a, b: tuple[key:Hash,val:JsonSource]): int =
  ## Comparator for JsonSource of file type, defining precedence order
  ## 
  ## # File Precedence
  ## Most precedent decided as follows
  ## - Deeper in file hierarchy
  ## - Newer modification time
  ## - Lexical sort
  if a.val.discriminator != b.val.discriminator:
    raise ValueError.newException("JsonSource kinds do not match for comparison")
  if a.val.discriminator in [jsEnv]:
    raise ValueError.newException("No sorting for env JsonSources")
  cmp(a.val.sortKey(), b.val.sortKey())
  
iterator items*(s: FileSelector, reverse = false): Path =
  ## Iterate over *extant* paths of a FileSelector. Low to high precedence.
  ## Dont follow symlinks. Paths returned are relative.
  ## 
  ## Precedence as per [File Precedence]
  ##
  ## **fskPath** *abc*
  ## - A maximum of one path for fskPath
  ## - Relative paths are returned as-is, and are relative to the pwd
  ##
  ## **fskPeg**
  ## - zero or more paths returned
  ## - Paths are relative to their searchspace
  ## - An empty searchspace will be relative to the pwd
  ##
  ## Matched paths are returned in order with following precedence:
  ##    - Deepest in file hierachy, unless tied, then
  ##    - Newest mtime, unless tied, then
  ##    - Lexical order of relative pathe
  ## 
  ## Supports the nimvm for all compilation targets, and the c runtime

  template logicBlock() = 
    case s.discriminator
    of fskPath:
      var extant: bool = extant(s.path)
      if extant:
        yield s.path
    of fskPeg:
      var items: seq[SortKey] = @[]
      # todo may need a nimvm implementation
      var searchspace =
        if $s.searchspace == "":
          util.getCurrentDir().Path
        else:
          s.searchspace
      var item: Path
      
      # Loop all files in dir and extract matches
      template process(itemx: untyped) =
        item = searchspace / $itemx
        if contains($item, s.peg):
          items.add(
            ($item, split($(item.parentDir), '/').len, util.getLastModificationTime($item))
          )
      when nimvm: 
        for itemx in staticWalkDirRec(searchspace, relative = true):
          process(itemx)
      else: 
        when not defined(js):
          for itemx in walkDirRec($searchspace, relative = true):
            process(itemx)
  
      # put in precedence order
      if reverse:
        items.sort(cmp) # low to high
      else:
        items.sort(cmp, SortOrder.Descending)
        
      for itemx in items:
        yield itemx.path.Path
        
  when nimvm: # support nimvm with any compilation target
    logicBlock()
  else: # bail if targeting js and not the nimvm
    when defined(js):
      raise CodepathDefect.newException("File access not supported on JS backend")
    else: # support non js runtime
      logicBlock()
        
  
iterator interpolatedItems*(s: FileSelector, reverse = false): Path =
  for i in s.interpolate().items(reverse):
    yield i

proc initJsonSource*(s: FileSelector): seq[JsonSource] =
  ## Initialize a sequence of JsonSources from a FileSelector
  result = @[]
  for path in s.items():
    result.add path.initJsonSource()

proc `$`*(x: JsonSource): string =
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
    doAssert(x.prefix == "" and x.caseInsensitive == default(bool))
    result.path = x.path.Path
  of jsEnv:
    doAssert(x.path == "")
    result.prefix = x.prefix
    result.caseInsensitive = x.caseInsensitive
  result.jsonStr = x.jsonStr
  result.json = parseJson(result.jsonStr)

proc parse(x: string): JsonNode # forward declaration

proc pretty*(x: JsonSource, indent: int = 2): seq[string] =
  x.json.pretty(indent).splitLines()

proc mergeIn(dest, src: JsonNode): void # forward declaration
proc load(x: JsonSource): tuple[jsonStr: string, json: JsonNode] {.raises: OSError.} =
  ## Read json, located relative to current context directory, and parse
  ##
  ## Cue to json fallback implemented at higher level in stack
  ## Raise OSError for missing sops binary or missing cue binary and no fallback
  ## 
  ## Relative paths are anchored at the context directory: the project dir at
  ## compiletime and the workingdirectory at runtime.
  ## 
  ## Support nimvm on any target and c backend
  when nimvm: discard 
  else:
    when defined(js):
      if x.discriminator in [jsJson, jsCue, jsSops]:
        raise ValueError.newException("File access not supported on JS backend")
        
  # logic for nimvm/ non js backends follows
  var jsonStr: string
  var json: JsonNode
  
  proc pathResolve(path:Path):string =
    ## resolve relative paths rel context dir, return absolute ones
    if util.isAbsolute(path): $path
    else: $(getContextDir() / path)

  # extract json string
  case x.discriminator
  of jsJson:
    var absPath = pathResolve(x.path)
    when nimvm:
      jsonStr = staticRead(absPath)
    else:
      jsonStr = readFile(absPath)
  of jsCue:
    var absPath = pathResolve(x.path)
    var cmd: tuple[output: string, exitCode: int]
    when nimvm:
      cmd = gorgeEx(&"cue export {absPath}")
    else:
      when not defined(js): # dirty hack
        cmd = execCmdEx(&"cue export {absPath}")
    if cmd.exitCode != 0:
      raise newException(IOError, &"Cue export error for file {absPath};\n{cmd.output}")
    jsonStr = cmd.output
  of jsSops:
    var absPath = pathResolve(x.path)
    var cmd: tuple[output: string, exitCode: int]
    when nimvm:
      cmd = gorgeEx(&"sops decrypt --output-type json {absPath}")
    else:
      when not defined(js): # dirty hack
        cmd = execCmdEx(&"sops decrypt --output-type json {absPath}")
    if cmd.exitCode != 0:
      raise
        newException(IOError, &"Sops decrypt error for file {absPath};\n{cmd.output}")
    jsonStr = cmd.output
  of jsEnv: # json string plus object
    var rawEnv: seq[string]
    json = newJObject()
    for k, v in envPairs():
      let kprime =
        if x.caseInsensitive:
          k.toLowerAscii()
        else:
          k
      let xprefix =
        if x.caseInsensitive:
          x.prefix.toLowerAscii()
        else:
          x.prefix
      if kprime.startsWith(xprefix):
        let key = k[xprefix.len ..^ 1]
        rawEnv.add(key & "=" & v)
        if kprime == xprefix: # top level json object merge ie "NIM_={...}"
          var topLevelJson: JsonNode = v.parse()
          json.mergeIn topLevelJson
        else: # nested path
          let path = key.split('_')
          var parent = json
          for part in path[0 ..^ 2]: # make path
            if not parent.contains(part):
              parent[part] = newJObject()
            parent = parent[part]
          parent[path[^1]] = v.parse() # insert
    jsonStr = json.pretty

  # parse string
  if x.discriminator in [jsJson, jsCue, jsSops]:
    try:
      json = parseJson(jsonStr)
    except JsonParsingError as e:
      raise newException(ValueError, &"JSON parsing error for file {x.path};\n{e.msg}")

  (jsonStr, json)

proc reload*(x: var JsonSource): void =
  ## Reload the content of a JsonSource, redo interpolations with current context
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

proc contains*(n: JsonSource, key: varargs[string]): bool =
  ## Determine if a nested key is present in a JsonSource
  n.json.contains(key)

proc `{}`*(n: JsonSource, key: varargs[string]): JsonNode =
  ## Access a nested key in a JsonSource
  return n.json{key}

type Catenatable[T] =
  concept
      proc `&`(x, y: T): T

iterator cartesianProduct[T: Catenatable](a, b: openArray[T], op: proc(x, y: T): T): T =
  ## Compute the cartesian product of two sequences of strings
  for itemA in a:
    for itemB in b:
      yield (op(itemA, itemB))

iterator cartesianProduct[T: Catenatable](a, b: openArray[T]): T =
  for x in cartesianProduct(
    a,
    b,
    proc(x, y: T): T =
      x & y,
  ):
    yield x

proc mergeIn(dest, src: JsonNode): void =
  ## Merge src into dest, overwriting any existing keys in dest
  ## When an object value is found in src, and the corresponding key in dest is
  ## also an object, the merge is done recursively retaining exclusive keys in
  ## dest, clobbering common keys with those from src and adding exclusive keys
  ## from src.
  ## When an array value is found in src, any corresponding key in dest is
  ## overwritten with the array from src.
  for k, v in src:
    case v.kind
    of JObject:
      if dest.contains(k) and dest[k].kind == JObject:
        mergeIn(dest[k], v)
      else:
        dest[k] = v
    else:
      dest[k] = v

proc parse(x: string): JsonNode =
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
  ## 
  ## Used when parsing env var values to json nodes
  var s = x.strip()
  var sLower = s.toLowerAscii()
  if s.len == 0:
    return newJString("")
  if sLower == "null":
    return newJNull()
  if sLower in ["true", "false"]:
    return newJBool(sLower == "true")
  # take out sign only strings so not interpreted as int without number
  if sLower in ["+", "-"]:
    return newJString(s)

  if sLower[0] == '[' and sLower[^1] == ']': # Array
    result = newJArray()
    for element in s[1 ..^ 2].split(','):
      result.add(parse(element))
    return result

  if sLower in toSeq(cartesianProduct(["+", "-", ""], ["nan", "inf"])): # Float special
    return newJFloat(parseFloat(s))

  if sLower[0] in {'+', '-', '0' .. '9', '.', '_'}: # Number possibly
    if sLower[1 ..^ 1].allCharsInSet({'0' .. '9', '_', '.', 'e', '+', '-'}):
      case sLower.count('.')
      of 0:
        return newJInt(parseInt(s.replace("_")))
      of 1:
        return newJFloat(parseFloat(s.replace("_")))
      else:
        discard # continue and try as object or string

  if sLower[0] == '{' and sLower[^1] == '}': # Object (we trimmed whitespace)
    when defined(js): # JS backends std/json does not support raw numbers
      return parseJson(s)
    else:
      # raw*=false will convert to JInt/JFloat instead of JString for numbers
      return parseJson(s, rawIntegers = false, rawFloats = false)

  return newJString(s)

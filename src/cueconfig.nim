## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
##
## Load configuration from cue, json and sops file(s) as well as environment 
## variable(s). At compiletime or runtime. Save configuration loaded at 
## compiletime into the binary for use at runtime. Reload configuration at runtime
## is needed.
## 
## [Cue](https://cuelang.org)
## [SOPS](https://github.com/getsops/sops)
## 
## Configuration sources follow well defined precedence. All configuration merges
## to master json document. Precedent sources will shadow lower precedence
## sources where keys overlap. 
## 
## # Environment Variables
## Environment variables are lifted from the runtime os environment.
## * All vars with matching user specified prefix(es) are used
## * The case sensitive json path is derived from the sans prefix variable name 
##   split on _.
## * Environment variables are merged into the configuraton with highest precedence.
## * Homogeneous arrays, any JSON string, and primitive types supported.
##
## # Configuration Files
## - Regex patterns to match files may be specified, or alternatively file paths
## - Matched files loaded to configuration
## - Missing cue files fallback to json files of same name if present
##
## # [SOPS](https://github.com/getsops/sops) Files | Secrets Management
## This works by loading from sops files from disk to memory, decrypting, making
## the memory available to cue as a fifo file, and then cue will merge this into
## its configuration.
##
## This is disabled at compiletime as you should not compile secrets into
## your binary or javascript. If it were stolen an attacker could extract them.
##
## # API
## getConfig[T](key: varargs[string]|string) is exposed
##
## # JS
## Compilation for the javascript backend is supported. Only compiletime config.
## 
## # Overall flow;
## ## Composing Runtime Config (nimvm, or backend)
## 1. FileSelector is registered
## 2. `loadRegisteredConfig`_ or `loadRegisteredConfigFiles`_ turns selectors to
##    JsonSource and adds them to the config singleton.
## 
import std/[times, json, staticos, paths, tables, strformat, macros, strutils,
  sequtils,sets]
#import std/[time,json, staticos, paths, tables, strformat, macros, strutils]
import cueconfig/[jsonextra, util]

when not defined(js):
  import
    std/[os, osproc, hashes, re] # these wont compile with js backend or are unneeded
# 
type Config = object
  # path: (json string, json node)
  # tables keyed on a label
  # cue, json
  ctCue: OrderedTable[string, JsonSource]
  ctJson: OrderedTable[string, JsonSource]
  rtCue: OrderedTable[string, JsonSource]
  rtJson: OrderedTable[string, JsonSource]
  ctSops: OrderedTable[string, JsonSource]
  rtSops: OrderedTable[string, JsonSource]
  ## this can be set at nimvm runtime but will not make it into compiled binary.
  ## Accomodates secrets access at runtime, and at compiletime to accomodate case
  ## where you may want access to secret material at compiletime.

  # environment variables
  ctEnv: OrderedTable[string, JsonSource]
  rtEnv: OrderedTable[string, JsonSource]

  # these strings must match fieldnames above, precedence low to high
  precedenceClass = ["ctJson", "ctCue", "ctSops", "ctEnv", "rtJson", "rtCue", "rtSops", "rtEnv"]

iterator classes(x: Config, reverse = false): OrderedTable[string, JsonSource] =
  ## iterate json source tables in high to low precedence order
  for ix in 0 ..< x.precedenceClass.len:
    let className =
      if reverse:
        x.precedenceClass[ix]
      else:
        x.precedenceClass[^(1+ix)]
    let table: OrderedTable[string, JsonSource] =
      x.getField(className, OrderedTable[string, JsonSource])
    yield table

iterator pairs(x: Config, reverse = false): tuple[label: string, jsrc: JsonSource] =
  ## iterate json sources in high to low precedence order
  for table in x.classes(reverse):
    #standard iterator yields in insertion order, this is backwards
    let keys = table.keys.toSeq()
    var
      label: string
      jsrc: JsonSource
    for ix in 1 .. keys.len:
      label =
        if reverse:
          keys[(ix - 1)]
        else:
          keys[^ix]
      jsrc = table[label]
      yield (label, jsrc)

iterator items(x: Config, reverse = false): JsonSource =
  ## iterate json sources in precedence order, high to low
  for (_, jsrc) in x.pairs(reverse):
    yield jsrc # # precedence high to low: RUN, BIN, PRJ

# const PRJDIR = Path(getProjectPath()) # project root directory
# const PRJCFG = PRJDIR / "config.cue" # compile

# # static:
# #   echo os.getCurrentDir()
# when nimvm:  # Compiletime.
#   discard
# else: # Runtime.
#   when not defined(js): # js backend has no filesystem access
#     let RUNDIR = paths.getCurrentDir() # directory from which the user has run the bin
#     let BINDIR: Path = Path(getAppDir()) # path to binary file being executed
#     let RUNCFG = RUNDIR / "config.cue" # runtime
#     let BINCFG = BINDIR / "config.cue" # runtime
#     let CFGS = [BINCFG, RUNCFG] # precedence increases  left to right

when defined(js):
  import jsffi
  proc isNode(): bool =
    return defined(nodejs)
    {.
      emit:
        """
    return typeof process !== 'undefined' &&
    process.versions != null &&
    process.versions.node != null;
    """
    .}

  proc isBrowser(): bool =
    not isNode()

proc `$`*(x: Config): string =
  var tmp: seq[string] = @[]
  for label, jsrc in x:
    tmp.add(&"\n== {label&' ':=<78}")
    tmp &= jsrc.pretty
    tmp.add('-'.repeat(80) & "\n")
  return tmp.join("\n")

proc sources*(x: Config): seq[string] =
  ## Get list of loaded config sources
  for s in x:
    result.add $s

type EnvRegistry = seq[tuple[envprefix: string, caseInsensitive: bool]]
var envRegistry: EnvRegistry
var ctEnvRegistry {.compiletime.}: EnvRegistry

proc registerEnvPrefix*(envprefix: string, caseInsensitive: bool = true): void =
  ## Register environment variable prefix for selecting env vars to be loaded
  ##
  ## Use at compiletime or runtime.
  when nimvm:
    ctEnvRegistry.add((envprefix, caseInsensitive))
  else:
    envRegistry.add((envprefix, caseInsensitive))

proc deregisterEnvPrefix*(envprefix: string): void =
  ## Deregister a previously registered env var prefix so it is not loaded on
  ## `reload`_ calls. This will not remove its config content if it were
  ## loaded. Call `loadRegisteredEnvVars`_ or `reload`_ to do that.
  when nimvm:
    ctEnvRegistry = ctEnvRegistry.filterIt(it.envprefix != envprefix)
  else:
    envRegistry = envRegistry.filterIt(it.envprefix != envprefix)

var configRegistry: seq[FileSelector]
var ctConfigRegistry {.compiletime.}: seq[FileSelector] = @[]

proc registerConfigFileSelector*(selectors: varargs[FileSelector]): void =
  ## Register config file path or pattern to be located and loaded at runtime or
  ## compiletime. 
  ## 
  ## # Interpolation
  ## Implemented by `iterator interpolatedItems(FileSelector)`_
  ## FileSelector.searchspace replaces any `{ENV}` or `{getCurrentDir()}`
  ## FileSelector.path replaces any `{ENV}` or `{getCurrentDir()}`
  ## 
  ## # Relative Paths
  ## Alternatively, FileSelector.path or searchspace may be relative, making the
  ## `{getCurrentDir()}` prefix implicit. 
  ## 
  ## # Extensions
  ## The extension must be .cue or .json, .sops.
  ## 
  ## # Extra detail
  ## ## Environment
  ## Environment variables may be used, specify as `{ENVVAR}`, and it will be 
  ## interpolated at the time of use. If the value changes at runtime
  ## then a reload will pick up the new value and it wont be necessary
  ## to deregister the stale and reregister the new selector as it would be if
  ## the env variable were filled in caller side and thus fixed.
  ## 
  ## ## Paths
  ## You may want to use `getCurrentDir`_ or `getAppDir`_ to build your paths for
  ## a selector. getAppDir() is fixed and may be evaluated caller side. As 
  ## `setCurrentDir`_ may be used, any path determined callerside prior to this 
  ## change event will become stale. Therefore a syntax for time of use resolution,
  ## like with environment variables, is provided. Time of use is when a config
  ## reload is done. 

  ## # Environment
  ## Environment variables will always have their leading and trailing whitespace
  ## stripped. Any trailing "/" is stripped before use (you must add this).
  ## Any leading "/" is preserved.
  runnableExamples:
    var matcher: r".*\.config\.(cue|json)$"
    registerConfigFileSelector(
      initFileSelector(Path("{getCurrentDir()}/jog"), matcher), # dynamic
      initFileSelector(Path("jog"), matcher), # equivalent, dynamic
      # equivalent until setCurrentDir changes the current dir (not dynamic)
      initFileSelector(Path(getCurrentDir() / "jog"), matcher),
    )
    # interpolation
    registerConfigFileSelector(
      initFileSelector(Path("{HOME}/.config/kappa/config.cue")),
      initFileSelector(Path("{getCurrentDir()}/{SUBPATH}/config.cue")),
    )
    # all sops files under CONFIGDIR (youll need sops configured for access)
    registerConfigFileSelector(initFileSelector(Path"{CONFIGDIR}", r"\.sops\.yaml$"))
    if RELOAD_EVERYTHING: # registered files, env vars, sops
      reload()
    else: # just registered config files (sops,json,cue)
      loadRegisteredConfig()
    # Remove a file selector
    deregisterConfigFileSelector(
      FileSelector(
        discriminator: fskPath,
        path: Path("{HOME}/.config/kappa/config.cue"), # must match exactly
      )
    )
    # And remove it from the current configuration
    loadRegisteredConfig()

    
  when nimvm:
    for selector in selectors: ctConfigRegistry.add(selector)
  else:
    for selector in selectors: configRegistry.add(selector)
      
proc registerConfigFileSelector*(paths: varargs[string]): void =
  for p in paths:
    registerConfigFileSelector(initFileSelector(Path(p)))
proc registerConfigFileSelector*(patternSelectors:varargs[tuple[searchpath: string, regex: string]]): void =
  for (sp, rx) in patternSelectors:
    registerConfigFileSelector(initFileSelector(Path(sp), rx))

proc deregisterConfigFileSelector*(selector: FileSelector): void =
  ## Deregister a previously registered config file selector so it is not loaded
  ## on `reload`_ calls. This will not remove its config content if it were
  ## loaded. Call `loadRegisteredConfig`_ or `reload`_ to do that.
  when nimvm:
    ctConfigRegistry = ctConfigRegistry.filterIt(hash(it) != hash(selector))
  else:
    configRegistry = configRegistry.filterIt(hash(it) != hash(selector))

type CtSerializedConfig = tuple[env, file: seq[SerializedJsonSource]]
iterator items(x: CtSerializedConfig): SerializedJsonSource =
  ## iterate serialized json sources in precedence order, high to low
  for s in x.env:
    yield s
  for s in x.file:
    yield s

var ctSerializedConfig: CtSerializedConfig
proc buildCompiletimeConfig(): CtSerializedConfig {.compiletime.} =
  ## Commit registered compile time config files and environment variables to the binary.
  ##
  ## Call once only. Subsequent registrations will not be included in the
  ## compiled binary but their config will be available at compiletime.
  var tempEnv: seq[SerializedJsonSource] = @[]
  var tempFiles: seq[SerializedJsonSource] = @[]
  var jsrc: JsonSource
  # load and serialize selected config files
  for s in ctConfigRegistry:
    for p in s:
      jsrc = initJsonSource(p)
      case jsrc.discriminator
      of jsCue, jsJson:
        tempFiles.add(jsrc.serialize)
      of jsEnv:
        assert false, "dead code"
      of jsSops:
        # security safety, no compile in secrets
        raise newException(
          ValueError,
          &"SOPS files may not be committed to compile time configuration for security reasons: {p}",
        )
  # load and serialize compiletime env vars
  for (pfx, insensitive) in ctEnvRegistry:
    tempEnv.add(initJsonSource(pfx, insensitive).serialize)
  (env: tempEnv, file: tempFiles)

proc setCompiletimeConfig(data: CtSerializedConfig): void =
  ## Set the compile time configuration from serialized json sources.
  ##
  ## The template `commitCompiletimeConfig`_ + setter enables delayed evaluation
  ## so registrations may be made prior to committing. This proc transfers the
  ## const data from client module scope to the `cueconfig`_ module scope.
  ctSerializedConfig = data

template commitCompiletimeConfig*(): untyped =
  ## Commit registered compile time config files and environment variables to
  ## the binary.
  ##
  ## Subsequent registrations will not be included in the compiled binary but
  ## their config will be available at compiletime.
  ## 
  ## Workflow Saving Compiletime Config (nimvm only)
  ## 1. FileSelector is registered
  ## 2. Client calls `commitCompiletimeConfig`_,
  ##    - FileSelectors -> JsonSource -> SerializedJsonSource conversions
  ##    - Serialized result is stored in a const scoped to the client module.
  ##    - A call is embedded in the client to send to cueconfig module at runtime.
  const data: CtSerializedConfig = buildCompiletimeConfig()
  setCompiletimeConfig(data)

proc loadRegisteredConfig*()

var configInstance: Config
var configInitialized = false

when nimvm:
  var ctConfigInstance {.compiletime.}: Config
  var ctConfigInitialized {.compiletime.} = false

proc initConfig(): Config =
  ## Initialize configuration from last committed compiletime config.
  ##
  ## Called at compiletime, start with an empty config
  ##
  ## Called at runtime, start with compiled config
  ##
  ## `loadRegisteredConfig`_ may not be called yet as this proc is required to
  ## define `config`_.
  result=Config() # otherwise we dont get defaults for the type
  when nimvm:
    discard
  else:
    for s in ctSerializedConfig:
      let jsrc = s.deserialize
      case jsrc.discriminator
      of jsSops:
        raise newException(
          ValueError,
          &"SOPS files may not be committed to compile time configuration for security reasons: {$jsrc}",
        )
      of jsCue:
        result.ctCue[$jsrc] = jsrc
      of jsJson:
        result.ctJson[$jsrc] = jsrc
      of jsEnv:
        result.ctEnv[$jsrc] = jsrc

proc cfgRuntime(): var Config =
  if not configInitialized:
    configInstance = initConfig()
    configInitialized = true
    loadRegisteredConfig()
  configInstance
when nimvm:
  proc cfgCompiletime(): var Config =
    if not ctConfigInitialized:
      ctConfigInstance = initConfig()
      ctConfigInitialized = true
      loadRegisteredConfig()
    ctConfigInstance
template mcfg(): var Config =
  ## Lazy access to Config singleton
  when nimvm:
    cfgCompiletime()
  else:
    cfgRuntime()
template cfg(): lent Config =
  ## Readonly access to Config singleton
  mcfg()

proc loadRegisteredConfigFiles(): void =
  ## Load all registered config files into config. Old configs removed
  ## 
  ## Json fallback is applied for missing cue files or cue binary. Where Json and
  ## cue files of the same name are found, the json source will be ignored unless
  ## the cue failed to load. Source deduplication will be performed.
  ## 
  ## # Fallback
  ## Where cue files or binary are not available a json file matching the 
  ## same selector (modified to match the json extension) will be used if 
  ## possible. This fallback applies to fskPath and fskRegex. 
  ## 
  ## # Conflicts
  ## Where both .cue and .json files are matched by selectors the .cue file 
  ## will be used and the .json ignored. Aside from this case all matched files 
  ## are loaded.
  ## 
  ## # Precedence
  ## First, precedence is on precedence class. For files in the same class
  ## files deeper in the file hierarchy take precedence. Where multiple files 
  ## exist at the same level file precedence is based on mtime, with latest 
  ## modified taking precedence. Where mtime is not available or the same, 
  ## lexicographical order of full path shall determine, higher in the sort 
  ## order takes precedence.
  ## 
  ## This is implemented by the iteration order of `FileSelector.items()`_
  ## 
  ## If called at compiletime only use the content of `ctConfigRegistry` and
  ## `ctEnvRegistry`, not what may have been comitted by `commitCompiletimeConfig`_
  var cueFiles,jsonFiles,sopsFiles: OrderedTable[string, JsonSource]
  var registry: seq[FileSelector]
  when nimvm:
    registry = ctConfigRegistry
  else:
    registry = configRegistry
  for s in configRegistry:
    for p in s.interpolatedItems(reverse = true): # iterates only files that exist
      var jsrc = initJsonSource(p, s.useJsonFallback)
      case jsrc.discriminator
      of jsSops:
        sopsFiles[$jsrc] = jsrc
      of jsCue:
        cueFiles[$jsrc] = jsrc
      of jsJson:
        jsonFiles[$jsrc] = jsrc
      else:
        assert false, "Unexpected JsonSource discriminator"
        
  # ignore json files where cue of same name exists (one source of truth)
  var cuePaths, jsonPaths: HashSet[tuple[path:Path,key:string]]
  for label, jsrc in cueFiles: 
    cuePaths.incl((jsrc.path, $jsrc))
  for label, jsrc in jsonFiles:
    jsonPaths.incl((jsrc.path, $jsrc))
  for (path,key) in cuePaths:
    var collisions = jsonPaths.countit(it.path==path.changeFileExt("json"))
    if collisions > 0:
      jsonFiles.del(key)
      
  when nimvm:
    mcfg().ctCue = cueFiles
    mcfg().ctJson = jsonFiles
    mcfg().ctSops = sopsFiles
  else:
    cfg().rtCue = cueFiles
    cfg().rtJson = jsonFiles
    cfg().rtSops = sopsFiles

proc loadRegisteredEnvVars() =
  ## Load env vars matching registered prefixes.
  ##
  ## At runtime all previous runtime env vars are replaced and any compiled env
  ## vars are preserved.
  ##
  ## At compiletime all previous compiletime env vars are replaced.
  ##
  ## This behaviour ensures that when you reload, you get a snapshot of the
  ## selected env vars at the time and do not have stale values interfering.
  var updated: OrderedTable[string, JsonSource]
  var registry: EnvRegistry
  when nimvm:
    registry = ctEnvRegistry
  else:
    registry = envRegistry
  for (envprefix, caseInsensitive) in registry:
    var jsrc = initJsonSource(envprefix, caseInsensitive)
    updated[$jsrc] = jsrc

  when nimvm:
    mcfg().ctEnv = updated
  else:
    mcfg().rtEnv = updated

proc loadRegisteredConfig*(): void =
  ## Load all registered config files and env vars
  when not defined(js): # no fs access in js
    loadRegisteredConfigFiles()
  
  when defined(js):
    # js backend, no fs access
    when not isBrowser(): 
      loadRegisteredEnvVars() 
  else:
    loadRegisteredEnvVars()

proc getConfigNodeImpl(key: openarray[string]): JsonNode  =
  ## Get config JsonNode at path `key` (split on '.'), respecting precedence
  ##
  ## Raise an exception if the requested key is not present.
  for label, jsrc in cfg():
    if jsrc.contains(key): # differentiates jsnode{key}=null vs no key
      return jsrc{key}
  let sources: string = cfg().sources().join("\n\t")
  raise newException(ValueError, &"Key '{key}' not found in sources;\n\t{sources}")

template getConfigNode*(key: string): lent JsonNode =
  getConfigNodeImpl(key.split('.'))

template getConfigNode*(key: varargs[string]): lent JsonNode =
  getConfigNodeImpl(key)

proc configHasKey*(key: string): bool =
  ## Check if config has key at path `key` (dot separated)
  ##
  ## Returns true if key exists, false otherwise
  try:
    discard getConfigNode(key)
    return true
  except ValueError:
    return false

# proc getConfig*(): OrderedTable[string, (string, JsonNode)] =
#   ## Get config map
#   cfg()

# Note large floats are parsed to strings (not floats) by std/json `parseJson`
# to preserve precision. `to[J](JsonNode, string)` will only cast a nan, and
# +/-inf strings to float. This template intercepts and casts appropriately.
proc getConfig*[T](key: string): T =
  ## Get a config value, typed per the json primitive, at path `key` (dot separated)
  ##
  ## Request JsonNode type for json objects
  runnableExamples:
    ## Assuming config has;
    ## ```{
    ##   "server": {"port": 8080, "host": "localhost"}
    ##   "bigNumber": 1.234567890123456789e+30
    ##   "homArray": [1,2,3,4,5]
    ##   "mixedArr": [1, "two", 3.0, {"four": 4}]
    ## }````
    import cueconfig
    let port: int = getConfig[int]("server.port")
    let host: string = getConfig[string]("server.host")
    let server: JsonNode = getConfig[JsonNode]("server")
    let hmArr: seq[int] = getConfig[seq[int]]("homArray")
    let mxArr: JsonNode = getConfig[JsonNode]("mixedArr")

  var node = getConfigNode(key)
  when T is JsonNode:
    return node
  if node.kind == JString:
    when T is SomeInteger:
      return parseInt(node.getStr())
    elif T is SomeFloat:
      return parseFloat(node.getStr())
    else:
      discard
  return node.to(T)

template getConfig*[T](key: varargs[string]): T =
  getConfig[T](key.join("."))

proc showConfig*(): string = ## Show current configuration as string
  $cfg()

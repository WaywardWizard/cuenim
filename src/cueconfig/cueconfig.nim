## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
##
## .. importdoc:: cueconfig/jsonextra.nim
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
import
  std/
    [times, json, paths, tables, strformat, macros, strutils, sequtils, sets, algorithm, hashes]
#import std/[time,json, staticos, paths, tables, strformat, macros, strutils]
import cueconfig/[jsonextra, util]
# when nimvm:
#   import system/nimscript
  
when not defined(js):
  import std/[os] # these wont compile with js backend or are unneeded
#
type
  Config = ref object
    # path: (json string, json node)
    # tables keyed on a label
    # cue, json
    ctCue = OrderedTableRef[Hash, JsonSource].new()
    ctJson = OrderedTableRef[Hash, JsonSource].new()
    rtCue = OrderedTableRef[Hash, JsonSource].new()
    rtJson = OrderedTableRef[Hash, JsonSource].new()
    ctSops = OrderedTableRef[Hash, JsonSource].new()
    rtSops = OrderedTableRef[Hash, JsonSource].new()
    ## this can be set at nimvm runtime but will not make it into compiled binary.
    ## Accomodates secrets access at runtime, and at compiletime to accomodate case
    ## where you may want access to secret material at compiletime.

    # environment variables
    ctEnv = OrderedTableRef[Hash, JsonSource].new()
    rtEnv = OrderedTableRef[Hash, JsonSource].new()
    serializedConfigChecksum: Hash = 0
    stale = false

    # these strings must match fieldnames above, precedence low to high
    precedenceClass =
      ["ctJson", "ctCue", "ctSops", "ctEnv", "rtJson", "rtCue", "rtSops", "rtEnv"]

  EnvRegistry = seq[tuple[envprefix: string, caseInsensitive: bool]]
  ConfigRegistry = seq[FileSelector]
  SerializedConfig = tuple[env, file: seq[SerializedJsonSource]]

## `dualVar`_ for accessibility at both compile and runtime, except independant
## these maintain a dual state, One for compiletime and one for runtime.
dualVar(envRegistry, EnvRegistry) ## to init JsonSource
dualVar configRegistry, ConfigRegistry ## selectors for files to init JsonSource
dualVar configInstance, Config ## singleton
dualVar serializedConfig, SerializedConfig ## type assignable to a const

dualInitConfigInstance Config.new()
dualInitEnvRegistry @[]
dualInitConfigRegistry @[]

proc hash(x: Config): Hash =
  ## Guaranteed to change if order or content changes
  result = x.stale.int.hash
  result = result !& x.precedenceClass.hash
  result = result !& x.ctJson.keys().toSeq().toHashSet().hash
  result = result !& x.ctCue.keys().toSeq().toHashSet().hash
  result = result !& x.ctSops.keys().toSeq().toHashSet().hash
  result = result !& x.ctEnv.keys().toSeq().toHashSet().hash
  result = result !& x.rtJson.keys().toSeq().toHashSet().hash
  result = result !& x.rtCue.keys().toSeq().toHashSet().hash
  result = result !& x.rtSops.keys().toSeq().toHashSet().hash
  result = result !& x.rtEnv.keys().toSeq().toHashSet().hash
  result = !$result

iterator classes(x: Config, reverse = false): OrderedTableRef[Hash, JsonSource] =
  ## iterate json source tables in low to high precedence order
  ## reverse=false: low to high precedence order
  ## reverse=true: high to low precedence order
  for ix in 0 ..< x.precedenceClass.len:
    let className =
      if reverse:
        x.precedenceClass[^(1 + ix)]
      else:
        x.precedenceClass[ix]
    yield x.getField(className, OrderedTableRef[Hash, JsonSource])

iterator pairs(x: Config, reverse = false): tuple[label: Hash, jsrc: JsonSource] =
  ## iterate json sources in precedence order, low to high
  ## reverse=false: low to high precedence order (and first to last added for env)
  ## reverse=true: high to low precedence order (and last to first added for env)
  ## have in the tables of the config object
  for table in x.classes(reverse):
    #standard iterator yields in insertion order, this is backwards
    assert not table.isnil()
    let keys = table.keys.toSeq()
    var
      label: Hash
      jsrc: JsonSource
    for ix in 1 .. keys.len:
      label =
        if reverse:
          keys[^ix]
        else:
          keys[(ix - 1)]
      jsrc = table[label]
      yield (label, jsrc)

iterator items(x: Config, reverse = false): JsonSource =
  ## iterate json sources in precedence order, low to high
  ## reverse=false: low to high precedence order (and first to last added for env)
  ## reverse=true: high to low precedence order (and last to first added for env)
  for (_, jsrc) in x.pairs(reverse):
    yield jsrc # # precedence high to low: RUN, BIN, PRJ

# const PRJDIR = Path(getProjectPath()) # project root directory
# let RUNDIR = paths.getCurrentDir() # directory from which the user has run the bin
# let BINDIR: Path = Path(getAppDir()) # path to binary file being executed

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
  tmp.add(&"\nConfig Hash: {x.hash().intToStr}, stale: {x.stale}")
  for label, jsrc in x:
    tmp.add(&"== {$jsrc&' ':=<56}{' '& $label:->20} ==")
    tmp &= jsrc.pretty
    tmp.add('-'.repeat(80) & "\n")
  return tmp.join("\n")

proc sources(x: Config): seq[string] =
  ## Get list of loaded config sources
  for s in x:
    result.add $s

proc getConfigLazy(update: bool): var Config # forward

proc registerEnvPrefix*(envprefix: string, caseInsensitive: bool = true): void =
  ## Register environment variable prefix for selecting env vars to be loaded
  ##
  ## Use at compiletime or runtime.
  var item = (envprefix, caseInsensitive)
  for ix in dualGetEnvRegistry():
    if hash(ix) == hash(item):
      return
  dualMGetEnvRegistry().add(item)
  dualMGetConfigInstance().stale = true

proc deregisterEnvPrefix*(envprefix: string): void =
  ## Deregister a previously registered env var prefix so it is not loaded on
  ## `reload`_ calls. This will not remove its config content if it were
  ## loaded. Call `loadRegisteredEnvVars`_ or `reload`_ to do that.
  dualSetEnvRegistry dualGetEnvRegistry().filterIt(it.envprefix != envprefix)
  dualMGetConfigInstance().stale = true

proc registerConfigFileSelectorImpl(selectors: varargs[FileSelector]): void =
  var known: HashSet[int]
  # deduplicate
  for i in dualMGetConfigRegistry():
    known.incl(hash(i))
  for selector in selectors:
    if known.contains(hash(selector)):
      continue
    dualMGetConfigInstance().stale = true
    dualMGetConfigRegistry().add(selector)

proc registerConfigFileSelector*(selector: FileSelector): void =
  ## Register config file path or pattern to be located and loaded at runtime or
  ## compiletime.
  ##
  ## # Interpolation
  ## Occurs at the time the config file selected is *loaded*, see
  ## `loadRegisteredConfig`_.
  ##
  ## Implemented by `interpolatedItems`_ and `interpolate`_
  ## FileSelector.searchspace replaces any `{ENV}` or `{getContextDir()}`
  ## FileSelector.path replaces any `{ENV}` or `{getContextDir()}`
  ##
  ## # Relative Paths
  ## Alternatively, FileSelector.path or searchspace may be relative, making the
  ## `{getContextDir()}` prefix implicit. At binary runtime this is the working
  ## directory. Modify it with `setCurrentDir`_. At compiletime, this is the
  ## project directory (folder containing file being compiled) and fixed.
  ##
  ## At compiletime note, the working directory is wherever the compiler was
  ## run from and furthermore cannot be changed with `nimscript.cd()`. This means
  ## the working directory is uncontrollable and thus the context directory is
  ## the project directory instead.
  ##
  ## # Extensions
  ## The extension must be .cue or .json, .sops.
  ##
  ## # Extra detail
  ## ## Environment
  ## Environment variables may be used, specify as `{ENVVAR}`, and it will be
  ## interpolated at the time of load. If the value changes at runtime
  ## then a reload will pick up the new value and it wont be necessary
  ## to deregister the stale and reregister the new selector as it would be if
  ## the env variable were filled in caller side and thus fixed.
  ##
  ## ## Paths
  ## You may want to use `getCurrentDir`_ or `getAppDir`_ to build your paths for
  ## a selector. getAppDir() is fixed and may be evaluated caller side. As
  ## `setCurrentDir`_ may be used, any path determined callerside prior to this
  ## change event will become stale. Therefore a syntax for time of load resolution,
  ## like with environment variables, is provided. Time of use is when a config
  ## reload is done.
  ##
  ## # Environment
  ## Environment variables will always have their leading and trailing whitespace
  ## stripped.
  runnableExamples:
    var matcher: r".*\.config\.(cue|json)$"
    registerConfigFileSelector(
      initFileSelector(Path("{getContextDir()}/jog"), matcher), # dynamic
      initFileSelector(Path("jog"), matcher), # equivalent, dynamic
      # equivalent until setCurrentDir changes the current dir (not dynamic)
      #initFileSelector(Path(getCurrentDir() / "jog"), matcher),
    )
    # interpolation
    registerConfigFileSelector(
      initFileSelector(Path("{HOME}/.config/kappa/config.cue")),
      initFileSelector(Path("{getContextDir()}/{SUBPATH}/config.cue")),
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
  registerConfigFileSelectorImpl(selector)

proc registerConfigFileSelector*(pselector: varargs[Path]): void =
  ## Convenience fskPath registration automatically fallback to json
  for p in pselector:
    registerConfigFileSelector(initFileSelector(p))

proc registerConfigFileSelector*(paths: varargs[string], useJsonFallback = true): void =
  for p in paths:
    registerConfigFileSelector(initFileSelector(Path(p), useJsonFallback))

proc registerConfigFileSelector*(
    patternSelectors:
      varargs[tuple[searchpath: string, peg: string, useJsonFallback = true]]
): void =
  for (sp, rx, useJsonFallback) in patternSelectors:
    registerConfigFileSelector(initFileSelector(Path(sp), rx, useJsonFallback))

proc registerConfigFileSelector*(
    rxselectors: varargs[tuple[searchpath, peg: string]]
): void =
  ## Convenience fskPeg registration automatically fallback to json
  for (searchpath, peg) in rxselectors:
    registerConfigFileSelector(initFileSelector(Path(searchpath), peg, true))

proc registerConfigFileSelector*(
    search: Path, peg: string, useJsonFallback: bool
): void =
  registerConfigFileSelector(initFileSelector(search, peg, useJsonFallback))

proc deregisterConfigFileSelector*(selector: FileSelector): void =
  ## Deregister a previously registered config file selector so it is not loaded
  ## on `reload`_ calls. This will not remove its config content if it were
  ## loaded. Call `loadRegisteredConfig`_ or `reload`_ to do that.
  dualSetConfigRegistry dualGetConfigRegistry().filterIt(hash(it) != hash(selector))
  dualMGetConfigInstance().stale = true

proc deregisterConfigFileSelector*(path:string) =
  ## Any file matching path
  dualSetConfigRegistry dualGetConfigRegistry().filterIt(not it.match(path))
  dualMGetConfigInstance().stale = true
 
proc deregisterConfigFileSelector*(searchpath:string, peg:string) =
  ## Any file matching path
  dualSetConfigRegistry dualGetConfigRegistry().filterIt(not it.match(searchpath,peg))
  dualMGetConfigInstance().stale = true

iterator items(x: SerializedConfig): SerializedJsonSource =
  ## iterate serialized json sources in precedence order, high to low
  for s in x.env:
    yield s
  for s in x.file:
    yield s

proc buildCompiletimeConfig(): SerializedConfig {.compiletime.} =
  ## Commit registered compile time config files and environment variables to
  ## the binary. This loads the sources registered at calltime. Interpolation
  ## will occur at calltime this time, thus the context dir and environment
  ## vars will be as they are at calltime.
  ##
  ## Call once only. Subsequent registrations will not be included in the
  ## compiled binary but their config will be available at compiletime.
  ##
  ## Where the serialized config is a fskPath or fskPeg fileselector with a
  ## relative search path then it will *not* be relative to the working directory
  ## but the *project directory*. This is because `nimscript.cd()` does not work
  ## for .nim files, making the working directory uncontrollable other than by
  ## running the compiler in a certain directory. `{getContextDir()}` will also
  ## be replaced with the project directory.
  var tempEnv: seq[SerializedJsonSource] = @[]
  var tempFiles: seq[SerializedJsonSource] = @[]
  var jsrc: JsonSource
  # load and serialize selected config files
  for s in dualGetConfigRegistry(): # FileSelector
    # Add check for missing file
    for p in s: # Path
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
          &"DecryptedSOPS files should not be committed to compile time configuration for security reasons: {p}",
        )
  # load and serialize compiletime env vars
  for (pfx, insensitive) in dualGetEnvRegistry():
    tempEnv.add(initJsonSource(pfx, insensitive).serialize)
  (env: tempEnv, file: tempFiles)

template commitCompiletimeConfig*(): untyped =
  ## Commit registered compile time config files and environment variables to
  ## the binary. Call in a non static context.
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
  ##
  ## Constraints, Requirements, Rationale, Details
  ## * The single mechanism for persisting data across the compiletime/runtime
  ##   boundary is const. We must use a const.
  ## * Const are evaluated by the compiler when they are encountered
  ## * We need to delay evaluation of the const until after registrations
  ## * The client module calls this after registrations.
  ## * The const will exist in the client module scope, and this is necessary
  ##   for the const to be evaluated after registrations.
  ## * The cueconfig module requires access to the consts data.
  ## * AST to transfer the const data to cueconfig module scope is also inserted.
  ## * This transfer must be made at runtime.
  when nimvm:
    # because calling at compiletime set the vmserializedConfig variable which
    # will not be accessible at runtime. We have to use a runtime variable as
    # our intermodule compiletime transport
    raise newException(
      ValueError,
      "commitCompiletimeConfig may only be used in non-nimvm (runtime) context",
    )
  const data: SerializedConfig = buildCompiletimeConfig()
    ## defined at \
    ## compiletime in the module calling this template, at the callsite

  dualSetSerializedConfig data ## data available at compiletime for \
    ## `showComittedRegistrations`_ and runtime for config initialization
  dualMGetConfigInstance().stale = true

proc loadRegisteredConfig()

template rtTableForSource(s: JsonSource): OrderedTableRef =
  case s.discriminator
  of jsSops:
    dualMGetConfigInstance().rtSops
  of jsCue:
    dualMGetConfigInstance().rtCue
  of jsJson:
    dualMGetConfigInstance().rtJson
  of jsEnv:
    dualMGetConfigInstance().rtEnv

template ctTableForSource(s: JsonSource): OrderedTableRef =
  case s.discriminator
  of jsSops:
    dualMGetConfigInstance().ctSops
  of jsCue:
    dualMGetConfigInstance().ctCue
  of jsJson:
    dualMGetConfigInstance().ctJson
  of jsEnv:
    dualMGetConfigInstance().ctEnv

proc addRtSourceToConfig(s: JsonSource) =
  rtTableForSource(s)[s.hash] = s

proc addCtSourceToConfig(s: JsonSource) =
  ctTableForSource(s)[s.hash] = s

proc addSource(s: JsonSource) =
  when nimvm:
    addCtSourceToConfig(s)
  else:
    addRtSourceToConfig(s)

proc hash(x: SerializedConfig): Hash =
  ## Order independant hash
  var hashes: seq[Hash] = x.mapIt(it.hash).toSeq()
  sort[Hash](hashes)
  hashes.hash()

proc loadCompiletimeComittedConfig() =
  ## Load compiletime comitted config and return true if this resulted in change
  ##
  ## Where the serialized config has not changed do nothing.
  ##
  ## Does not remove previously loaded config.
  var c = dualMGetConfigInstance()
  var sconfig = dualGetSerializedConfig()
  if c.serializedConfigChecksum != sconfig.hash():
    for s in sconfig:
      let jsrc = s.deserialize
      if jsrc.discriminator == jsSops:
        raise newException(
          ValueError,
          &"SOPS files may not be committed to compile time configuration for security reasons: {$jsrc}",
        )
      addCtSourceToConfig(jsrc)
    dualMGetConfigInstance().serializedConfigChecksum = sconfig.hash()

proc refresh() =
  ## Refresh the config singleton to match the comitted and registered config
  loadCompiletimeComittedConfig()
  loadRegisteredConfig()

proc getConfigLazy(update: bool): var Config =
  ## Return mutable config singleton. update will re-load config as needed
  if update:
    if dualGetConfigInstance().stale:
      refresh()
      dualMGetConfigInstance().stale = false
  result = dualMGetConfigInstance()

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
  ## possible. This fallback applies to fskPath and fskPeg.
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
  ## If called at compiletime only use the content of envRegistry, not what may
  ## have been comitted by `commitCompiletimeConfig`_
  ##
  var cueFiles, jsonFiles, sopsFiles = OrderedTableRef[Hash, JsonSource].new()
  var registry: ConfigRegistry = dualGetConfigRegistry() # seq[FileSelector]
  for s in registry: # FileSelector
    for p in s.interpolatedItems(reverse = true): # Path (extant ones)
      var jsrc = initJsonSource(p, s.useJsonFallback)
      case jsrc.discriminator
      of jsSops:
        sopsFiles[jsrc.hash] = jsrc
      of jsCue:
        cueFiles[jsrc.hash] = jsrc
      of jsJson:
        jsonFiles[jsrc.hash] = jsrc
      else:
        assert false, "Unexpected JsonSource discriminator"

  # ignore json files where cue of same name exists (one source of truth)
  var cueItems, jsonItems: HashSet[tuple[path: Path, key: Hash]]
  for label, jsrc in cueFiles:
    cueItems.incl((jsrc.path, jsrc.hash))
  for label, jsrc in jsonFiles:
    jsonItems.incl((jsrc.path, jsrc.hash))
  let jsonPaths = toHashSet[Path](jsonItems.mapIt(it.path))
  for (path, key) in cueItems:
    if jsonPaths.contains(path.changeFileExt("json")):
      jsonFiles.del(key)

  # sort ordered tables by precedence not insertion order, low to high to match
  # the (c|r)tEnv tables which are ordered earliest to latest add, which is low
  # to high precedence.
  sopsFiles.sort(cmpFiles)
  cueFiles.sort(cmpFiles)
  jsonFiles.sort(cmpFiles)

  # replace (dont keep old registrations)

  when nimvm:
    dualMGetConfigInstance().ctCue = cueFiles
    dualMGetConfigInstance().ctJson = jsonFiles
    dualMGetConfigInstance().ctSops = sopsFiles
  else:
    dualMGetConfigInstance().rtCue = cueFiles
    dualMGetConfigInstance().rtJson = jsonFiles
    dualMGetConfigInstance().rtSops = sopsFiles

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
  var updated = OrderedTableRef[Hash, JsonSource].new()
  var registry: EnvRegistry = dualGetEnvRegistry()
  for (envprefix, caseInsensitive) in registry:
    var jsrc = initJsonSource(envprefix, caseInsensitive)
    updated[jsrc.hash] = jsrc

  when nimvm:
    dualMGetConfigInstance().ctEnv = updated
  else:
    dualMGetConfigInstance().rtEnv = updated

proc loadRegisteredConfig(): void =
  ## Load all registered config files and env vars
  ##
  ## Because the config getters are lazy update this would not need to
  ## be exposed. However env vars, or the working directory can be updated
  ## and this would need to be signalled by calling this proc.
  when not defined(js): # no fs access in js
    loadRegisteredConfigFiles()
    loadRegisteredEnvVars()
  else:
    # js backend, no fs access
    when not isBrowser():
      loadRegisteredEnvVars()

proc reload*() =
  loadRegisteredConfig()

proc getConfigNodeImpl(key: openarray[string]): JsonNode =
  ## Get config JsonNode at path `key` (split on '.'), respecting precedence
  ##
  ## Raise an exception if the requested key is not present.
  var cfg: Config = getConfigLazy(update = true)
  for label, jsrc in getConfigLazy(update = true).pairs(reverse = true):
    # high to low precedence
    if jsrc.contains(key): # differentiates jsnode{key}=null vs no key
      return jsrc{key}
  let sources: string = dualMGetConfigInstance().sources().join("\n\t")
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

# Note large floats are parsed to strings (not floats) by std/json `parseJson`
# to preserve precision. `to[J](JsonNode, string)` will only cast a nan, and
# +/-inf strings to float. This template intercepts and casts appropriately.
proc getConfig*[T](key: string): T =
  ## Get a config value, typed per the json primitive, at path `key` (dot separated)
  ##
  ## Request JsonNode type for json objects
  # runnableExamples:
  #   ## Assuming config has;
  #   ## ```{
  #   ##   "server": {"port": 8080, "host": "localhost"}
  #   ##   "bigNumber": 1.234567890123456789e+30
  #   ##   "homArray": [1,2,3,4,5]
  #   ##   "mixedArr": [1, "two", 3.0, {"four": 4}]
  #   ## }````
  #   import cueconfig
  #   let port: int = getConfig[int]("server.port")
  #   let host: string = getConfig[string]("server.host")
  #   let server: JsonNode = getConfig[JsonNode]("server")
  #   let hmArr: seq[int] = getConfig[seq[int]]("homArray")
  #   let mxArr: JsonNode = getConfig[JsonNode]("mixedArr")
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

proc showSources*(): string =
  ## Show list of loaded config sources
  result = dualMGetConfigInstance().sources().join("\n")

proc checksumConfig*(): int = ## Checksum config
  hash(getConfigLazy(update = true))

proc clearConfigAndRegistrations*(): void =
  ## Clear all runtime configuration and registered configuration
  ##
  ## Compiletime configuration is preserved.
  when not defined(js): # no fs access in js
    dualMGetConfigInstance().rtCue = OrderedTableRef[Hash, JsonSource]()
    dualMGetConfigInstance().rtJson = OrderedTableRef[Hash, JsonSource]()
    dualMGetConfigInstance().rtSops = OrderedTableRef[Hash, JsonSource]()
  dualMGetConfigInstance().rtEnv = OrderedTableRef[Hash, JsonSource]()
  dualSetEnvRegistry @[]
  dualSetConfigRegistry @[]
  dualMGetConfigInstance().stale = true

proc showRegistrations*(): string =
  ## Print registered config file selectors and env var prefixes
  var registry: ConfigRegistry = dualGetConfigRegistry() #seq[FileSelector]
  var msg: string
  var tmp: seq[string] = @[]
  when nimvm:
    msg = "Compiletime"
  else:
    msg = "Runtime"
  tmp.add &"{msg} Registrations;"
  tmp.add "\t" & " Config File Selectors:"
  for s in registry:
    tmp.add "\t\t" & $s
  tmp.add "\t" & " Env Var Prefixes:"
  for (pfx, insensitive) in dualGetEnvRegistry():
    tmp.add "\t\t" & pfx & " (case insensitive: " & $insensitive & ")"
  return tmp.join("\n")

proc showComittedRegistrations*(): string =
  ## Show registrations comitted
  ##
  ## If called at compiletime, no SerializedConfig is available.
  var tmp: seq[string] = @[]
  tmp.add "Compiletime Comitted Registrations;"
  for item in dualMGetSerializedConfig():
    tmp.add &"\t{$item}"
  return tmp.join("\n")

proc showConfig*(): string = ## Show current configuration as string
  &"Context Directory: {getContextDir()}\n" & showRegistrations() & "\n" &
    showComittedRegistrations() & $getConfigLazy(update = true)

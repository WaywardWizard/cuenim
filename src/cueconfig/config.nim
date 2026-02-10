## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
##
## This module contains core configuration management and access.
import
  std/[
    times, json, paths, tables, strformat, macros, strutils, sequtils, sets, algorithm,
    hashes, sugar,
  ]
import cueconfig/[jsonextra, util, exceptions]
when not defined(js):
  import std/[os] # these wont compile with js backend or are unneeded

type
  Config = ref object
    ctCue = OrderedTableRef[Hash, JsonSource].new()
    ctJson = OrderedTableRef[Hash, JsonSource].new()
    rtCue = OrderedTableRef[Hash, JsonSource].new()
    rtJson = OrderedTableRef[Hash, JsonSource].new()
    ctSops = OrderedTableRef[Hash, JsonSource].new()
    rtSops = OrderedTableRef[Hash, JsonSource].new()
    ctEnv = OrderedTableRef[Hash, JsonSource].new()
    rtEnv = OrderedTableRef[Hash, JsonSource].new()
    serializedConfigChecksum: Hash = 0
    stale = false

    ## these strings must match fieldnames above, precedence low to high
    precedenceClass =
      ["ctJson", "ctCue", "ctSops", "ctEnv", "rtJson", "rtCue", "rtSops", "rtEnv"]

  EnvRegistry = seq[tuple[envprefix: string, caseInsensitive: bool]]
  ConfigRegistry = seq[FileSelector]
  SerializedConfig = tuple[env, file: seq[SerializedJsonSource]]

## for accessibility at both compile and runtime, except independant
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

when defined(js):
  import jsffi
  proc isNode*(): bool =
    return defined(nodejs)
    {.
      emit:
        """
    return typeof process !== 'undefined' &&
    process.versions != null &&
    process.versions.node != null;
    """
    .}

  proc isBrowser*(): bool =
    not isNode()

proc `$`*(x: Config): string =
  var tmp: seq[string] = @[]
  tmp.add(&"\nConfig Hash: {x.hash().intToStr}, stale: {x.stale}")
  for label, jsrc in x.pairs():
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
  # `reload`_ calls. This will not remove its config content if it were
  # loaded. Call `loadRegisteredEnvVars`_ or `reload`_ to do that.
  dualSetEnvRegistry dualGetEnvRegistry().filterIt(it.envprefix != envprefix)
  dualMGetConfigInstance().stale = true

proc registerConfigFileSelectorImpl(selectors: varargs[FileSelector]): void =
  var known: HashSet[int]
  # deduplicate
  for i in dualMGetConfigRegistry():
    known.incl(hash(i))
  for selector in selectors:
    if known.contains(hash(selector)):
      # Update boolean attributes require and useJsonFallback
      for i in 0 ..< dualGetConfigRegistry().len:
        if hash(dualGetConfigRegistry()[i]) == hash(selector):
          dualMGetConfigRegistry()[i].require = selector.require
          dualMGetConfigRegistry()[i].useJsonFallback = selector.useJsonFallback
          dualMGetConfigInstance().stale = true
          break # only one match possible
      continue
    dualMGetConfigInstance().stale = true
    dualMGetConfigRegistry().add(selector)

proc registerConfigFileSelector*(selector: FileSelector): void =
  ## Register config file path or pattern to be located and loaded to config
  #  # runnableExamples:
  #   import std/[os, paths]
  #   import cueconfig/util
  #   var matcher = r".*\.config\.(cue|json)$"
  #   # interpolation on searchpath/fskPeg type selectors
  #   registerConfigFileSelector(
  #     ("{getContextDir()}/jog", matcher), # interpolated at load
  #     ("jog", matcher), # equivalent, relpath implicitly anchored to context dir
  #     # equivalent until setCurrentDir changes the current dir (not dynamic)
  #     ((string(paths.getCurrentDir() / "jog"), matcher)),
  #   )
  #   # interpolation on path
  #   registerConfigFileSelector(
  #     "{HOME}/.config/kappa/config.cue", # Path fine
  #     "{getContextDir()}/{SUBPATH}/config.cue", # strings also
  #     useJsonFallback = true,
  #   )
  #   # all sops files under CONFIGDIR (youll need sops configured for access)
  #   registerConfigFileSelector(
  #     Path"{CONFIGDIR}", r"\.sops\.yaml$", useJsonFallback = false
  #   )
  #   const RELOAD_EVERYTHING = false
  #   if RELOAD_EVERYTHING: # registered files, env vars, sops
  #     reload()
  #   else: # just registered config files (sops,json,cue)
  #     loadRegisteredConfig()
  #   # Remove a file selector
  #   deregisterConfigFileSelector(
  #     FileSelector(
  #       discriminator: fskPath,
  #       path: Path("{HOME}/.config/kappa/config.cue"), # must match exactly
  #     )
  #   )
  # And remove it from the current configuration
  registerConfigFileSelectorImpl(selector)

proc registerConfigFileSelector*(
    pselector: varargs[Path], useJsonFallback = false, require = true
): void =
  ## Paths to files to use in config. If require then missing files raise.
  ## For cue files only, useJsonFallback will attempt to load a json file of
  ## the same name if missing or the cue binary is not available.
  for p in pselector:
    registerConfigFileSelector(initFileSelector(p, useJsonFallback, require))

proc registerConfigFileSelector*(
    paths: varargs[string], useJsonFallback = false, require = true
): void =
  for p in paths:
    registerConfigFileSelector(initFileSelector(Path(p), useJsonFallback, require))

proc registerConfigFileSelector*(
    patternSelectors: varargs[
      tuple[searchpath: string, peg: string, useJsonFallback = false, require = true]
    ]
): void =
  for (sp, peg, useJsonFallback, require) in patternSelectors:
    registerConfigFileSelector(
      initFileSelector(Path(sp), peg, useJsonFallback, require)
    )

proc registerConfigFileSelector*(
    rxselectors: varargs[tuple[searchpath, peg: string]],
    useJsonFallback = false,
    require = true,
): void =
  for (searchpath, peg) in rxselectors:
    registerConfigFileSelector(
      initFileSelector(Path(searchpath), peg, useJsonFallback, require)
    )

proc registerConfigFileSelector*(
    search: string, peg: string, useJsonFallback = false, require = true
): void =
  registerConfigFileSelector(
    initFileSelector(search.Path, peg, useJsonFallback, require)
  )

proc registerConfigFileSelector*(
    search: Path, peg: string, useJsonFallback = false, require = true
): void =
  registerConfigFileSelector(initFileSelector(search, peg, useJsonFallback, require))

proc deregisterConfigFileSelector*(selector: FileSelector): void =
  ## Deregister a previously registered config file selector so it is not loaded
  # on `reload`_ calls. This will not remove its config content if it were
  # loaded. Call `loadRegisteredConfig`_ or `reload`_ to do that.
  let lenBefore = dualGetConfigRegistry().len
  dualSetConfigRegistry dualGetConfigRegistry().filterIt(hash(it) != hash(selector))
  let lenAfter = dualGetConfigRegistry().len
  if lenBefore == lenAfter:
    raise newException(
      ValueError,
      &"Selector {$selector} not found in registry;\n{$dualGetConfigRegistry()}",
    )
  dualMGetConfigInstance().stale = true

proc deregisterConfigFileSelector*(path: string) =
  ## Any file matching path
  dualSetConfigRegistry dualGetConfigRegistry().filterIt(not it.match(path))
  dualMGetConfigInstance().stale = true

proc deregisterConfigFileSelector*(searchpath: string, peg: string) =
  ## Any file matching path
  dualSetConfigRegistry dualGetConfigRegistry().filterIt(not it.match(searchpath, peg))
  dualMGetConfigInstance().stale = true

iterator items*(x: SerializedConfig): SerializedJsonSource =
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
          ConfigError,
          &"DecryptedSOPS files should not be committed to compile time configuration for security reasons: {p}",
        )
  # load and serialize compiletime env vars
  for (pfx, insensitive) in dualGetEnvRegistry():
    tempEnv.add(initJsonSource(pfx, insensitive).serialize)
  (env: tempEnv, file: tempFiles)

template commitCompiletimeConfig*(): untyped =
  ## Commit registered compile time config files and environment variables to
  ## the binary. Call in a non static context, for js or c backends
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
    raise ConfigError.newException(
      "commitCompiletimeConfig may only be used in non-nimvm (runtime) context"
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
  var hashes = newSeq[Hash]()
  for ix in x.items():
    hashes.add(hash(ix))
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
          ConfigError,
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
  ## When processing registrations, if a registration without any matched files
  ## is found an exception will be raised for the user to handle. Except for when
  ## a selector that includes a cue file with json fallback is enabled. Fallback
  ## is applied for missing cue files or cue binary but not for invalid cue files.
  ##
  ## Where Json and cue files of the same name are found, the json source will
  ## be ignored unless the cue failed to load. Never will both json and cue be
  ## loaded of the same path. Source deduplication will be performed.
  ##
  ## Fallback:
  ## Where cue files or binary are not available a json file matching the
  ## same selector (modified to match the json extension) will be used if
  ## possible. This fallback applies to fskPath and fskPeg.
  ##
  ## Conflicts:
  ## Where both .cue and .json files are matched by selectors the .cue file
  ## will be used and the .json ignored. Aside from this case all matched files
  ## are loaded.
  ##
  ## Precedence:
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
  var cueFiles, jsonFiles, sopsFiles = OrderedTableRef[Hash, JsonSource].new()
  var registry: ConfigRegistry = dualGetConfigRegistry() # seq[FileSelector]
  for s in registry: # FileSelector
    # check for empty selectors
    var selectorEmpty = true
    for p in s.interpolatedItems(reverse = true): # Path (extant ones)
      selectorEmpty = false
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
    if selectorEmpty and s.require:
      raise ConfigError.newException(
        &"Config file selector target not readable or matched no files: {s}\nContext dir: {getContextDir()}"
      )

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
  when nimvm: # nimvm any backend
    loadRegisteredConfigFiles()
    loadRegisteredEnvVars()
  else:
    when defined(js):
      when isNode():
        loadRegisteredEnvVars()
    else: # c backend
      loadRegisteredConfigFiles()
      loadRegisteredEnvVars()

proc reload*() =
  ## Reload all registered config files and env vars, but leave compiletime
  loadRegisteredConfig()

proc getConfigNodeImpl(key: openarray[string]): JsonNode =
  ## Get config JsonNode at path `key` (split on '.'), for highest precedence
  ## source. Where the node is a JObject, then create a new node and merge all
  ## values (see `mergeIn`) across all sources into it respecting precedence.
  ##
  ## Raise an exception if the requested key is not present.
  var cfg: Config = getConfigLazy(update = true)
  # this is going to be modified, we dont want to modify originals
  var resultObject: JsonNode = %*{}

  for label, jsrc in cfg.pairs(reverse = true):
    # high to low precedence
    if jsrc.contains(key): # differentiates jsnode{key}=null vs no key
      if jsrc{key}.kind == JObject:
        # merge all config source contributions to single node
        for label2, jsrc2 in cfg.pairs(): # low to high
          if jsrc2.contains(key):
            var contribution: JsonNode = jsrc2{key}
            assert(
              contribution.kind == JObject,
              &"Object and non object value for key {key} in config sources",
            )
            resultObject.mergeIn(contribution)
        return resultObject
      # if value is terminal (!=JObject), return it
      return jsrc{key}

  # key not present in any source
  let sources: string = dualMGetConfigInstance().sources().join("\n\t")
  raise ConfigError.newException(&"Key '{key}' not found in sources;\n\t{sources}")

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
  except ConfigError:
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
  when not defined(js):
    result &= &"Context Directory: {getContextDir()}\n"
  result &=
    showRegistrations() & "\n" & showComittedRegistrations() &
    $getConfigLazy(update = true)

proc getConfigHash*(): string =
  ## Get a hash of the current config state. Guaranteed to change of order or content changes
  result = getConfigLazy(update = true).hash().intToStr()

## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
##
## Load configuration from cue file(s) and environment variables.
##
## Environment variables are lifted from the runtime os environment with case 
## insensitive prefix NIM_, the case sensitive json path split on _. Environment variables
## are merged into the configuraton with highest precedence. Values are
## formatted per `parse`_
##
## Configuration loaded from working directory, binary directory, or compile
## time the project directory. Precedence: working > binary > compile time
##
## Single getConfig[T](key: varargs[string]) is exposed
##
## Compilation for the javascript backend is supported, but only compile time configuration

import std/[json, staticos, paths, tables, strformat, macros, strutils, sequtils]
import std/[envvars]
import jsonextra
when not defined(js):
  import std/[os, osproc] # these wont compile with js backend which has no fs access
else:
  import jsffi
  proc isNode(): bool {.emit: """
    typeof process !== 'undefined' &&
    process.versions != null &&
    process.versions.node != null;
    """.}
  proc isBrowser(): bool = not isNode()

# Cue installed
const NO_CUE*: bool = gorgeEx("command -v cue")[1] != 0

proc `/`(a: Path, b: string): Path =
  result = a
  result.add(b.Path)

# precedence high to low: RUN, BIN, PRJ
const PRJDIR = Path(getProjectPath()) # project root directory
const PRJCFG = PRJDIR / "config.cue" # compile

when nimvm: discard
else: # Runtime config
  when not defined(js): # js backend has no filesystem access
    let RUNDIR = paths.getCurrentDir() # directory from which the user has run the bin
    let BINDIR: Path = Path(getAppDir()) # path to binary file being executed
    let RUNCFG = RUNDIR / "config.cue" # runtime
    let BINCFG = BINDIR / "config.cue" # runtime
  let CFGS = [BINCFG, RUNCFG] # precedence increases  left to right

template loadConfigLogic(executor: proc(s: string): (string, int)): string =
  ## Report failure to load config file, evaluate to contents of file as string, empty if failure and print warning
  # let msg = &"Loading config from {cfg}"
  #
  # when nimvm: echo msg
  # else: info msg
  #
  var (output, code) = executor(cfg) # result is a json string
  if code != 0:
    raise newException(
      IOError,
      "Failed to load config file {cfg}, cue export exited with code " & $code,
    )
  output
  
# Override config when runtime cfg file exists
func cueExportCmd(path: string): string =
  &"cue export {path}"
  
proc fileToJsonStatic(path: string): (string,int) =
  ## Load cue file contents at compile time, fallback to json file of same name
  ## if cue not found.
  var output:string
  if NO_CUE or not staticFileExists path:
    let jpath = $Path(path).changeFileExt(".json")
    if staticFileExists jpath: (staticRead jpath, 0)
    else: ("", 1)
  else:
    gorgeEx(cueExportCmd path)

proc loadConfigStatic(
    cfgs: openArray[string or Path]
): seq[(string, string)] {.compileTime.} =
  ## Load configuration files (cfgs) at compile time to compileTimeConfig const
  ## return: [...(name, json)]
  #echo "Loading compiletime configurations ", cfgs
  for cfg in cfgs:
    if not staticFileExists $cfg:
      raise newException(
        IOError,
        &"Compile time config file {cfg} not found",
      )
    result.add (cfg, loadConfigLogic(fileToJsonStatic))
  return result

type Config = object # path: (json string, json node)
  configurations: OrderedTable[string, (string, JsonNode)] =
    initOrderedTable[string, (string, JsonNode)]()
proc `$`*(x:Config): string =
  var tmp: seq[string]= @[]
  for k,v in x.configurations.pairs:
    tmp.add(k)
    tmp.add(v[1].pretty(2))
  return tmp.join("\n")

iterator pairs(x:Config,reverse=false): (string,(string,JsonNode)) =
  ## iterate most to least recent insertion
  var keys = x.configurations.keys.toSeq()
  for ix in 1..keys.len:
    if reverse: yield (keys[^ix],x.configurations[keys[^ix]])
    else: yield (keys[ix-1],x.configurations[keys[ix-1]])

# This must be const to persist compiletime values to the binary (or script for js)
#                          name,   json string
const compileTimeConfig: seq[(string, string)] = 
  if fileExists($PRJCFG): # allow no compile time config
    loadConfigStatic([$PRJCFG])
  else:
    #echo "No compile time configuration"
    @[]
  
proc initConfig(): Config =
  ## Intialize configuration with compile time configs, runtime configs added later, order matters for precedence
  for (name, json) in compileTimeConfig:
    # suffix prevents collision with runtime loaded configs of same name
    result.configurations[name&"_compiled"] = (json, parseJson json)

# this will not be available at runtime, due to the pragma
var ctConfig {.compileTime.}: Config = initConfig() # compile time singleton
var config: Config = initConfig() # global static singleton
proc add(c: var Config = config, name: string, json: string): void =
  c.configurations[name] = (json, parseJson json)
  
proc add(c: var Config = config, name: string, source: string, json:JsonNode): void =
  ## For env vars
  c.configurations[name] = (source, json)

template cfg(): Config =
  when nimvm: ctConfig else: config
    
proc loadEnvVars(): void =
  ## Load environment variables into config
  ## Key and value case conserved
  var
    rawEnv: seq[string]
    json: JsonNode = newJObject()
    cfgtable = cfg().configurations
  for k,v in envPairs():
    let kLow = k.toLowerAscii
    if kLow.startsWith("nim_"):
      rawEnv.add(k & "=" & v)
      let path = k[4..^1].split('_')
      var parent = json
      for part in path[0..^2]:
        if not parent.contains(part):
          parent[part]=newJObject()
        parent = parent[part]
      parent[path[^1]]=v.parse()
  # Merge into config with highest precedence
  # last env var has highest precedence
  config.add("env",rawEnv.join("\n"), json)
  #echo config
    
proc fileToJson(path: string): (string,int) =
  ## Load cue file contents at runtime, fallback to json file of same name
  if NO_CUE or not fileExists(path):
    let jpath = $Path(path).changeFileExt(".json")
    if fileExists jpath: (readFile jpath, 0)
    else: ("", 1)
  else:
    execCmdEx(cueExportCmd $path)
    
proc loadConfig(cfgs: openArray[string], reload=false): void {.inline.} =
  ## Load (runtime) configuration files and env to Config singleton
  ## Note the order of cfgs is important for precedence, last has highest
  ## 
  ## NodeJs and c execution environments only support runtime config
  when defined(js):
    if not isNode():
      raise newException(AccessViolationDefect, "No runtime config available in browser")
  let foundCfgs = cfgs.filterIt(fileExists($it) or fileExists($it.changeFileExt(".json")))
  var msg =  if reload: "Reloading " else: "Loading "
  msg = msg & "runtime configurations: "
  #echo msg, foundCfgs 
  for cfg in foundCfgs:
    var jsonstring = loadConfigLogic(fileToJson)
    if jsonstring != "":
      config.add(cfg, jsonstring)
      
  # Load env vars, available in c, and nodejs but not browser js
  let useEnv: bool = block:
    when defined(js): isNode()
    else: true
        
  if useEnv: loadEnvVars() # after config files, for precedence
    
proc loadConfig(cfgs: openArray[Path], reload=false): void {.inline.} =
  loadConfig(cfgs.mapIt($it))

proc getConfigNodeImpl(key: openarray[string]): JsonNode {.raises: [ValueError].} =
  for mname, (jstr, jnode) in config.pairs(true): # `pairs(Config)`_
    if jnode.contains(key): # differentiates jsnode{key}=null vs no key
      return jnode{key}
  raise newException(ValueError, &"Key '{key}' not found in configuration")

proc getConfigNode*(key: string): JsonNode {.inline,raises: [ValueError].} =
  ## Return config value for dot notation key
  return getConfigNodeImpl(key.split('.'))

proc getConfigNode*(key: openarray[string]|varargs[string]): JsonNode {.inline.} = return getConfigNodeImpl(key)

# proc getConfig*( # type as second arg avoid overload ambiguity with getConfig
#     key: string|openarray[string], T: typedesc
# ): T {.inline,raises: [ValueError, KeyError].} =
#   ## Get config value with typecast
#   getConfig(key).to(T)

proc getConfig*(): OrderedTable[string, (string, JsonNode)] =
  ## Get config map
  cfg().configurations

proc getConfig*[T](key: string|openArray[string]): T {.inline.} =
  return getConfigNode(key).to(T)
  
proc getConfig*[T](key: varargs[string]): T {.inline.} =
  return getConfigNode(key).to(T)

proc showConfig*():string = $config

# For c backend. Nimvm does not support these as getCurrentDir and getAppDir are not available at compile time
when not defined(js):
  # Inital runtime config loading
  loadConfig(CFGS)

proc reload*(): void = # Not supported in js+browser
  ## Reload runtime configuration files
  config = initConfig() # reset to compile time config
  loadConfig(CFGS, true)

   
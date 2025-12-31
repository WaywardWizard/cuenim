## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
## Test data `tests/config.cue`_
import std/[unittest, json, paths, files, strutils, envVars,dirs,osproc]

import ../src/cueconfig

# Test for cue binary done by src/config.nim
const binCfg = Path("tests/bin/config.cue") # see --outdir flag in nimble file
const pwdCfg = Path("config.cue")
const binCfgBk = binCfg.changeFileExt("cue.bak")
const pwdCfgBk = pwdCfg.changeFileExt("cue.bak")

proc injectEnv(env: string) =
  for line in env.splitLines():
    let parts = line.split('=')
    if parts.len == 2:
      putEnv(parts[0].strip, parts[1])

suite "Read configuration":
  # Compiled in config as per `tests/config.cue`_
  setup:
    let binCfgCue =
      """
    bin: {
      nested: {
        flag: false
      }
      string: "Runtime Config"
      number: 100
      fnumber: 6.28
    }
    common: x: 1
    common: y: 1
    common: z: 1
    """
    let pwdCfgCue =
      """
    pwd: {
      nested: {
        flag: true
      }
      string: "Overwritten Runtime Config"
      number: 200
      fnumber: 9.42
    }
    common: y: 2
    common: z: 2
    """
    # Note case sensitivity of env vars
    let env =
      """
    nim_env_test=testing123
    Nim_common_z=3
    NIM_COMMON_Z=100
    """
    if fileExists(binCfg): moveFile(binCfg, binCfgBk)
    if fileExists(pwdCfg): moveFile(pwdCfg, binCfgBk)
    writeFile($binCfg, binCfgCue)
    writeFile($pwdCfg, pwdCfgCue)
    injectEnv(env)
    reload()
    #echo showConfig()
    
  teardown:
    removeFile(binCfg)
    removeFile(pwdCfg)
    if fileExists(binCfgBk): moveFile(binCfgBk, binCfg)
    if fileExists(pwdCfgBk): moveFile(pwdCfgBk, pwdCfg)

  # setup overwrote `tests/config.cue`_, expect to see original content in the
  # config as it is loaded to the binary at compile time `compileTimeConfig`_
  test "Read compiled configuration":
    check getConfig[string]("app.string") == "foo"
    check getConfig[int]("app.number") == 42
    check getConfig[float]("app.fnumber") == 3.14

    check getConfig[bool]("app.nested.flag") == true
    check getConfig[bool](["app", "nested", "flag"])
    check getConfig[bool](@["app", "nested", "flag"])

    check getConfig[float]("app.n0") == -2.23
    check getConfig[int]("app.n1") == 4200
    check getConfig[float]("app.n2") == 2.32423e7
    check getConfig[float]("app.n3") == 2.32423e-7
    check getConfig[float]("app.n4") == -2.32423e-7
    check getConfig[float]("app.n5") == 2.32423e7
    check getConfig[float]("app.n6") == 2.32423e-7
    check getConfig[float]("app.n7") == -0.3242e33
    check getConfig[float]("app.n8") == 0.23
    check getConfig[float]("app.n9") == -0.23

    check getConfigNode("app.nested").kind == JObject

  test "Read binary folder configuration":
    check getConfigNode("bin").kind == JObject
    
  test "Read pwd configuration":
    check getConfigNode("pwd").kind == JObject
    
  test "Read env configuration":
    check getConfigNode("env").kind == JObject

  test "Precedence":
    check getConfig[int]("common.w") == 0 # from compile time
    check getConfig[int]("common.x") == 1 # from bindir
    check getConfig[int]("common.y") == 2 # from pwd
    check getConfig[int]("common.z") == 3 # from env
  
suite "JSON Fallback":
  setup:
    const binCue = """
    fallback: {
      fnumber: 6.28
      string: "Runtime Config"
    }
    """
    const cfgJson = binCfg.changeFileExt("json")
    
    if fileExists(binCfg): moveFile(binCfg, binCfgBk)
      
    var (json,mexit) = execCmdEx("echo '$#' | cue export -" % [binCue])
    if mexit != 0: raise newException(IOError, "Could not run cue\n" & json)
    writeFile($cfgJson, json)
    reload()
    
  teardown:
    removeFile(cfgJson)
    if fileExists(binCfgBk): moveFile(binCfgBk, binCfg)
      
  test "Load cue file fallback to json":
    check getConfig[float]("fallback.fnumber") == 6.28
    check getConfig[string]("fallback.string") == "Runtime Config"
    
suite "Env parsing":
  setup:
    const env = """
    nim_env_sTr=stringValue
    nim_env_inT=12345
    nim_env_fLoat=3.14159
    nim_env_array0=[one,two,three]
    nim_env_array1=[1,2,3]
    nim_env_array2=[1.1,1]
    nim_env_array3=[1,1.1]
    """
    injectEnv(env)
    reload()
  test "Case sensitivity":
    check getConfig[string]("env.sTr") == "stringValue"
    check getConfig[int]("env.inT") == 12345
    expect ValueError: discard getConfig[string]("env.str")
  test "Arrays":
    check getConfig[seq[string]]("env.array0") == @["one","two","three"]
    check getConfig[seq[int]]("env.array1") == @[1,2,3]
    check getConfig[seq[float]]("env.array2") == @[1.1,1.0]
    # This will fail as mixed types not supported in nim, the JsonNode does tho
    # check getConfig[seq[int]]("env.array3") == @[1,1]
    
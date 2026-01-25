## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
## Test data `tests/config.cue`_
import std/[unittest, json, paths, strutils, envVars, macros]
when not defined(js):
  import std/[files, osproc, dirs, os, times]

import cueconfig/[config, util]

# when nimvm:
#   from system/nimscript import cd
abortOnError = true

const ENV =
  """
nim_env_test=testing123
Nim_common_z=3
NIM_COMMON_Z=100
OBJ_COMMON_Z=100
NIM_common_w=0
NIm_COMMON_Z=110
"""

const ppath = getProjectPath().Path

# NodeJS (compile with -d:nodejs) or C backend
proc injectEnv(env: string) =
  for line in env.splitLines():
    let parts = line.split('=')
    if parts.len == 2:
      putEnv(parts[0].strip, parts[1])

var GPATH: string
proc wipePath() =
  # Clear PATH to prevent finding cue binaries
  if len(GPATH) == 0:
    GPATH = getEnv("PATH")
  putEnv("PATH", "")

proc restorePath() =
  putEnv("PATH", GPATH)

when defined(js):
  const BROWSER = isBrowser()
  const NODE = isNode()
else:
  const BROWSER = false
  const NODE = false

when (NODE or defined(c)):
  suite "Env registrations":
    setup:
      injectEnv(ENV)
      registerEnvPrefix("NIM_", caseInsensitive = false)
    teardown:
      clearConfigAndRegistrations()
    test "Case sensitive prefix":
      check getConfig[int]("COMMON.Z") == 100
      check getConfig[int]("common.w") == 0
    test "Case insensitive prefix":
      registerEnvPrefix("NiM_", caseInsensitive = true)
      check getConfig[int]("common.z") == 3
      check getConfig[string]("env.test") == "testing123"
    test "JSON key sensitivity":
      expect(ValueError):
        discard getConfig[int]("cOMMON.Z")
    test "Precedence (later registrations precedent)":
      registerEnvPrefix("NiM_", caseInsensitive = true)
      check getConfig[int]("COMMON.Z") == 110
      registerEnvPrefix("OBJ_")
      check getConfig[int]("COMMON.Z") == 100

when (not defined(js)):
  suite "File registrations":
    setup:
      clearConfigAndRegistrations()
      setCurrentDir(ppath / "assets")
    suite "Relative paths":
      test "Relative fskPath":
        registerConfigFileSelector("fallback.json")
        check getConfig[string]("fileExtUsed") == "json"
        var c1, c2: int
        c1 = checksumConfig()
        registerConfigFileSelector("subdir.json") # no subdir.json in assets
        check c1 == checksumConfig() # no change as no subdir.json exists

        setCurrentDir(ppath / "assets/subdir")
        # we signal the contextdir changed
        reload()
        # now the context dir contains subdir.json but not fallback.json
        check getConfig[string]("subdirjson") == "here"
        expect(Exception):
          check getConfig[string]("fileExtUsed") == "json"

      test "Relative fskPeg":
        # going to recurse and find, anchored at assetss
        registerConfigFileSelector(("", r"subdir\.json$"))
        check getConfig[string]("subdirjson") == "here"
        setCurrentDir(ppath / "../src")
        reload()
        expect( # reload now will not find anything
          ValueError
        ):
          check getConfig[string]("subdirjson") == "here"

    suite "Interpolation":
      test "fskPath {getContextDir()}":
        setCurrentDir(ppath / "assets/subdir")
        registerConfigFileSelector("{getContextDir()}/subdir.json")
        check getConfig[string]("subdirjson") == "here"

        setCurrentDir(ppath / "assets")
        reload()
        expect(ValueError):
          # now the interpolated path won't be correck
          check getConfig[string]("subdirjson") == "here"

      test "fskPath {ENV}":
        putEnv("STUB", "subdir")
        setCurrentDir(ppath / "assets/subdir")
        registerConfigFileSelector("{STUB}.json")
        check getConfig[string]("subdirjson") == "here"

      test "fskPeg {getContextDir()}":
        setCurrentDir(ppath / "assets/subdir")
        registerConfigFileSelector(("{getContextDir()}", r"subdir.json$"))
        check getConfig[string]("subdirjson") == "here"

        setCurrentDir(ppath / "assets")
        reload() # still okay as the patern will recurse
        check getConfig[string]("subdirjson") == "here"

        setCurrentDir(ppath / "../src")
        reload()
        expect(ValueError):
          # now the interpolated path won't be correct
          check getConfig[string]("subdirjson") == "here"

      test "fskPeg {ENV}":
        putEnv("S1", "assets")
        putEnv("S2", "subdir")
        setCurrentDir(ppath)
        reload()
        # relative if it is not absolute
        registerConfigFileSelector(("{S1}/{S2}", r"subdir.json$"))
        check getConfig[string]("subdirjson") == "here"

        putEnv("S1", "../src")
        check getConfig[string]("subdirjson") == "here" # havent reloaded yet
        reload() # now the config will have new env
        expect(ValueError):
          # now the interpolated path won't be correct
          check getConfig[string]("subdirjson") == "here"

  suite "Fallback and precedence":
    setup:
      clearConfigAndRegistrations()
      setCurrentDir(ppath)
    test "Path no fallback":
      setCurrentDir(ppath)
      registerConfigFileSelector("assets/fallback.cue", false)
      check getConfig[string]("fileExtUsed") == "cue"
    test "Cue precedent":
      registerConfigFileSelector("assets/fallback.cue", false)
      registerConfigFileSelector("assets/fallback.json")
      check getConfig[string]("fileExtUsed") == "cue"
    test "Path with fallback":
      wipePath() # make cue binary unavailable forcing fallback
      registerConfigFileSelector("assets/fallback.cue", true)
      check getConfig[string]("fileExtUsed") == "json"
      restorePath()
    test "PEG no fallback":
      registerConfigFileSelector(ppath, r"assets\/fall\w+\.cue$", false)
      wipePath()
      expect(Exception):
        check getConfig[string]("fileExtUsed") == "json"

    test "PEG with fallback":
      registerConfigFileSelector(
        ppath, r"assets\/fall\w+\.cue$", useJsonFallback = true
      )
      wipePath()
      check getConfig[string]("fileExtUsed") == "json"
    test "PEG, match recurse to subpaths":
      restorePath()
      registerConfigFileSelector(ppath, r"regexmatch\.cue$", useJsonFallback = false)
      check getConfig[string]("regexmatch.onlyroot") == "here"
      check getConfig[string]("regexmatch.onlysubdir") == "here"
    test "Clear config":
      registerConfigFileSelector(ppath, r"regexmatch\.cue$", useJsonFallback = false)
      check getConfig[string]("regexmatch.common") == "subdir"
      clearConfigAndRegistrations()
      expect(ValueError):
        discard getConfig[string]("regexmatch.common")
    test "Subdir precedent":
      registerConfigFileSelector(ppath, r"regexmatch\.cue$", useJsonFallback = false)
      check getConfig[string]("regexmatch.common") == "subdir"
      clearConfigAndRegistrations()
    test "Subdir precedent order independant":
      # order independence
      setCurrentDir(ppath)
      registerConfigFileSelector(
        ["assets/regexmatch.cue", "assets/subdir/regexmatch.cue"]
      )
      check getConfig[string]("regexmatch.common") == "subdir"
      clearConfigAndRegistrations()
      registerConfigFileSelector(
        ["assets/subdir/regexmatch.cue", "assets/regexmatch.cue"]
      )
      check getConfig[string]("regexmatch.common") == "subdir"
    template setupTimePrecedentFiles(t1, t2: Time) =
      writeFile("assets/subdir/mtime1.cue", "mtime:value: \"mtime1\"")
      setLastModificationTime("assets/subdir/mtime1.cue", t1)
      writeFile("assets/subdir/mtime2.cue", "mtime:value: \"mtime2\"")
      setLastModificationTime("assets/subdir/mtime2.cue", t2)

    test "Newest precedent":
      registerConfigFileSelector(("assets/subdir", r"mtime@(\.cue$)"))
      var tnow = getTime()
      var tolder = tnow - initDuration(seconds = 10)
      setupTimePrecedentFiles(tnow, tolder)
      check getConfig[string]("mtime.value") == "mtime1"
    test "Lexicographical precedent":
      registerConfigFileSelector(("assets/subdir", r"mtime@(\.cue$)"))
      var tnow = getTime()
      setupTimePrecedentFiles(tnow, tnow)
      check getConfig[string]("mtime.value") == "mtime1"
    test "Cue precedent over json":
      setCurrentDir(ppath / "assets")
      registerConfigFileSelector(["conflictA.cue", "conflictB.json"])
      check getConfig[string]("conflict") == "A"
    test "Shadow, not clobber":
      setCurrentDir(ppath / "assets")
      registerConfigFileSelector(["conflictB.json", "conflictA.cue"])
      check getConfig[string]("onlyInA") == "A"
      check getConfig[string]("other") == "here"
  suite "SOPS":
    setup:
      putEnv("SOPS_AGE_KEY_FILE", $ppath / "age.keypair")
      var theSecret = "c4ViBOUl/JzUE97sWaFZs6pcIAEgaJ02OAWOHOxfjMM="
    teardown:
      clearConfigAndRegistrations()
    test "Read from SOPs file":
      registerConfigFileSelector(ppath / "assets/secrets.sops.yaml")
      check getConfig[string]("secret") == theSecret
    test "Env supercedes":
      registerConfigFileSelector(ppath / "assets/secrets.sops.yaml")
      putEnv("NIM_secret", "MAGIC")
      registerEnvPrefix("NIM_", true)
      check getConfig[string]("secret") == "MAGIC"

      clearConfigAndRegistrations()
      registerEnvPrefix("NIM_", true)
      registerConfigFileSelector(ppath / "assets/secrets.sops.yaml")
      check getConfig[string]("secret") == "MAGIC"

    test "Supercedes cue, json":
      clearConfigAndRegistrations()
      registerConfigFileSelector(ppath / "assets/secrets.sops.yaml")
      registerConfigFileSelector(ppath / "assets/config.cue")
      registerConfigFileSelector(ppath / "assets/fallback.json")
      check getConfig[string]("secret") == theSecret

# NODE+BROWSER+C
suite "Read static configuration (at compiletime)":
  setup:
    # This is static it probably applies over everything
    static:
      # in the js backend case, we cant change the context dir, even at compiletime
      clearConfigAndRegistrations()
      #os.setCurrentDir $ppath
      #cd($ppath)
      registerConfigFileSelector("assets/config.cue")
      putEnv("SOPS_AGE_KEY_FILE", string(ppath / "age.keypair"))
      
  test "Compiletime registrations":
    const ctregs = showRegistrations()
      # registrations at compiletime, what commit() wouldput to binary
    check ctregs.contains("assets/config.cue") # @ compiletime
    check not showRegistrations().contains("assets/config.cue") # @ runtime
  # test "Second commit":
  #   static:
  #     registerConfigFileSelector(ppath / "assets/conflictA.cue")
  test "Compiletime get":
    # will raise exception if fails
    # const evaluated at conpiletime, so we are testing compile time access
    const cfgNode = getConfig[string]("compiled.testString")
    check cfgNode == "hello world"

  test "Compiletime config not persisted without commit":
    expect(ValueError):
      # trigger an init of singleton
      check getConfig[string]("compiled.testString") == "hello world"
  test "Compiletime commit":
    # needs to come after static registrations
    commitCompiletimeConfig() # define const, send back to cueconfig module
    check getConfig[string]("compiled.testString") == "hello world"
  test "Compiler-runtime SOPs OK":
    static:
      registerConfigFileSelector(ppath / "assets/secrets.sops.yaml")
    const cts = getConfig[string]("secret") # and accessible, from sops.yaml
    check cts == "c4ViBOUl/JzUE97sWaFZs6pcIAEgaJ02OAWOHOxfjMM="
    check getConfig[string]("secret") == "not" # but not persisted (from config.cue)
  # test "Compiletime sops commit barred":
  #   # this one raises a compiletime exception, uncomment to test, maybe handle
  #   # in nimble task
  #   # OK
  #   commitCompiletimeConfig()

# NODE, BROWSER, C
suite "Read static configuration (at runtime)":
  test "Read compiled":
    check getConfigNode("compiled").kind == JObject
# NODE, BROWSER, C
suite "JSON value type conversion":
  test "Read string":
    check getConfig[string]("app.string") == "foo"
  test "Read numbers":
    check getConfig[int]("app.number") == 42
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
    check getConfig[float]("app.fnumber") == 3.14
  test "Read boolean":
    check getConfig[bool]("app.nested.flag") == true
    check getConfig[bool](["app", "nested", "flag"])
    check getConfig[bool](@["app", "nested", "flag"])
  test "Read object":
    check getConfigNode("app.nested").kind == JObject

suite "API":
  test "Dot notation key":
    check getConfig[bool]("app.nested.flag") == true
  test "Array of strings key":
    check getConfig[bool](["app", "nested", "flag"]) == true
  test "Seq key":
    check getConfig[bool](@["app", "nested", "flag"]) == true
  test "Varargs key":
    check getConfig[bool]("app", "nested", "flag") == true

when not defined(js): # filesystem access required
  suite "Read runtime configuration":
    # Compiled in config as per `tests/config.cue`_
    # Overwrite `tests/config.cue`_, the working directory `config.cue`_
    setup:
      # Note case sensitivity of env vars
      let env =
        """
      nim_env_test=testing123
      Nim_common_z=3
      NIM_COMMON_Z=100
      """
      setCurrentDir(ppath / "assets")
      registerEnvPrefix("nim_", caseInsensitive = true)
      registerConfigFileSelector("bincfg.cue")
      registerConfigFileSelector("pwdcfg.cue")
      injectEnv(env)

    test "Read binary folder configuration":
      check getConfigNode("bin").kind == JObject
    test "Read pwd configuration":
      check getConfigNode("pwd").kind == JObject
    test "Read env configuration":
      check getConfigNode("env").kind == JObject
    test "Precedence, reloading":
      check getConfig[int]("common.w") == 0 # from compile time
      check getConfig[int]("common.x") == 1 # from bindir
      check getConfig[int]("common.y") == 2 # from pwd
      check getConfig[int]("common.z") == 3 # from env

  suite "JSON Fallback for missing cue file":
    setup:
      setCurrentDir(ppath / "assets")
    test "Load cue file fallback to json":
      registerConfigFileSelector("only.json", true)
      check getConfig[string]("test") == "onlyjson"

when (not defined(js) or NODE):
  suite "Env parsing":
    setup:
      const env =
        """
      nim_env_sTr=stringValue
      nim_env_inT=12345
      nim_env_fLoat=3.14159
      nim_env_array0=[one,two,three]
      nim_env_array1=[1,2,3]
      nim_env_array2=[1.1,1]
      nim_env_array3=[1,1.1]
      nim_env_obj={"old": 1,"key1":"value1","key2":2,"key3":3.0, "key4":true, "key5":null, "key6":[1,2,3],"key7":{"subkey":"subvalue"}}
      nim_={"env": {"obj": {"old": 0}}, "topLevelKey": "topLevelValue"}
      """
      injectEnv(env)
      when defined(js):
        registerEnvPrefix("nim_", caseInsensitive = true)
      reload()
    test "Case sensitivity of json keys":
      check getConfig[string]("env.sTr") == "stringValue"
      check getConfig[int]("env.inT") == 12345
      expect ValueError:
        discard getConfig[string]("env.str")
    test "Arrays":
      check getConfig[seq[string]]("env.array0") == @["one", "two", "three"]
      check getConfig[seq[int]]("env.array1") == @[1, 2, 3]
      check getConfig[seq[float]]("env.array2") ==
        @[1.1, 1.0]
          # This will fail as mixed types not supported in nim, the JsonNode does
          # check getConfig[seq[int]]("env.array3") == @[1,1]
    test "Object":
      let objNode = getConfigNode("env.obj")
      check objNode["key1"].getStr() == "value1"
      check objNode["key2"].getInt() == 2
      check objNode["key3"].getFloat() == 3.0
      check objNode["key4"].getBool() == true
      check objNode["key5"].kind == JNull
      check objNode["key6"].kind == JArray
      check objNode["key7"].kind == JObject
      check objNode["key7"]["subkey"].getStr() == "subvalue"
    suite "Top level object env":
      test "Object collision common key clobber":
        check getConfig[int]("env.obj.old") == 0
      test "Object collision old keys retained":
        check getConfig[int]("env.obj.key2") == 2
      test "Top level key":
        check getConfig[string]("topLevelKey") == "topLevelValue"

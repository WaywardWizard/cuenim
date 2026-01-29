## Copyright (c) 2025 Ben Tomlin
## Licensed under the MIT license
## Test simple API wrapper functions
import std/[unittest, paths, envVars, macros,strutils]
when not defined(js):
  import std/[os]
import ../src/cueconfig
import cueconfig/exceptions

when not defined(js):
  const ppath = getProjectPath().Path
  const adir = $ppath & "/assets"
  const sdir = $ppath & "/../src"
  
  suite "Simple API - File registration":
    setup:
      clear()
      setCurrentDir adir
  
    test "Register and access config file":
      register("fallback.json")
      check getconfig[string]("fileExtUsed") == "json"
  
    test "Deregister config file":
      register("fallback.json")
      deregister("fallback.json")
      expect(ConfigError): # missing key
        discard getconfig[string]("fileExtUsed")
  
  suite "Simple API - Environment registration":
    setup:
      clear()
      putEnv("NIM_test", "value123")
  
    test "Register and access env prefix":
      registerEnv("NIM_", caseSensitive = true)
      check getconfig[string]("test") == "value123"
  
    test "Deregister env prefix":
      registerEnv("NIM_", caseSensitive = true)
      deregisterEnv("NIM_")
      expect(ConfigError):
        discard getconfig[string]("test")
  
  suite "Simple API - Config access":
    setup:
      clear()
      setCurrentDir adir
      register("config.cue")
  
    test "Config with dot notation":
      check getconfig[string]("app.string") == "foo"
      check getconfig[int]("app.number") == 42
  
    test "Config with varargs":
      check getconfig[string]("app", "string") == "foo"
      check getconfig[int]("app", "number") == 42
  
    test "Config with array":
      check getconfig[string](["app", "string"]) == "foo"
      check getconfig[int](["app", "number"]) == 42
  
  suite "Simple API - Inspect and reload":
    setup:
      clear()
      setCurrentDir adir
  
    test "Inspect returns registration info":
      register("fallback.json")
      let info = inspect()
      check info.len > 0
      check info.contains("fallback.json")
  
    test "Reload updates config":
      register("fallback.json")
      check getconfig[string]("fileExtUsed") == "json"
      setCurrentDir sdir
      reload()
      expect(ConfigError):
        check getconfig[string]("fileExtUsed") == "json"

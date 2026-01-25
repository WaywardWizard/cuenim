## Copyright (c) 2025 Ben Tomlin 
## Licensed under the MIT license
##  
## .. importdoc:: cueconfig/cueconfig,cueconfig/jsonextra
## 
## This api is simplified for end users and wraps an alternative API with more 
## descriptive names and convenience overloads in `cueconfig/config module`_
import std/[paths, pegs]
import cueconfig/cueconfig
export getConfig, reload

template register*(path: string, fallback: bool = true) =
  ## Register a config file at path, with JSON fallback for unavailable cue files
  registerConfigFileSelector(path, fallback)

template deregister*(path: string) =
  ## Remove a registered config file at path
  deregisterConfigFileSelector(path)

template register*(searchdir: string, peg: string, fallback: bool = true) =
  ## Register config files in searchdir matching peg, with JSON fallback for cue
  registerConfigFileSelector((searchdir, peg, fallback))

template deregister*(searchpath: string, peg: string) =
  ## Remove registered file matcher pattern
  deregisterConfigFileSelector(searchpath, peg)

template registerEnv*(prefix: string, caseSensitive: bool = false) =
  ## Register environment variable prefix to include env vars in config
  registerEnvPrefix(prefix, caseInsensitive = not caseSensitive)

template deregisterEnv*(prefix: string) =
  ## Deregister environment variable prefix
  deregisterEnvPrefix(prefix)

template clear*() =
  ## Remove all registered config from config, except for comitted config
  clearConfigAndRegistrations()

template commit*() =
  ## Commit all earlier registrations made in a static context to binary
  commitCompiletimeConfig()

template inspect*(): string =
  ## Dump config with useful diagnostic information such as ct/rt registrations
  showConfig()


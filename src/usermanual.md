Copyright (c) 2025 Ben Tomlin 
Licensed under the MIT license

.. importdoc:: cueconfig/jsonextra, cueconfig/vmutil
.. contents::
# Introduction
Load configuration from [cue](https://cuelang.org), json and [sops](https://github.com/getsops/sops) file(s) as well as environment variable(s). At compiletime or runtime. Save configuration loaded at compiletime into the binary for use at runtime.

All configuration merges to master json document. Configuration sources follow well defined precedence. Precedent sources will shadow lower precedence sources where keys overlap.

## Overall flow
1. FileSelector or EnvPrefix is registered, selecting a set of files or envs
2. The data scoped by these selectors is loaded lazily into the config singleton.
3. Config keys are accessed via the config singleton, which merges all loaded data according to well defined precedence.

# Configuration Sources
## Environment Variables
Environment variables are lifted from the runtime or compiletime os environment.
* All vars with matching user specified prefix(es) are used
* The case sensitive json path is derived from the sans prefix variable name
  split on _.
* Environment variables are merged into the configuraton with highest precedence.
* Homogeneous arrays, any JSON string, and primitive types supported.

## Configuration Files
- Cue and Json supported.
- Regex patterns to match files may be specified, or alternatively file paths
- Matched files loaded to configuration
- Missing cue files fallback to json files of same name if present
- The extension must be .cue or .json, .sops.(json|cue)

### CUE, SOPS Integration
For SOPS you need your sops access key in the SOPS_AGE_KEY_FILE environment variable and the sops binary in PATH. For cue you need the cue binary in PATH. You dont need either of these things if you dont want to use CUE or SOPS support.

### File Selection
You register string paths to files, or a search directory path and PEG pattern to match files within that directory.

These paths may be absolute or relative. Relative paths are relative to the context directory [getContextDir]. Briefly, this is the working directory at runtime, and the project directory at compiletime. Its also possible to have environment variables or the context directory interpolated into the paths.

#### PEGS
PEGs not regexes are used to match patterns. Basic regexes will work as a peg also.

#### Interpolation
Occurs at the time the config file selected is *loaded*. Loading occurs once lazily at time of access. Only after a subsequent registration or reload() will interpolation reoccur. Thus if you use interpolation and change scoped environment variables or the working directory, you must call reload() to have these changes reflected in the config.

Implemented by `interpolatedItems`_ and `interpolate`_

FileSelector.searchspace replaces any `{ENV}` or `{getContextDir()}`
FileSelector.path replaces any `{ENV}` or `{getContextDir()}`

At compiletime note, the working directory is wherever the compiler was
run from and furthermore cannot be changed with `nimscript.cd()`. This means
the working directory is uncontrollable and thus the context directory is
the project directory instead.

##### Environment
Environment variables may be used, specify as `{ENVVAR}`, and it will be
interpolated at the time of load. If the value changes at runtime
then a reload will pick up the new value and it wont be necessary
to deregister the stale and reregister the new selector as it would be if
the env variable were filled in caller side and thus fixed.

### File Types
#### Sops Files | Secrets Management
This works by loading from sops files from disk to memory, decrypting, making
the memory available to cue as a fifo file, and then cue will merge this into
its configuration.

This is disabled at compiletime as you should not compile secrets into
your binary or javascript. If it were stolen an attacker could extract them.


## Precedence
The guiding principle is to draw config closest to the source of truth and from
the most specific source. Thus environment variables have highest precedence,
then sops files, then cue files, then json files. These are the four precedence
classes. Each class can be divided into two: runtime and compiletime. 

Config access will try to find a key in the most precedent class before attempting the next. When there are multiple sources in the same precedence class that contain a key;
- Runtime is preferred over compiletime.
- When the precedence class is environment, later registraitons are preferred.
- For file classes (sops, cue, json) the deepest file in the hierarchy is used, then the latest, then the lexicographically first.

As a rule, configuration sources shadow those of lower precedence, and do not clobber them.

### Conflicts
Say a json and cue file of the same names are selected. Here the cue file will be precedent as it is the source of truth and the json file was derived from it. As an exception, in this situation, the cue file will not shadow but clobber the json.

#### Shadow vs Clobber Examples

The following examples illustrate the difference between shadowing (normal merge behavior) and clobbering (complete replacement):

**1. JSON File Content (`config.json`):**
```json
{
  "database": {
    "host": "localhost",
    "port": 5432,
    "name": "myapp_db"
  },
  "cache": {
    "enabled": true,
    "ttl": 3600
  },
  "features": {
    "analytics": false,
    "notifications": true
  }
}
```

**2. CUE File Content (`config.cue`):**
```json
{
  "database": {
    "host": "prod-db.example.com",
    "port": 5432,
    "user": "admin"
  },
  "logging": {
    "level": "debug",
    "format": "json"
  },
  "features": {
    "analytics": true
  }
}
```

**3. Shadowed Merge (Normal Behavior):**
In normal shadowing behavior, overlapping keys from the higher precedence source (CUE) take precedence, but non-overlapping keys from both sources are preserved:
```json
{
  "database": {
    "host": "prod-db.example.com",
    "port": 5432,
    "user": "admin",
    "name": "myapp_db"
  },
  "cache": {
    "enabled": true,
    "ttl": 3600
  },
  "features": {
    "analytics": true,
    "notifications": true
  },
  "logging": {
    "level": "debug",
    "format": "json"
  }
}
```

**4. Clobber Merge (Same-name CUE/JSON files):**
When CUE and JSON files have the same name, the CUE file **clobbers** the JSON file completely. The JSON file's entire content is replaced by the CUE file's content:
```json
{
  "database": {
    "host": "prod-db.example.com",
    "port": 5432,
    "user": "admin"
  },
  "logging": {
    "level": "debug",
    "format": "json"
  },
  "features": {
    "analytics": true
  }
}
```

**Key Differences:**

| Aspect | Shadowed Merge | Clobber Merge |
|--------|---------------|---------------|
| Overlapping keys | CUE values replace JSON values | CUE values replace JSON values |
| JSON-only keys | Preserved in final result | Lost |
| CUE-only keys | Added to final result | Added to final result |
| Result size | Union of both sources | Only CUE content |


## Fallback
When a cue file is registered but not found or exportable, fallback to a json file of the same name (but with `.json` extension).

# Comitting Config to Binary
Config sources registered at compiletime may have their contents comitted to the binary for runtime use.
[commit]. SOPs sources cannot be comitted to a binary for security reasons.

# API 
A simplified api of [module src/api] is provided for end users.

## Summary
| Call | CT|RT | Usage |
| ---  | --- |---  | --- |
| register | 1|1 | Select (sops, cue, json) files for use in config, or environment variable prefixes for selecting sets of environment variables to contributo to the config |
| deregister | 1|1 | Remove selected files or env prefixes |
| registerEnv | 1 |1 | Register a prefix to match env vars with |
| deregisterEnv | 1 |1 | Deregister a prefix to match env vars with |
| commit | 0|1 | Commit all current (static) registrations to binary. |
| getConfig | 1|1 | Lookup config key from loaded sources |
| reload | 1|1 | Reload config after external changes such as environment variables or working directory |
| inspect | 1|1 | Get a string representation of the config, registrations and other state |

## Calltime Context
### CT/RT
Access of config at compiletime as well as runtime is supported. Procs behave the same in both contexts. However, only the config (statically) registered before a commit() call will be persist into runtime.

### External
Env vars, the pwd() and the availibility of selected files all change the resulting config. reload() should be called if the env or pwd() changes to have the config reflect these. Otherwise, *new* registrations are included automatically on the next config access.

# JS Backend
Compilation for the javascript backend is supported. Only compiletime config can use files

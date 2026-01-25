# CueConfig
Cueconfig allows sourcing and accessing configuration at compiletime or runtime from environment variables, SOPs, CUE and JSON files. These are referred to as JsonSources. JsonSources are merged into a single configuration object, from which typed values may be retrieved. At compiletime configuration may be used, and at runtime. Js and C backends are supported with the caveat that the JS backend has no filesystem access at runtime (but we have fs access at compiletime). 

You may also compile in the configuration sourced at runtime, thus configuring your binary, and the override the compiled configurations at will later with any JsonSource.

If you are using CUE or SOPS, you need those binaries available at compiletime or runtime or both depending on when you use them.
*   [**CUE**](https://cuelang.org/docs/install/)
*   [**SOPS**](https://getsops.io)

# Quick Start
## Install
```bash
nimble install cueconfig
```
## Use
Register your configuration source(s) at compiletime (in a static context)
```nim
import cueconfig, std/envvars
var
  keypath = "/path/to/your/age/key.txt"
  sopsFilePath = "/path/to/your/encrypted/config.sops.(json|yaml)"
  cueFilePath = "/path/to/your/config.cue"
  jsonFilePath = "/path/to/your/config.json"
  cue2File = "/path/to/your/other/config.cue"
  cue3File = "/path/to/your/third/config.cue"
static:
  putEnv("SOPS_AGE_KEY_FILE",keypath) # your sops key 
  register(sopsFilePath) # your sops encrypted json file, must be a .sops.json
  register(cueFilePath)  
  register(jsonFilePath)
```
Then access your configuration at compiletime. If your requested key is not found an exception is raised. After registering a JsonSource its contents are immediately available.
```nim
static:
  let dbHost: string = getConfig[string]("backend.db.host")
  let dbPort: int = getConfig[int]("backend.db.port")  
  let routes[JsonNode] = getConfig[JsonNode]("frontend.spa.routes")
const 
  jwtRefreshPeriod = getConfig[int]("frontend.jwt.refresh.period")
  jwtAccessPeriod = getConfig[int]("frontend.jwt.access.period")
````
To configure your binary you can persist all registrations made in a static context prior to calling `commit()`. `commit()` will serialize the registered config, store it in the binary with a const, then deserialize at runtime. You must call commit in a runtime context. If you try to commit SOPS JsonSources an exception will be raised. This is intentionally disallowed as secret material should not be compiled into binaries.
```nim
static:
  register(cueFilePath)  
  register(jsonFilePath)
  commit() # store the registered config in the binary
  register(cue2FilePath) # you can still register more sources at runtime
```  
Now contents of `cueFilePath` and `jsonFilePath` are accessible with `getConfig` at runtime. You can access contents of `cue2FilePath` at compiletime, but not runtime, since it was not registered prior to commit.

Dump your configuration at runtime for debugging.
```nim
inspect()
```

To load configuration at runtime;
```nim
register(cue3File)
getConfig[int]("some.key.in.cue3file")
```
Say you want to load in a new set of files for configuration
```nim
var configs: seq[string]
clear() # remove registrations and runtime config, but not compiled in config
register(configs)
getConfig[float]("some.float.key")
```
Or maybe you want to remove a particular registration
```nim
deregister(cue3File)
```
To source config from environment varibles, you need to register a prefix of environment variable names. All environment variables matching this prefix will be matched. The json keypath will be extracted from the environment variable name by removing the prefix and replacing `_` with `.`. The value of the env var may be a json value (string, number, object, array, boolean, null) and will be parsed as such.
```nim
putEnv("NIM_some_key","-0.32e-13")
registerEnv("NIM_",caseSensitive=false) # sensitivity applies to prefix only
let someKey: float = getConfig[float]("some.key")
```
You can commit your config sourced from env vars just like with files. If you want to just input json with an env var, set its value to an object
```nim
putEnv("NIM_","{\"key1\":\"value1\",\"key2\":2}") # top level merge
putEnv("NIM_server_data","{\"key1\":\"value1\",\"key2\":2}") # nested merge
````

# Documentation
[Github Pages](https://waywardwizard.github.io/cueconfig/)

# Why
The benefits of CUE and SOPS are best heard from the horses mouth. For CUE, config can be typed and validated, it can be generated from other config, and boilerplate and repitition can be eliminated. Particularly you can change a value, and have other values change accordingly, because you can derive your configuration from principal configuration with logic.

For SOPS, secret management is simplified, and the less friction there is to securing systems the more secured they will be. You need secret management if you are handling secrets. 

Some advantages to separating config from your executable is you gain agility and can more rapidly test. You can centralize configuration and keep a single source of truth.

Another point. Configuration is just a fundamental that needs to be done well once and with enough flexibility that you dont need to spend time bending around it. Get the basics right, dont build on the sand.

# Alternatives
- Just use getEnv. For any complex configuration, youll still need to populate your env vars, and youll need to write some code to source, parse and validate them. This repo provides that code for you.
- Parse Json/Yaml/Toml/Ini with library. Then you have a JsonNode. You still need to do secrets, you lose the benefits of CUE, and you need to think about precedence and merging. You"ll reimplement this wheel.
- Neither of the above provide compiletime configuration access without further work, and they dont provide compile in configuration.

# Configuration Examples
## CUE
For a config
```cue
frontend: {
  jwt: {
    refresh: period: 36_000
    access: period: 3_600
  }
  spa: {
    routes: {
			home: "/"
			dashboard: "/dashboard"
			profile: "/profile"
		}
  }
}
backend: {
  blacklist: ["100.200.100.200","1.2.3.4"]
  blacklist: [...net.IP]
	db: {
		host: "localhost"
		port: 5432
	}
}
```
Access with
*   `getConfig[T](key: string|varargs[string]): T`: Retrieves a configuration value by key (dot notation|array/varargs of keys).

Valid key formats:
*   Dot notation: `getConfig[int]("frontend.jwt.refresh.period")`
*   Array of strings: `getConfig[int](["frontend", "jwt", "refresh", "period"])`
*   Seq of strings: `getConfig[int](@["frontend", "jwt", "refresh", "period"])`
*   Varargs strings: `getConfig[int]("frontend", "jwt", "refresh", "period")`

## Environment Variables
Environment variables can override any configuration value. The matching logic is as follows:

1.  Prefix: `NIM_` (case-insensitive or sensitive).
2.  Separator: `_` (underscore) denotes nested keys.
3.  Case Sensitivity: The JSON keys themselves are case-sensitive.

## Special Case: Top-Level JSON Object
If you use secret management, a simple way of injecting your secrets to the
config is to yield a json string containing all secrets and assign that to a
single `nim_` environment variable. This json object will be merged into the
config according to the precedence rules. Do this with a `nim_` environment
variable (note the trailing underscore) set with /usr/bin/env.

**Examples:**

*   `NIM_SERVER_PORT=9090` overrides `server.port`.
*   `Nim_database_connectionString=...` overrides `database.connectionString`.
*   `nim_app_settings_theme=dark` overrides `app.settings.theme`.
*   `nim_array=[1,2,-.3204e-13]` heterogeneous json array (cast to homogenous nim container)
*   `nim_object={"key1":"value1","key2":2}` json object 
*   `nim_={"key1":"value1","key2":2}` special case keys to top level json object 

Equivalent cue:
```cue
server: {
	port: 9090
}
database: {
	connectionString: "..."
}
app: {
	settings: {
		theme: "dark"
	}
}	
array: [1, 2, -3.204e-14]
object: {
	key1: "value1"
	key2: 2
}
```

# License
MIT

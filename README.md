# CueConfig

Cue configuration with JSON fallback for Nim projects.

## Description

`cueconfig` is a Nim library that simplifies configuration management by leveraging [CUE](https://cuelang.org/) (Configure Unify Execute). It allows you to define your configuration in CUE, providing powerful validation and schema definition capabilities. It also supports a robust fallback mechanism to JSON and overrides via environment variables.

## Features

*   **CUE Integration**: First-class support for CUE configuration files.
*   **JSON Fallback**: Automatically falls back to `.json` files if `.cue` files are missing or CUE is not installed.
*   **Hierarchical Configuration**: Merges configuration from multiple sources with a defined precedence order. ENV > Working Dir > Binary Dir > Compile-time.
*   **Compile in config + Runtime overrides**: Loads configuration from the project root at compile time and allows overrides from the environment, working directory or binary directory at runtime.
*   **Environment Variables**: Seamlessly overrides configuration values using environment variables with the `NIM_` prefix.
*   **Type Safety**: Provides a generic `getConfig[T]` procedure to retrieve typed configuration values.
*   **Cross-Platform**: Works on all platforms supported by Nim.
*   **JS Backend Support**: Some compatibility with Nim's JavaScript backend (Node.js and Browser). For browser usage there is no runtime config as JS does not have file system access. Compile time config is embedded as normal.

## Installation
Then, install the `cueconfig` package using Nimble:
```bash
nimble install cueconfig
```

## Prerequisites

*   **CUE**: To use CUE files, you need to have `cue` installed and available in your system's PATH.
    *   [Install CUE](https://cuelang.org/docs/install/)

## Usage

### Basic Usage

1.  **Create a configuration file** (e.g., `config.cue` in your project root):
    This cue will be generated into JSON at compile time and embedded into the binary. Your config file(s) must be named `config.cue` or `config.json`.
    ```cue
    server: {
        host: "localhost"
        port: 8080
        debug: true
    }
    ```

2.  **Access configuration in Nim**:

    ```nim
    import cueconfig

    let host = getConfig[string]("server.host")
    let port = getConfig[int]("server.port")
    
    if getConfig[bool]("server.debug"):
        echo "Debug mode is on"
    ```

3. **Override **:
    You can override configuration values using environment variables. For example, to change the server port, set the following environment variable before running your application:k
    ```bash
    export NIM_SERVER_PORT=9090
    ```
    Otherwise, additional config or override config in a `config.cue` or `config.json` file can be placed in the working directory or binary directory.

### Configuration Precedence

`cueconfig` loads configuration from the following sources, in order of precedence (highest to lowest):

1.  **Environment Variables**: Variables starting with `NIM_`.
2.  **Runtime (Working Directory)**: `config.cue` (or `config.json`) in the current working directory. Useful if you want to test your binary with various configs.
3.  **Runtime (Binary Directory)**: `config.cue` (or `config.json`) in the directory where the executable is located.
4.  **Compile-time**: `config.cue` (or `config.json`) in the project root directory at compile time.

### Environment Variables

Environment variables can override any configuration value. The matching logic is as follows:

1.  Prefix: `NIM_` (case-insensitive).
2.  Separator: `_` (underscore) denotes nested keys.
3.  Case Sensitivity: The keys themselves are case-sensitive.

**Examples:**

*   `NIM_SERVER_PORT=9090` overrides `server.port`.
*   `Nim_database_connectionString=...` overrides `database.connectionString`.
*   `nim_app_settings_theme=dark` overrides `app.settings.theme`.

### JSON Fallback

If `config.cue` is not found, `cueconfig` will look for `config.json`. This is useful for deployments where installing the CUE binary might not be desirable or possible.

### API Reference

*   `getConfig[T](key: string): T`: Retrieves a configuration value by key (dot notation) and converts it to the specified type `T`.
*   `getConfigNode(key: string): JsonNode`: Retrieves the raw `JsonNode` for a given key.
*   `reload()`: Reloads the runtime configuration and environment variables. Useful for long-running applications or testing.
*   `showConfig()`: Returns a string representation of the currently loaded configuration.

## License

MIT

## Tests
`nimble test`

## Development AI Usage
AI has been used for dumb code completion, debugging and some documentation. The
logic and architecture is handwritten.

## Collaboration
Pull requests are welcome. Please include tests if relevant,
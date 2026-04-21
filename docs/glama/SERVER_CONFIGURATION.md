# BoJ Server Configuration

## Environment Variables

### Core Configuration

| Name | Required | Description | Default |
|------|----------|-------------|---------|
| `BOJ_BASE_URL` | No | Base URL for the BoJ REST API | `http://localhost:7700` |
| `BOJ_FEDERATION_PORT` | No | UDP port for Umoja federation | `9999` |
| `BOJ_QUIC` | No | Enable QUIC transport (1 = yes, 0 = UDP only) | `1` |
| `BOJ_REST_PORT` | No | TCP port for REST API | `7700` |
| `BOJ_MCP_BRIDGE` | No | Path to MCP bridge executable | `mcp-bridge/main.js` |

### Authentication

| Name | Required | Description | Default |
|------|----------|-------------|---------|
| `GITHUB_TOKEN` | No | GitHub API token for Git operations | - |
| `ORIGENE_API_KEY` | No | API key for OrigeneMCP | - |
| `NOTIFYHUB_API_KEY` | No | API key for NotifyHub | - |

### Database

| Name | Required | Description | Default |
|------|----------|-------------|---------|
| `BOJ_DB_PATH` | No | Path to SQLite database | `~/.boj/boj.db` |
| `BOJ_DB_MAX_CONNECTIONS` | No | Maximum database connections | `16` |

### Logging

| Name | Required | Description | Default |
|------|----------|-------------|---------|
| `BOJ_LOG_LEVEL` | No | Log level (debug, info, warn, error) | `info` |
| `BOJ_LOG_FORMAT` | No | Log format (json, text) | `json` |

### Federation

| Name | Required | Description | Default |
|------|----------|-------------|---------|
| `BOJ_FEDERATION_SEEDS` | No | Comma-separated list of seed nodes | - |
| `BOJ_FEDERATION_TIMEOUT` | No | Federation timeout in milliseconds | `5000` |

## Configuration File

The BoJ server can also be configured via a `boj.config.json` file:

```json
{
  "rest": {
    "port": 7700,
    "host": "0.0.0.0"
  },
  "federation": {
    "port": 9999,
    "quic": true,
    "seeds": ["seed1.example.com:9999", "seed2.example.com:9999"]
  },
  "database": {
    "path": "~/.boj/boj.db",
    "max_connections": 16
  },
  "logging": {
    "level": "info",
    "format": "json"
  },
  "cartridges": {
    "auto_load": true,
    "paths": ["cartridges/"]
  }
}
```

## Command-Line Arguments

The BoJ server accepts the following command-line arguments:

```bash
# Start the server
boj-server --config boj.config.json

# Start with specific cartridges
boj-server --cartridges database-mcp,git-mcp

# Start in development mode
boj-server --dev

# Start with verbose logging
boj-server --log-level debug
```

## Docker Configuration

When running in Docker, use environment variables:

```bash
docker run -e BOJ_REST_PORT=8080 -e BOJ_LOG_LEVEL=debug boj-server
```

## Configuration Examples

### Production Configuration

```json
{
  "rest": {
    "port": 8080,
    "host": "0.0.0.0"
  },
  "federation": {
    "port": 9999,
    "quic": true
  },
  "logging": {
    "level": "info",
    "format": "json"
  }
}
```

### Development Configuration

```json
{
  "rest": {
    "port": 7700,
    "host": "localhost"
  },
  "federation": {
    "port": 9999,
    "quic": false
  },
  "logging": {
    "level": "debug",
    "format": "text"
  }
}
```

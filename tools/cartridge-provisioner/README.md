# Cartridge Provisioner

The Cartridge Provisioner is a tool for deploying cartridges to BoJ Server, BoJ Server + Elixir Multiplier, or panll.

## Features

- Deploy cartridges to BoJ Server, BoJ Server + Elixir Multiplier, or panll
- Scale cartridges based on load
- Apply runtime configuration to cartridges
- Support health checks and rollback

## Installation

```bash
cd tools/cartridge-provisioner
npm install
```

## Usage

### Command Line

```bash
node provisioner.js <cartridge-dir> <target> [--scale <scale>] [--config <config-file>]
```

### Options

- `<cartridge-dir>`: Path to the cartridge directory containing `cartridge.json`
- `<target>`: Target deployment environment (`boj-server`, `boj-server-elixir`, or `panll`)
- `--scale <scale>`: Number of instances to scale the cartridge to (default: `1`)
- `--config <config-file>`: Path to the configuration file for the cartridge

### Example

```bash
node provisioner.js ../../cartridges/my-cartridge boj-server --scale 3 --config config.json
```

### Programmatic Usage

```javascript
import { deployCartridge } from './provisioner.js';

const result = await deployCartridge('path/to/cartridge', 'boj-server', {
  scale: 3,
  config: {
    api_key: 'your-api-key',
    rate_limit: 1000,
  },
});

console.log('Cartridge deployed:', result);
```

## Output

The Cartridge Provisioner deploys the cartridge to the specified target and applies the configuration. The cartridge files are copied to the target directory, and the configuration is applied.

## License

This tool is licensed under the PMPL-1.0-or-later license. See the LICENSE file for more information.

<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Cartridge Configurator

The Cartridge Configurator is a tool for applying runtime configuration to cartridges dynamically.

## Features

- Apply runtime configuration to cartridges
- Validate configuration against a schema
- Support multi-environment configurations
- Trigger hot-reload if supported

## Installation

```bash
cd tools/cartridge-configurator
npm install
```

## Usage

### Command Line

```bash
node configurator.js <cartridge-dir> <config-file> [--no-validate]
```

### Options

- `<cartridge-dir>`: Path to the cartridge directory containing `cartridge.json`
- `<config-file>`: Path to the configuration file for the cartridge
- `--no-validate`: Skip configuration validation

### Example

```bash
node configurator.js ../../cartridges/my-cartridge config.json
```

### Programmatic Usage

```javascript
import { applyConfig } from './configurator.js';

const result = await applyConfig('path/to/cartridge', {
  api_endpoint: 'https://api.example.com',
  rate_limit: 1000,
}, { validate: true });

console.log('Configuration applied:', result);
```

## Output

The Cartridge Configurator applies the configuration to the cartridge and writes it to a `config.json` file in the cartridge directory. If hot-reload is supported, it triggers a hot-reload of the cartridge.

## License

This tool is licensed under the MPL-2.0 license. See the LICENSE file for more information.

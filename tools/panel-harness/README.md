<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Panel Harness

The Panel Harness is a tool for bridging cartridges to BoJ Server and panll.

## Features

- Register cartridges with BoJ Server or panll
- Support protocol translation (REST ↔ gRPC ↔ GraphQL)
- Route events between cartridges and BoJ Server/panll
- Expose cartridges as A2ML-compliant services or panll modules

## Installation

```bash
cd tools/panel-harness
npm install
```

## Usage

### Command Line

```bash
node harness.js <cartridge-dir> <target> [--routes <routes-file>]
```

### Options

- `<cartridge-dir>`: Path to the cartridge directory containing `cartridge.json`
- `<target>`: Target environment (`boj-server` or `panll`)
- `--routes <routes-file>`: Path to the routes configuration file for the cartridge

### Example

```bash
node harness.js ../../cartridges/my-cartridge boj-server --routes routes.json
```

### Programmatic Usage

```javascript
import { registerCartridge } from './harness.js';

const result = await registerCartridge('path/to/cartridge', 'boj-server', {
  routes: [
    { protocol: 'REST', port: 4000 },
    { protocol: 'gRPC', port: 50051 },
  ],
});

console.log('Cartridge registered:', result);
```

## Output

The Panel Harness registers the cartridge with the specified target and writes the registration to a `registration.json` file in the harness directory.

## License

This tool is licensed under the MPL-2.0 license. See the LICENSE file for more information.

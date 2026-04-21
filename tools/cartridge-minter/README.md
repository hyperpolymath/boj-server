# Cartridge Minter

The Cartridge Minter is a tool for packaging, signing, and versioning cartridges for the BoJ server.

## Features

- Package cartridges into distributable artifacts
- Generate A2ML manifests and panll descriptors
- Sign cartridges for security and authenticity
- Version cartridges using semantic versioning

## Installation

```bash
cd tools/cartridge-minter
npm install
```

## Usage

### Command Line

```bash
node minter.js <cartridge-dir> <output-dir> [--sign] [--version <version>]
```

### Options

- `<cartridge-dir>`: Path to the cartridge directory containing `cartridge.json`
- `<output-dir>`: Path to the output directory for the minted cartridge
- `--sign`: Sign the cartridge (placeholder for actual signing logic)
- `--version <version>`: Specify the version of the cartridge (default: `0.1.0`)

### Example

```bash
node minter.js ../../cartridges/my-cartridge output --sign --version 1.0.0
```

### Programmatic Usage

```javascript
import { mintCartridge } from './minter.js';

const result = await mintCartridge('path/to/cartridge', 'path/to/output', {
  sign: true,
  version: '1.0.0',
});

console.log('Cartridge minted:', result);
```

## Output

The Cartridge Minter generates the following files:

- `<cartridge-name>.a2ml.json`: A2ML manifest for the cartridge
- `<cartridge-name>.panll.json`: panll descriptor for the cartridge

## License

This tool is licensed under the PMPL-1.0-or-later license. See the LICENSE file for more information.

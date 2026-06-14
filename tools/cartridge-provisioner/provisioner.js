#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

// Cartridge Provisioner — Deploy cartridges to BoJ Server, BoJ Server + Elixir Multiplier, or panll

import { readFile, writeFile, mkdir, readdir, copyFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';

async function readJsonFile(filePath) {
  const content = await readFile(filePath, 'utf8');
  return JSON.parse(content);
}

async function writeJsonFile(filePath, data) {
  await writeFile(filePath, JSON.stringify(data, null, 2), 'utf8');
}

async function ensureDirectoryExists(directory) {
  await mkdir(directory, { recursive: true });
}

async function deployCartridge(cartridgeDir, target, options = {}) {
  const { scale = 1, config = {} } = options;
  
  // Read cartridge.json
  const cartridgeJsonPath = join(cartridgeDir, 'cartridge.json');
  const cartridge = await readJsonFile(cartridgeJsonPath);
  
  // Ensure the target directory exists
  const targetDir = join('deploy', target, cartridge.name);
  await ensureDirectoryExists(targetDir);
  
  // Copy cartridge files to the target directory
  await copyFile(cartridgeJsonPath, join(targetDir, 'cartridge.json'));
  
  // Copy A2ML manifest and panll descriptor if they exist
  try {
    await copyFile(join(cartridgeDir, `${cartridge.name}.a2ml.json`), join(targetDir, `${cartridge.name}.a2ml.json`));
  } catch (error) {
    console.warn(`A2ML manifest not found: ${error.message}`);
  }
  
  try {
    await copyFile(join(cartridgeDir, `${cartridge.name}.panll.json`), join(targetDir, `${cartridge.name}.panll.json`));
  } catch (error) {
    console.warn(`panll descriptor not found: ${error.message}`);
  }
  
  // Apply configuration
  const configPath = join(targetDir, 'config.json');
  await writeJsonFile(configPath, config);
  
  // Scale the cartridge (placeholder for actual scaling logic)
  console.log(`Scaling cartridge to ${scale} instances...`);
  
  return {
    cartridge,
    target,
    scale,
    config,
    targetDir,
  };
}

async function main() {
  const args = process.argv.slice(2);
  
  if (args.length < 2) {
    console.error('Usage: node provisioner.js <cartridge-dir> <target> [--scale <scale>] [--config <config-file>]');
    process.exit(1);
  }
  
  const cartridgeDir = args[0];
  const target = args[1];
  const scaleIndex = args.indexOf('--scale');
  const scale = scaleIndex !== -1 ? parseInt(args[scaleIndex + 1], 10) : 1;
  const configIndex = args.indexOf('--config');
  const configFile = configIndex !== -1 ? args[configIndex + 1] : null;
  
  let config = {};
  if (configFile) {
    try {
      config = await readJsonFile(configFile);
    } catch (error) {
      console.error('Error reading config file:', error);
      process.exit(1);
    }
  }
  
  try {
    console.log(`Deploying cartridge from ${cartridgeDir} to ${target}...`);
    const result = await deployCartridge(cartridgeDir, target, { scale, config });
    
    console.log('Cartridge deployed successfully:');
    console.log(`  Name: ${result.cartridge.name}`);
    console.log(`  Target: ${result.target}`);
    console.log(`  Scale: ${result.scale}`);
    console.log(`  Config: ${JSON.stringify(result.config)}`);
    console.log(`  Target Directory: ${result.targetDir}`);
  } catch (error) {
    console.error('Error deploying cartridge:', error);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { deployCartridge };

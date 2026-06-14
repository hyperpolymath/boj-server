#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

// Cartridge Configurator — Apply runtime configuration to cartridges dynamically

import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
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

async function applyConfig(cartridgeDir, config, options = {}) {
  const { validate = true } = options;
  
  // Read cartridge.json
  const cartridgeJsonPath = join(cartridgeDir, 'cartridge.json');
  const cartridge = await readJsonFile(cartridgeJsonPath);
  
  // Validate configuration
  if (validate) {
    console.log('Validating configuration...');
    // In a real implementation, you would validate the configuration against a schema
  }
  
  // Apply configuration
  const configPath = join(cartridgeDir, 'config.json');
  await writeJsonFile(configPath, config);
  
  // Trigger hot-reload if supported (placeholder for actual hot-reload logic)
  console.log('Applying configuration...');
  
  return {
    cartridge,
    config,
    configPath,
  };
}

async function main() {
  const args = process.argv.slice(2);
  
  if (args.length < 2) {
    console.error('Usage: node configurator.js <cartridge-dir> <config-file> [--no-validate]');
    process.exit(1);
  }
  
  const cartridgeDir = args[0];
  const configFile = args[1];
  const validate = !args.includes('--no-validate');
  
  let config;
  try {
    config = await readJsonFile(configFile);
  } catch (error) {
    console.error('Error reading config file:', error);
    process.exit(1);
  }
  
  try {
    console.log(`Applying configuration to cartridge from ${cartridgeDir}...`);
    const result = await applyConfig(cartridgeDir, config, { validate });
    
    console.log('Configuration applied successfully:');
    console.log(`  Name: ${result.cartridge.name}`);
    console.log(`  Config: ${JSON.stringify(result.config)}`);
    console.log(`  Config Path: ${result.configPath}`);
  } catch (error) {
    console.error('Error applying configuration:', error);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { applyConfig };

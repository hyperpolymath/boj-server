#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

// Panel Harness — Bridge cartridges to BoJ Server and panll

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

async function registerCartridge(cartridgeDir, target, options = {}) {
  const { routes = [] } = options;
  
  // Read cartridge.json
  const cartridgeJsonPath = join(cartridgeDir, 'cartridge.json');
  const cartridge = await readJsonFile(cartridgeJsonPath);
  
  // Ensure the target directory exists
  const targetDir = join('harness', target, cartridge.name);
  await ensureDirectoryExists(targetDir);
  
  // Register the cartridge with the target
  console.log(`Registering cartridge with ${target}...`);
  
  // In a real implementation, you would register the cartridge with BoJ Server or panll here
  // For now, we'll just log the registration
  const registration = {
    cartridge,
    target,
    routes,
    registeredAt: new Date().toISOString(),
  };
  
  // Write the registration to a file
  const registrationPath = join(targetDir, 'registration.json');
  await writeJsonFile(registrationPath, registration);
  
  return {
    cartridge,
    target,
    routes,
    registrationPath,
  };
}

async function main() {
  const args = process.argv.slice(2);
  
  if (args.length < 2) {
    console.error('Usage: node harness.js <cartridge-dir> <target> [--routes <routes-file>]');
    process.exit(1);
  }
  
  const cartridgeDir = args[0];
  const target = args[1];
  const routesIndex = args.indexOf('--routes');
  const routesFile = routesIndex !== -1 ? args[routesIndex + 1] : null;
  
  let routes = [];
  if (routesFile) {
    try {
      routes = await readJsonFile(routesFile);
    } catch (error) {
      console.error('Error reading routes file:', error);
      process.exit(1);
    }
  }
  
  try {
    console.log(`Registering cartridge from ${cartridgeDir} with ${target}...`);
    const result = await registerCartridge(cartridgeDir, target, { routes });
    
    console.log('Cartridge registered successfully:');
    console.log(`  Name: ${result.cartridge.name}`);
    console.log(`  Target: ${result.target}`);
    console.log(`  Routes: ${JSON.stringify(result.routes)}`);
    console.log(`  Registration Path: ${result.registrationPath}`);
  } catch (error) {
    console.error('Error registering cartridge:', error);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { registerCartridge };

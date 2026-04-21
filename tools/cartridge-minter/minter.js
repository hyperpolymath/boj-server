#!/usr/bin/env node
// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// Cartridge Minter — Package, sign, and version cartridges

import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { exec } from 'node:child_process';
import { promisify } from 'node:util';

const execAsync = promisify(exec);

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

async function mintCartridge(cartridgeDir, outputDir, options = {}) {
  const { sign = false, version = '0.1.0' } = options;
  
  // Read cartridge.json
  const cartridgeJsonPath = join(cartridgeDir, 'cartridge.json');
  const cartridge = await readJsonFile(cartridgeJsonPath);
  
  // Update version
  cartridge.version = version;
  
  // Generate A2ML Manifest
  const a2mlManifest = {
    spdx: 'PMPL-1.0-or-later',
    name: cartridge.name,
    version: cartridge.version,
    description: cartridge.description,
    domain: cartridge.domain,
    tier: cartridge.tier,
    protocols: cartridge.protocols,
    tools: cartridge.tools,
  };
  
  // Generate panll Descriptor
  const panllDescriptor = {
    name: cartridge.name,
    version: cartridge.version,
    description: cartridge.description,
    domain: cartridge.domain,
    tier: cartridge.tier,
    protocols: cartridge.protocols,
    tools: cartridge.tools,
  };
  
  // Ensure output directory exists
  await ensureDirectoryExists(outputDir);
  
  // Write A2ML Manifest
  const a2mlManifestPath = join(outputDir, `${cartridge.name}.a2ml.json`);
  await writeJsonFile(a2mlManifestPath, a2mlManifest);
  
  // Write panll Descriptor
  const panllDescriptorPath = join(outputDir, `${cartridge.name}.panll.json`);
  await writeJsonFile(panllDescriptorPath, panllDescriptor);
  
  // Sign the cartridge (placeholder for actual signing logic)
  if (sign) {
    console.log('Signing cartridge (placeholder)...');
    // In a real implementation, you would use a tool like Sigstore or GPG to sign the cartridge
  }
  
  return {
    cartridge,
    a2mlManifest,
    panllDescriptor,
    a2mlManifestPath,
    panllDescriptorPath,
  };
}

async function main() {
  const args = process.argv.slice(2);
  
  if (args.length < 2) {
    console.error('Usage: node minter.js <cartridge-dir> <output-dir> [--sign] [--version <version>]');
    process.exit(1);
  }
  
  const cartridgeDir = args[0];
  const outputDir = args[1];
  const sign = args.includes('--sign');
  const versionIndex = args.indexOf('--version');
  const version = versionIndex !== -1 ? args[versionIndex + 1] : '0.1.0';
  
  try {
    console.log(`Minting cartridge from ${cartridgeDir}...`);
    const result = await mintCartridge(cartridgeDir, outputDir, { sign, version });
    
    console.log('Cartridge minted successfully:');
    console.log(`  Name: ${result.cartridge.name}`);
    console.log(`  Version: ${result.cartridge.version}`);
    console.log(`  A2ML Manifest: ${result.a2mlManifestPath}`);
    console.log(`  panll Descriptor: ${result.panllDescriptorPath}`);
    
    if (sign) {
      console.log('  Signed: Yes');
    }
  } catch (error) {
    console.error('Error minting cartridge:', error);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { mintCartridge };

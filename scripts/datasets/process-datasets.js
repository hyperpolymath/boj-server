#!/usr/bin/env node
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

// Process and Integrate Datasets

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

async function processDatasets() {
  const datasetsDir = 'datasets';
  const outputDir = 'processed-datasets';
  
  // Ensure the output directory exists
  await ensureDirectoryExists(outputDir);
  
  // Read all dataset files
  const files = await readdir(datasetsDir);
  const datasets = [];
  
  for (const file of files) {
    if (file.endsWith('.json')) {
      const dataset = await readJsonFile(join(datasetsDir, file));
      datasets.push(dataset);
    }
  }
  
  // Process and integrate the datasets
  const processedDatasets = datasets.map((dataset) => {
    // Add metadata to the dataset
    return {
      ...dataset,
      metadata: {
        source: 'open-dataset',
        processedAt: new Date().toISOString(),
        version: '1.0.0',
      },
    };
  });
  
  // Write the processed datasets to files
  for (const dataset of processedDatasets) {
    const fileName = `${dataset.id || 'dataset'}-processed.json`;
    await writeJsonFile(join(outputDir, fileName), dataset);
  }
  
  return processedDatasets;
}

async function main() {
  try {
    console.log('Processing datasets...');
    const datasets = await processDatasets();
    console.log(`Processed ${datasets.length} datasets.`);
  } catch (error) {
    console.error('Error processing datasets:', error);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { processDatasets };

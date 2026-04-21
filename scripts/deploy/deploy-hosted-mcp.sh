#!/bin/bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

# Deploy Hosted MCP Servers

# This script deploys hosted MCP servers for improved accessibility.
# It supports deploying to various cloud providers and platforms.

set -euo pipefail

echo "=== Deploy Hosted MCP Servers ==="

# Check if the required tools are installed
if ! command -v docker &>/dev/null; then
  echo "Error: Docker is not installed. Please install Docker first."
  exit 1
fi

if ! command -v kubectl &>/dev/null; then
  echo "Error: kubectl is not installed. Please install kubectl first."
  exit 1
fi

# Build the Docker image
echo "Building Docker image..."
docker build -f Containerfile -t boj-server:latest .

# Push the Docker image to a container registry
echo "Pushing Docker image to container registry..."
docker tag boj-server:latest ghcr.io/hyperpolymath/boj-server:latest
docker push ghcr.io/hyperpolymath/boj-server:latest

# Deploy to Kubernetes
echo "Deploying to Kubernetes..."
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Wait for the deployment to be ready
echo "Waiting for deployment to be ready..."
kubectl wait --for=condition=available deployment/boj-server --timeout=300s

# Get the service URL
echo "Getting service URL..."
kubectl get service boj-server

# Deploy to Cloudflare Workers
echo "Deploying to Cloudflare Workers..."
npm run deploy:workers

# Deploy to Vercel
echo "Deploying to Vercel..."
npm run deploy:vercel

# Deploy to Netlify
echo "Deploying to Netlify..."
npm run deploy:netlify

echo "=== Deployment Complete ==="

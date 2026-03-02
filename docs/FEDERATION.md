# Umoja Federation — Distributed Hosting Model

## Philosophy

*Umoja* means **Unity** in Swahili. The Umoja network is a distributed federation of community-hosted BoJ servers. Like Tor or IPFS, it relies on volunteers donating compute time to create shared infrastructure.

The model: you don't need a hosting budget if the community IS the hosting.

## How It Works

### For node operators

1. Pull the BoJ container from the Stapeln supply chain
2. Run it locally (Podman, never Docker)
3. Your node appears in the Umoja network via gossip protocol
4. Requests are routed to you when you're online and healthy

### For users

1. Your AI reads the Teranga menu
2. If your local BoJ has the cartridge: served locally
3. If not, the request is routed to a community node that has it
4. All routing is transparent — the AI doesn't need to know which node serves it

### Trust model

**Hash attestation** is the core trust mechanism:

- Every BoJ binary has a SHA-256 hash
- Community nodes prove their binary matches the canonical build
- If someone modifies their server binary, the hash won't match
- **Mismatched hash**: excluded from the community network
- **But**: they can still run locally for personal use

This is non-punitive. We don't brick your installation. We just don't vouch for it.

The **PMPL license** encodes this same principle legally — provenance metadata with cryptographic signatures is required, so the legal framework and technical framework express the same thing.

### Gossip protocol

Nodes discover each other via IPv6 gossip:

- Each node maintains a local cache of known peers
- Periodically, nodes exchange peer lists
- New nodes propagate through the network
- Stale nodes (not seen for >1 hour) are deprioritised
- Byzantine fault tolerant — the network survives bad actors

### Load-aware routing

- Each node reports a load factor (0-100%)
- Nodes above 80% capacity are deprioritised
- Requests route to the healthiest available node
- If all nodes are overloaded, local execution is preferred

## Contributing a node

### Requirements

- Any computer running Podman
- IPv6 connectivity (no IPv4-only setups)
- Willingness to run the node during your uptime
- Agreement to the Community Node Policy (see below)

### Community Node Policy

1. **Don't modify the binary** — run the canonical build or you're off the network
2. **Don't use the network for illegal purposes** — we will remove attested status
3. **Be a good neighbour** — report issues, don't hoard bandwidth
4. **No guarantees required** — if your computer is off, your node is off. That's fine.

### What you get

- Your node appears in the Umoja network
- If you contribute a verified cartridge (passes `IsUnbreakable`), it goes in the Ayo menu with your name
- You're part of building distributed developer infrastructure
- IndieWeb integration: your node can participate in the IndieWeb community

## IndieWeb Integration

The IndieWeb community values self-hosting, federation, and ownership of your tools. BoJ's model aligns perfectly:

- Each BoJ node is independently hosted (IndieWeb principle: own your tools)
- Webmention support for discovery
- Microsub/Micropub compatibility where relevant
- The network grows organically, like the IndieWeb itself

## Seed Nodes

The initial network starts with four family nodes:

| Region | Operator | Notes |
|--------|----------|-------|
| Europe West (UK) | hyperpolymath | Primary development |
| Europe Central | family | Son's node |
| Oceania (Australia) | family | Brother's node |
| Americas | family | US node |

Four continents from day one. Georedundancy without a hosting budget.

## Security Layers

Community nodes benefit from the full BoJ security stack:

- **Stapeln supply chain**: Chainguard base images, signed containers
- **Vordr**: Runtime monitoring, ephemeral port management
- **Svalinn**: Edge gateway policy enforcement
- **Auto-SDP**: Software Defined Perimeter — zero exposed ports until authenticated
- **DoQ/DoH**: Encrypted DNS resolution for all BoJ traffic
- **oDNS**: Oblivious DNS relay option for maximum privacy
- **Hash attestation**: Binary integrity verification
- **PMPL provenance**: Cryptographic lineage tracking

## Future: Dynamic Threat Response

BoJ cartridges can be used with Aerie for dynamic threat response:

- Monitor evolving threats via the observe domain
- Rapidly deploy server structures to meet threats
- Use PanLL hybrid automation for modifying configurations
- Community nodes can coordinate responses via the gossip protocol

This is on the roadmap, not the current phase.

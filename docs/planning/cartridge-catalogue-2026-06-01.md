<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# Cartridge Catalogue Plan — 2026-06-01

> **Status**: draft for owner review. ~941 candidates surveyed across 6 buckets by 6 parallel Explore subagents; this document is the synthesis + framework + decision points.
>
> **Author**: Claude Opus 4.7 (session: boj-server)
> **Scope**: planning artefact. No cartridges built. No PRs filed.
> **Sources**: agent transcripts in `/tmp/claude-1000/.../tasks/`; existing inventories from `gh api repos/hyperpolymath/{boj-server,boj-server-cartridges}/contents`.

---

## 1. Framework — the three axes a cartridge gets pinned on

Generating 1000 cartridge rows by free-form brainstorm is padding by row 200. A planning framework that **scales to 1000 by construction** is more useful: pin every candidate on three orthogonal axes so the catalogue self-prioritises.

### Axis A — substrate (what the cartridge sits on)

10 buckets — every existing cartridge fits cleanly into exactly one. New candidates inherit the bucket's defaults (trust tier ceiling, expected protocols, FFI shape).

| # | Substrate | Examples already in 125 inventory |
|---|---|---|
| 1 | Relational DB / KV / Doc / Time-series / Object store | postgresql-mcp, redis-mcp, sqlite-mcp |
| 2 | Cloud control plane | aws-mcp, gcp-mcp, hetzner-mcp |
| 3 | Container / orchestration / IaC / config | k8s-mcp, iac-mcp |
| 4 | Edge / CDN / DNS / networking | cloudflare-mcp, vercel-mcp |
| 5 | Language tools (LSP / format / lint / DAP / BSP) | affinescript-mcp, ephapax-mcp |
| 6 | Observability / metrics / tracing / log | observe-mcp, grafana-mcp |
| 7 | Security / auth / secrets / supply-chain | vault-mcp, vordr-mcp, rokur-mcp |
| 8 | AI / ML / embedding / agent / knowledge | agent-mcp, nesy-mcp, local-coord-mcp |
| 9 | Domain APIs (finance / legal / health / ed / science) | zotero-mcp, todoist-mcp |
| 10 | IO + hardware + human interface | (sparse) |

### Axis B — tier (where in the dependency graph)

Same as the existing TOPOLOGY tiering. Cartridges higher in the dep graph cost more.

| # | Tier | Cost-per-cartridge intuition |
|---|---|---|
| 1 | Foundational | "gates of life" — DB / git / HTTP / auth. Already mostly built. |
| 2 | Infrastructure | cloud / k8s / CI / observability. Mostly built. |
| 3 | Domain | bio / legal / finance / education / science. Long-tail growth area. |
| 4 | Exotic | quantum / SDR / AR-VR / robotics. Hardware-coupled; high effort, high differentiation. |

### Axis C — trust grade (existing CRG)

Per `standards/cartridges/CARTRIDGE-FORMAT.adoc`: Ayo / Eno / Teranga / Shield. Trust gates which protocols the cartridge can speak and which dirs are mandatory:

- **Ayo** (baseline): cartridge.json + mod.js + Zig adapter + optional FFI. ~2 days to scaffold.
- **Eno** (medium): + Zig FFI required. ~1 week.
- **Teranga** (high): + Idris2 ABI required, formally verified state machine. ~2-3 weeks.
- **Shield** (highest): + adversary model + audit trail + Idris2 invariants on all protocol entry points. ~4-8 weeks.

**Pragmatic target distribution for 1000-cartridge expansion**: ~70% Ayo (700) / ~20% Eno (200) / ~8% Teranga (80) / ~2% Shield (20). Going heavier on Teranga/Shield doubles or triples the total build cost.

---

## 2. Three decision points to call before catalogue expansion

These are load-bearing — the answer changes the inventory shape materially.

### Decision 1 — multi-protocol cartridge vs sibling family

The schema (`cartridge.json` `protocols[]` array) supports **one cartridge declaring many protocols**. The current 125-cartridge convention is **one cartridge per role suffix** (`aws-mcp`, separately a hypothetical `aws-lsp`, separately `aws-dap`, etc.).

For the dev-tools bucket especially the difference is enormous:

- **Per-role family**: 32 languages × {lsp, format, lint, dap, bsp} ≈ **120 cartridges**.
- **Per-language multi-protocol**: 32 languages × 1 cartridge each ≈ **32 cartridges**.

Same surface, ~88 cartridge slots difference. The user's framing ("it should contain the mcp, lsp, debug, build, formatter, linter") reads as "one cartridge per package, declares many protocols" — i.e. the multi-protocol route. If that's the intended design, **the existing 125 partly mis-follow the convention** and a future consolidation would collapse families like `aws-mcp` to a single `aws` cartridge declaring `[MCP, LSP, DAP, BSP, Format, Lint]`.

**Open question**: which way? Recommend multi-protocol per package — fewer cartridges, less duplicate cartridge.json metadata, easier discovery (one row per substrate). Migration path: keep `<name>-mcp` aliases for one release cycle then sunset.

### Decision 2 — tooling stubs must be retired or rewritten before expansion

Agent C found:

- ✅ **Cartridge minter** — retired 2026-04-25 (Node.js policy). Replaced by `launch-scaffolder` (Rust, production-ready, has `mint`/`provision`/`config` subcommands).
- ⚠️ **Cartridge provisioner** — stub since 2026-04-21. README documents the invocation, the body is `// In a real implementation, you would …`. Writes JSON, does nothing else.
- ⚠️ **Cartridge configurator** — stub since 2026-04-21. Validation is no-op; hot-reload unimplemented.
- ⚠️ **Panel harness** — stub since 2026-04-21. Cartridge "registration" writes a `registration.json` and stops.

The three stubs are **README-and-stub-only**. A new contributor following the docs sees the invocation succeed and assumes things worked. **This is worse than missing tooling.**

**Recommended sequence**:
1. Decide: retire the three stubs (route everything through `launch-scaffolder` subcommands — they already exist), or rewrite them properly in Rust / Zig per estate policy.
2. End-to-end-validate one fresh cartridge through the chosen pipeline.
3. *Then* start catalogue expansion.

Without this, every contributor will hit the same stub trap independently.

### Decision 3 — backfill the 14 canonical-only LSPs first

From the boj-server ↔ boj-server-cartridges drift survey (already saved as memory `project_boj_server_cartridges_sync_2026_06_01`):

14 cartridges exist in `boj-server-cartridges/cartridges/` but **NOT** in `boj-server/cartridges/`:

```
cloud-lsp, container-lsp, database-lsp, git-lsp, iac-lsp, k8s-lsp,
librarian-mcp, npc-mcp, observe-lsp, proof-lsp, queues-lsp,
secrets-lsp, ssg-lsp, stack-orchestrator-mcp
```

These are low-cost wins — already designed, already in canonical source. Default-config boj-server operators (no fetcher run) never see them. **Backfill before expand**: ~14 cheap PRs to bring the runtime in line with canonical, then start adding new cartridges.

Also flagged by the drift survey (not strictly catalogue-blocking but ought to be ticketed):

- `"category"` field present in runtime cartridge.json, absent in canonical — fetcher silently drops it (no schema validation in `catalog.ex`).
- Fetcher's `find | sort` flat copy silently picks first-wins on name collisions across domains.

---

## 3. Catalogue — 941 candidates across 6 buckets

Sourced from 6 parallel Explore subagents. Each entry carries effort (`S`/`M`/`L`) and trust-tier guess (`Ayo`/`Eno`/`Teranga`/`Shield`).

> **Naming convention note**: agents tagged with `-mcp` per current convention. If Decision 1 lands on multi-protocol-per-package, names collapse — e.g. `cockroachdb-mcp` becomes `cockroachdb` declaring `[MCP, LSP]` if SQL tooling is bundled.

### §1 — Data & Storage (119 candidates)

#### Relational databases (20)
cockroachdb-mcp, timescaledb-mcp, planetscale-mcp, mariadb-mcp, oracle-database-mcp, yugabyte-mcp, citus-mcp, memsql-mcp, singlestore-mcp, foundationdb-mcp, alloydb-mcp, ravendb-mcp, couchdb-mcp, ferretdb-mcp, dolt-mcp, liquibase-mcp, flyway-mcp, prql-mcp, readyset-mcp, pg-partman-mcp

#### Document / KV / Time-series (21)
dynamodb-mcp, firestore-mcp, couchbase-mcp, etcd-mcp, consul-mcp, memcached-mcp, tarantool-mcp, scylla-mcp, cassandra-mcp, riak-mcp, voldemort-mcp, leveldb-mcp, rocksdb-mcp, badger-mcp, lmdb-mcp, hazelcast-mcp, ignite-mcp, cosmosdb-mcp, keydb-mcp, valkey-mcp, replicant-mcp

#### Object storage / S3-compatible (22)
minio-mcp, wasabi-mcp, backblaze-b2-mcp, digitalocean-spaces-mcp, vultr-object-storage-mcp, linode-object-storage-mcp, fastly-s3-mcp, supabase-storage-mcp, neon-storage-mcp, cloudflare-r2-mcp, iceberg-mcp, delta-lake-mcp, hudi-mcp, ceph-mcp, seaweedfs-mcp, moto-mcp, localstack-mcp, ovh-object-storage-mcp, scaleway-object-storage-mcp, qiniu-mcp, aliyun-oss-mcp, huaweicloud-obs-mcp

#### Search & analytics (21)
opensearch-mcp, meilisearch-mcp, algolia-mcp, typesense-mcp, tantivy-mcp, blast-mcp, tinyindex-mcp, xapian-mcp, whoosh-mcp, sphinx-mcp, solr-mcp, manticore-mcp, typesense-cloud-mcp, zinc-mcp, linsearch-mcp, vespa-mcp, myscale-mcp, lance-mcp, vald-mcp, jina-mcp, elasticsearch-serverless-mcp

#### Data warehouses & lakehouses (29)
datafusion-mcp, apache-druid-mcp, presto-mcp, trino-mcp, dbt-mcp, dbt-cloud-mcp, fivetran-mcp, airbyte-mcp, stitch-mcp, materialize-mcp, kestra-mcp, apache-airflow-mcp, prefect-mcp, dagster-mcp, metaflow-mcp, great-expectations-mcp, talend-mcp, informatica-mcp, apache-atlas-mcp, collibra-mcp, meltano-mcp, census-mcp, hightouch-mcp, soda-mcp, trifacta-mcp, apache-flink-mcp, pulsar-mcp, nifi-mcp, dbt-squared-mcp

### §2 — Dev Tools & Languages (163 candidates)

**Note**: this slice is most affected by Decision 1. If we go multi-protocol-per-package, the per-language family below collapses to one row per language.

#### Per-language tool families (~120 entries; 30 languages)
Languages with all 4-5 role variants (lsp/format/lint/dap/bsp): python, javascript, typescript, go, rust, java, c, cpp, csharp, ruby, php, swift, kotlin, scala, haskell, elixir, lua, ocaml, perl, bash, r, julia, dart, clojure, commonlisp, vim-script, toml, yaml, json, graphql, sql (+ tsql, postgresql variants)

Sample (just python): `python-lsp`, `python-format`, `python-lint`, `python-dap`, `python-bsp`. Repeat per-language. **120 names total**.

#### Build systems & package managers (18)
make-bsp, cmake-bsp, ninja-bsp, bazel-bsp, scons-bsp, gradle-bsp, maven-bsp, go-modules-bsp, cargo-bsp, dotnet-bsp, swift-package-bsp, pyenv-bsp, nvm-bsp, rbenv-bsp, jenv-bsp, asdf-bsp, crates-index-bsp, npm-registry-bsp (+ pypi-bsp, maven-central-bsp, hex-bsp)

#### Testing / fuzzing / benchmarking (25)
pytest-cart, unittest-cart, jest-cart, mocha-cart, vitest-cart, junit-cart, testng-cart, gtest-cart, catch2-cart, ctest-cart, cargo-test-cart, go-test-cart, rspec-cart, phpunit-cart, swift-testing-cart, elixir-test-cart, libfuzzer-cart, honggfuzz-cart, afl-cart, proptest-cart, hypothesis-cart, quickcheck-cart, jqwik-cart, criterion-cart, bencher-cart, jmh-cart, benchmark-go-cart, pytest-benchmark-cart

### §3 — Cloud, Infra, Container (150 candidates)

#### Cloud providers (30)
oracle-cloud-mcp, alibaba-mcp, huawei-cloud-mcp, ibm-cloud-mcp, packet-mcp, vultr-mcp, akamai-mcp, upcloud-mcp, scaleway-mcp, backblaze-mcp, ionos-mcp, bunnycdn-mcp, civo-mcp, exoscale-mcp, ovh-mcp, greenhost-mcp, citycloud-mcp, joyent-triton-mcp, upyun-mcp, tencentcloud-mcp, kingsoft-mcp, zadara-mcp, phoenixnap-mcp, contabo-mcp, infomaniak-mcp, genesis-cloud-mcp, vast-mcp, modal-mcp, fly-io-mcp, render-cloud-mcp

#### Containers & orchestration (30)
podman-mcp, containerd-mcp, docker-compose-mcp, nomad-mcp, mesos-mcp, swarm-mcp, cri-o-mcp, moby-mcp, lxc-lxd-mcp, openstack-mcp, vmware-tanzu-mcp, redhat-openshift-mcp, canonical-microk8s-mcp, k3s-mcp, k0s-mcp, serf-mcp, consul-svc-mcp, linkerd-mcp, istio-mcp, kuma-mcp, flannel-mcp, calico-mcp, cilium-mcp, weave-mcp, openebs-mcp, longhorn-mcp, rook-mcp, operator-sdk-mcp, helm-mcp, kustomize-mcp

#### IaC & config management (31)
pulumi-mcp, cdktf-mcp, tofu-mcp, crossplane-mcp, cloud-formation-mcp, heat-mcp, troposphere-mcp, cdktf-providers-mcp, jsonnet-mcp, jinja2-mcp, cdk-mcp, salt-mcp, puppet-mcp, chef-mcp, guix-mcp, nixos-mcp, guix-mcp, ignition-mcp, cloud-init-mcp, kickstart-mcp, preseed-mcp, packer-mcp, vagrant-mcp, blueprint-mcp, arm-templates-mcp, bicep-mcp, sarl-mcp, cue-mcp, dhall-mcp, hcl-mcp, tctl-mcp

#### Edge / CDN / DNS (32)
akamai-edge-mcp, fastly-mcp, bunny-mcp, limelight-networks-mcp, maxcdn-mcp, section-mcp, route53-mcp, azure-dns-mcp, gcp-cloud-dns-mcp, dnsimple-mcp, linode-dns-mcp, namecheap-api-mcp, godaddy-api-mcp, verisign-mcp, bind9-mcp, coredns-mcp, dnsmasq-mcp, powerdns-mcp, easyname-mcp, ns1-mcp, constellix-mcp, edgedns-mcp, cloudxns-mcp, zonomi-mcp, ttk-dns-mcp, edgecast-mcp, incapsula-mcp, keycdn-mcp, cdn77-mcp, quic-edge-mcp, worker-mcp

#### Networking / service mesh / LB (27)
envoy-mcp, nginx-mcp, haproxy-mcp, traefik-mcp, caddy-mcp, keepalived-mcp, gobetween-mcp, nlb-mcp, elb-alb-mcp, gcp-load-balancing-mcp, azure-lb-mcp, azure-appgw-mcp, f5-bigip-mcp, citrix-mcp, radware-mcp, barracuda-mcp, kemp-mcp, octavia-mcp, avi-networks-mcp, riverbed-mcp, thousand-eyes-mcp, vrrp-mcp, bgp-mcp, mpls-mcp, gre-mcp, wireguard-mcp, openvpn-mcp, strongswan-mcp, zerotier-mcp, tailscale-mcp, headscale-mcp, netmaker-mcp, tinc-mcp

### §4 — Observability, Security, Governance (202 candidates)

**Trust-tier note**: ~80% land at Teranga or Shield — security-boundary placement.

#### Observability / logging / metrics / tracing (30)
tempo-mcp, jaeger-mcp, newrelic-mcp, dynatrace-mcp, elastic-apm-mcp, opentelemetry-collector-mcp, honeycomb-mcp, lightstep-mcp, signoz-mcp, loki-mcp, elk-stack-mcp, splunk-mcp, clickhouse-stats-mcp, victorops-mcp, pagerduty-mcp, opsgenie-mcp, rundeck-mcp, datadog-mcp, new-relic-synthetics-mcp, uptimerobot-mcp, statuspage-mcp, scout-mcp, instana-mcp, coralogix-mcp, sumo-logic-mcp, grafana-loki-advanced-mcp, falco-mcp, auditbeat-mcp, osquery-mcp, wazuh-mcp, ossec-mcp

#### Security scanners / vulnerability DBs / SAST/DAST (42)
snyk-mcp, trivy-mcp, grype-mcp, owasp-dependency-check-mcp, black-duck-mcp, whitesource-mcp, checkmarx-mcp, sonarqube-mcp, fortify-mcp, veracode-mcp, burpsuite-mcp, owasp-zap-mcp, nessus-mcp, openvas-mcp, qualys-mcp, rapid7-insightvm-mcp, aqua-mcp, neuvector-mcp, twistlock-mcp, anchore-mcp, clair-mcp, falco-rules-mcp, appshield-mcp, frida-mcp, ghidra-mcp, ida-pro-mcp, yara-mcp, osquery-vulns-mcp, gitguardian-mcp, trufflehog-mcp, detect-secrets-mcp, gitleaks-mcp, nuclei-mcp, burp-collaborator-mcp, metasploit-mcp, cobalt-strike-mcp, maltego-mcp, shodan-mcp, cve-search-mcp, nvd-mirror-mcp

#### Identity / auth / secrets (40)
keycloak-mcp, auth0-mcp, okta-mcp, azuread-mcp, google-workspace-mcp, cognito-mcp, firebaseauth-mcp, magic-links-mcp, webauthn-mcp, totp-mcp, hotp-mcp, duo-mcp, twilio-authy-mcp, yubico-mcp, crowdstrike-identity-mcp, delinea-mcp, beyondtrust-mcp, cyberark-mcp, hashicorp-boundary-mcp, teleport-mcp, consul-acl-mcp, istio-authpolicy-mcp, falco-rbac-mcp, spiffe-spire-mcp, mtls-enforcer-mcp, cert-manager-mcp, smallstep-mcp, ejbca-mcp, openssl-pki-mcp, lets-encrypt-mcp, entrust-mcp, digicert-mcp, mozilla-sops-mcp, sealed-secrets-mcp, external-secrets-mcp, infisical-mcp, 1password-mcp, lastpass-mcp, bitwarden-mcp, dashlane-mcp

#### Compliance / audit / governance / policy (48)
openpolicy-mcp, kyverno-mcp, kubewarden-mcp, gatekeeper-mcp, calico-policy-mcp, cilium-policy-mcp, falco-policy-mcp, apparmor-mcp, selinux-mcp, osquery-audit-mcp, lynis-mcp, openscap-mcp, vuls-mcp, tenable-nessus-compliance-mcp, qualys-compliance-mcp, cloudmapper-mcp, scoutsuite-mcp, cloudsploit-mcp, prowler-mcp, cloudaudit-mcp, terraformcompliance-mcp, checkov-mcp, sentinel-mcp, cloudguard-mcp, snyk-iac-mcp, forseti-mcp, audit-tooling-mcp, auditd-mcp, log-aggregation-compliance-mcp, gdpr-mcp, ccpa-mcp, hipaa-mcp, soc2-mcp, pci-dss-mcp, iso27001-mcp, vanta-mcp, drata-mcp, cloudhealth-mcp, dome9-mcp, ermetic-mcp, wiz-mcp, clouddefense-mcp, lacework-mcp

#### Supply-chain / SBOM / attestation / provenance (42)
syft-mcp, spdx-mcp, cyclonedx-mcp, cosign-mcp, notation-mcp, sigstore-mcp, tuf-mcp, notary-mcp, in-toto-mcp, ite6-mcp, slsa-mcp, artifact-hub-mcp, helm-provenance-mcp, oci-distribution-mcp, harbor-mcp, zot-mcp, artifactory-mcp, nexus-mcp, package-build-attestation-mcp, buildkit-sbom-mcp, distroless-mcp, chainguard-images-mcp, aqua-imageassurance-mcp, binary-artifact-provenance-mcp, reproducible-builds-mcp, dependency-track-mcp, fossa-mcp, npm-audit-mcp, cargo-audit-mcp, safety-mcp, pip-audit-mcp, bundler-audit-mcp, composer-audit-mcp, license-compliance-mcp, reuse-mcp, parity-mcp, oci-index-mcp, transparency-log-mcp, pki-chain-validation-mcp

### §5 — Domain, IO, Hardware, Human (127 candidates)

#### Scientific computing / bio / chem / physics (26)
biopython-toolkit-mcp, rdkit-chemistry-mcp, numpy-scipy-mcp, pdb-protein-mcp, tandem-mass-spec-mcp, gromacs-md-mcp, quantum-cirq-mcp, nextflow-genomics-mcp, mafft-alignment-mcp, sagemaker-bioml-mcp, pymc-bayesian-mcp, fenics-fem-mcp, lammps-md-mcp, crystal-structure-mcp, cross-reactivity-mcp, metabolomics-mcp, gatk-variant-mcp, vcftools-mcp, deepvariant-mcp, enigma-pathogen-mcp, openmm-mcp, rosetta-protein-design-mcp, plumed-md-mcp, cp2k-mcp, omaha-spatial-bio-mcp, airflow-omics-mcp

#### Finance / legal / healthcare / education (25)
stripe-payments-mcp, plaid-fintech-mcp, iex-stock-data-mcp, fmp-financial-mcp, courtlistener-mcp, sec-filings-mcp, lexis-westlaw-lite-mcp, casetext-mcp, quickbooks-mcp, xero-accounting-mcp, fincen-aml-mcp, canvas-lms-mcp, moodle-lms-mcp, schoology-mcp, blackboard-lms-mcp, epic-emr-lite-mcp, cerner-fhir-mcp, fhir-clinical-mcp, medline-pubmed-mcp, clinicaltrials-mcp, medicare-mcp, pharmacy-ndc-mcp, edissmore-mcp, finaid-loan-mcp, msar-medical-edu-mcp

#### IO format converters (29)
pdf-text-extract-mcp, pdf-form-filler-mcp, epub-mcp, mobi-azw-mcp, docx-mcp, odt-mcp, markdown-mcp, latex-mcp, svg-mcp, image-ocr-mcp, video-transcode-mcp, audio-codec-mcp, parquet-arrow-mcp, avro-mcp, protobuf-mcp, msgpack-mcp, geojson-gis-mcp, postgis-mcp, netcdf-hdf5-mcp, gltf-3d-model-mcp, stl-ply-mcp, ics-calendar-mcp, vcf-genome-mcp, bam-sam-mcp, gff-gtf-mcp, cwl-wdl-mcp, csv-tsv-mcp, jsonl-ndjson-mcp, xml-soap-mcp

#### Hardware / sensors / IoT / robotics / SDR (30)
modbus-tcp-mcp, mqtt-mcp, zigbee-mcp, bluetooth-ble-mcp, usb-hid-mcp, serial-rs485-mcp, ros-robotics-mcp, opencv-vision-mcp, lidar-pointcloud-mcp, imu-accelerometer-mcp, gps-gnss-mcp, thermal-infrared-mcp, sdr-gnu-radio-mcp, rtl-sdr-mcp, ad9833-mcp, pressure-sensor-mcp, humidity-dht-mcp, mq-gas-sensor-mcp, soil-moisture-mcp, current-voltage-mcp, dji-drone-mcp, mavlink-autopilot-mcp, ultralytics-yolo-mcp, onnx-edge-mcp, tensorflow-lite-mcp, segmentation-sam-mcp, depth-stereo-mcp, hand-pose-mcp, hololens-mcp, oculus-vr-mcp

#### Human interfaces / accessibility (27)
screen-reader-bridge-mcp, wai-aria-mcp, liblouis-braille-mcp, braille-display-mcp, text-to-speech-mcp, whisper-asr-mcp, bsl-asl-mcp, sign-language-synthesis-mcp, eye-gaze-tracking-mcp, switch-input-mcp, haptic-feedback-mcp, color-blindness-mcp, dyslexia-font-mcp, high-contrast-mcp, captions-mcp, audio-description-mcp, sign-language-nlp-mcp, magnification-mcp, keyboard-navigation-mcp, low-bandwidth-text-mcp, voice-command-mcp, tremor-compensation-mcp, cognitive-load-mcp, language-simplification-mcp, gesture-recognition-mcp, mind-bci-mcp, voice-gender-adapt-mcp

#### Productivity / comms / scheduling / CRM (40)
outlook-exchange-mcp, microsoft-teams-mcp, zoom-mcp, calendly-mcp, timely-mcp, harvest-mcp, clockify-mcp, asana-mcp, monday-mcp, hubspot-crm-mcp, salesforce-mcp, pipedrive-mcp, zendesk-mcp, freshdesk-mcp, intercom-mcp, typeform-mcp, mailchimp-mcp, sendgrid-mcp, twilio-mcp, vonage-mcp, dynamics-365-mcp, sap-fiori-mcp, workday-mcp, successfactors-mcp, greenhouse-mcp, lever-ats-mcp, workable-mcp, referralhero-mcp, commsor-mcp, circle-community-mcp, mighty-networks-mcp, eventbrite-mcp, lunchclub-mcp, linkedin-recruiter-mcp, github-discussions-mcp, gumroad-mcp, patreon-mcp, substack-mcp, beehiv-mcp, makeform-mcp, ninox-mcp

### §6 — AI / ML / Agentic / Knowledge (180 candidates)

**Note**: this slice is the active growth area (boj-server #100 vector-DB and #101 multimodal already filed as planned waves). Joshua is in the cartridge-fetcher area; avoid name collisions with WIP.

#### Model providers / inference (30)
llama-cpp-mcp, ollama-mcp, vllm-mcp, text-generation-webui-mcp, exllama-mcp, mlc-llm-mcp, transformers-local-mcp, ctransformers-mcp, together-ai-mcp, modal-inference-mcp, baseten-mcp, banana-mcp, workers-ai-mcp, runpod-mcp, anyscale-mcp, hyperbolic-mcp, llava-mcp, moondream-mcp, claude-vision-local-mcp, visual-bert-mcp, blip-mcp, layoutlm-mcp, mistral-mcp, dolphin-mcp, code-llama-mcp, granite-mcp, deepseek-coder-mcp, yi-mcp, sentence-transformers-mcp, bge-mcp, e5-mcp, jinaai-mcp, cohere-rerank-mcp, rankgpt-mcp

#### Vector DBs / embedding stores / RAG (35)
milvus-mcp, vespa-vector-mcp, zinc-mcp, qdrant-cloud-mcp, pinecone-serverless-mcp, supabase-vector-mcp, neon-vector-mcp, typesense-vector-mcp, opensearch-vector-mcp, manticore-vector-mcp, elasticsearch-vector-mcp, meilisearch-vector-mcp, algolia-vector-mcp, sonic-mcp, langchain-mcp, llama-index-mcp, haystack-mcp, ragas-mcp, vectara-mcp, mixedbread-ai-mcp, bm25-retriever-mcp, dense-retriever-mcp, hybrid-retriever-mcp, hyde-mcp, small-to-big-mcp, rerank-fusion-mcp, adaptive-context-mcp, semantic-chunker-mcp, recursive-splitter-mcp, markdown-splitter-mcp, code-splitter-mcp, sliding-window-mcp

#### Knowledge graphs / ontologies / symbolic (30)
tigergraph-mcp, galaxybase-mcp, blazegraph-mcp, neptune-mcp, incense-mcp, owlready2-mcp, rdflib-mcp, protege-mcp, topquadrant-mcp, skos-mcp, dublin-core-mcp, clingo-mcp, rule-engine-mcp, prolog-mcp, forward-chaining-mcp, sparql-endpoint-mcp, inference-rules-mcp, openie-mcp, spacy-nlp-mcp, deimos-mcp, dbpedia-mcp, wikidata-mcp, schema-org-mcp, entity-resolution-mcp, property-alignment-mcp, schema-matching-mcp, graph-merge-mcp, federated-sparql-mcp

#### Document understanding / OCR / parsing (33)
tesseract-mcp, paddleocr-mcp, easyocr-mcp, doctr-mcp, surya-mcp, textract-mcp, cloudvision-mcp, azure-read-mcp, pypdf-mcp, pdfplumber-mcp, tabula-py-mcp, docling-mcp, unstructured-mcp, pandoc-doc-mcp, liboffice-mcp, aspose-mcp, table-transformer-mcp, detr-table-mcp, camelot-mcp, table2html-mcp, sparkcollab-mcp, layout-analyzer-mcp, segment-anything-mcp, document-classifier-mcp, reading-order-mcp, text-flow-mcp, entity-extractor-mcp, relation-extractor-mcp, invoice-parser-mcp, contract-parser-mcp, form-parser-mcp, metadata-extractor-mcp

#### Agentic frameworks / workflow engines (28)
autogen-mcp, crewai-mcp, agency-swarm-mcp, metagpt-mcp, superagent-mcp, phidata-mcp, swarm-mcp, prefect-agent-mcp, dagster-agent-mcp, airflow-agent-mcp, temporal-mcp, n8n-mcp, zapier-mcp, celery-mcp, rq-mcp, bull-queue-mcp, bullmq-mcp, apscheduler-mcp, schedule-mcp, llamaindex-memory-mcp, langchain-memory-mcp, langchain-tools-mcp, pydantic-tools-mcp, tool-validator-mcp, plugin-loader-mcp, capability-negotiation-mcp, agent-tracer-mcp, cost-tracker-mcp, prompt-logger-mcp

#### Multimodal (vision/audio/video/STT/TTS) (24)
vosk-mcp, silero-vad-mcp, wav2vec-mcp, deepspeech-mcp, glow-tts-mcp, tacotron2-mcp, hifigan-mcp, fastpitch-mcp, nuwave-mcp, google-tts-mcp, azure-tts-mcp, aws-polly-mcp, clip-mcp, clap-mcp, dino-mcp, internvl-mcp, qwen-vl-mcp, gemini-vision-mcp, gpt4-vision-mcp, stable-diffusion-mcp, sdxl-mcp, fooocus-mcp, animagine-mcp, controlnet-mcp, lora-fusion-mcp, dalle3-mcp, midjourney-mcp, video-classification-mcp, videoclip-mcp, slowfast-mcp, video-captioning-mcp, temporal-segmentation-mcp, pose-estimation-mcp, object-tracking-mcp, librosa-mcp, soundfile-mcp, pydub-mcp, music-generation-mcp, musicautobot-mcp, source-separation-mcp, key-tempo-mcp, spotify-audio-mcp, multimodal-embedding-mcp, cross-modal-retrieval-mcp, vision-language-chain-mcp, audio-visual-fusion-mcp, multimodal-retrieval-augmented-mcp

---

## 4. Prioritisation — what to build first

Following the decision points above, the recommended phasing is:

### Phase 0 — tooling fix (1-2 weeks, blocks everything)
1. Decide retire-vs-rewrite for the three stubs (provisioner / configurator / panel-harness).
2. End-to-end-validate one cartridge through `launch-scaffolder mint → provision → config → publish`.
3. Document the chosen path in `docs/specification/cartridge-lifecycle.adoc`.

### Phase 1 — backfill (1 week, low cost)
4. Bring the 14 canonical-only LSPs from `boj-server-cartridges` into `boj-server/cartridges/`.
5. File issue for the `"category"` field schema mismatch + add schema validation in `catalog.ex`.

### Phase 2 — high-leverage waves (1-2 quarters)
Order by value-density (cartridges per unit substrate that ship "out of the box" capability):
6. **Vector DB + RAG wave** (boj-server#100 already tracks this) — unblocks all knowledge-base workflows.
7. **Local-inference wave** — llama.cpp, ollama, vllm, etc. — unblocks all on-device LLM work.
8. **IO converters wave** (~29 candidates in §5) — small, mechanical, broad downstream unblock.
9. **Multimodal wave** (boj-server#101 already tracks this).

### Phase 3 — depth fills (rolling)
10. Per-language LSP/format/lint families (~120 entries) — *gated on Decision 1*. If multi-protocol-per-package, drops to ~30 cartridges.
11. Cloud-provider depth (~30 entries) — high cost, low novelty; defer until specific user need.
12. Security/compliance depth (~200 entries) — high effort due to trust-tier requirements; defer.

### Phase 4 — exotic (opportunistic)
13. SDR / quantum / robotics / haptics — hardware-coupled, low priority unless specific project demand.

---

## 5. Open questions for owner

Before any of Phase 0+ ships:

1. **Decision 1**: multi-protocol-per-package, or per-role-sibling-family?
2. **Decision 2**: retire the three tooling stubs, or rewrite them in Rust/Zig?
3. **Decision 3**: green-light the 14-LSP backfill PR series (≈14 small PRs)?
4. **Trust-tier distribution target**: confirm or override the 70/20/8/2 split.
5. **Naming**: should `boj-server-cartridges`'s taxonomy (`cross-cutting/`, `domains/`, `templates/`) become the source of truth, with the boj-server flat dir treated explicitly as a fetcher-managed cache?

Answer these and I can convert any Phase into PR-ready work.

---

## Provenance

- Subagents fanned out at 2026-06-01 ~12:30Z; all 6 returned within ~30 minutes.
- Existing 125-cartridge inventory + 14-cartridge canonical-only list cross-referenced against every candidate.
- Joshua's cartridge-fetcher area (PR #169) explicitly excluded from suggestions.
- ~50-80 candidates duplicate across slices (e.g., several `prefect-mcp` / `airflow-mcp` mentions) — dedupe pass needed before any commit; nominal count is 941, true unique count probably 850-900.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

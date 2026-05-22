// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// railway-mcp/mod.js -- Railway GraphQL API v2 cartridge implementation.
//
// Provides MCP tool handlers for the Railway GraphQL API:
//   - Project management (list, get, create, delete)
//   - Service management (list, get, create, restart)
//   - Deployment management (list, get, redeploy, rollback)
//   - Environment variables (list, set, delete)
//   - Domains (list, add)
//   - Logs (retrieve)
//   - Metrics (CPU, memory, network)
//
// Auth: Bearer token via RAILWAY_TOKEN env var or vault-mcp proxy.
// API endpoint: https://backboard.railway.app/graphql/v2
// API docs: https://docs.railway.app/reference/public-api
//
// Railway's entire public API is GraphQL-only (no REST endpoints).
// All operations use POST to the single GraphQL endpoint.
//
// Usage: import { handleTool } from "./mod.js";
//    or: deno run --allow-net --allow-env mod.js

const API_BASE = "https://backboard.railway.app/graphql/v2";

// ---------------------------------------------------------------------------
// Auth helper — retrieves the Railway API token from environment.
// In production, vault-mcp provides zero-knowledge credential proxying;
// for development, RAILWAY_TOKEN is read directly.
// ---------------------------------------------------------------------------

function getToken() {
  const token = typeof Deno !== "undefined"
    ? Deno.env.get("RAILWAY_TOKEN")
    : process.env.RAILWAY_TOKEN;
  if (!token) {
    throw new Error("RAILWAY_TOKEN not set. Generate at https://railway.app/account/tokens or export RAILWAY_TOKEN.");
  }
  return token;
}

// ---------------------------------------------------------------------------
// GraphQL request helper — wraps fetch with Railway auth headers, error
// handling, and structured responses. All Railway API calls go through
// this single function since the entire API is GraphQL.
// ---------------------------------------------------------------------------

async function railwayGQL(query, variables) {
  const token = getToken();

  const response = await fetch(API_BASE, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "boj-server/railway-mcp/0.1.0",
    },
    body: JSON.stringify({
      query,
      variables: variables || {},
    }),
  });

  const data = await response.json();

  // Surface GraphQL-level errors
  if (data.errors && data.errors.length > 0) {
    const messages = data.errors.map((e) => e.message).join("; ");
    return {
      status: response.status,
      error: messages,
      data: data.data || null,
      graphqlErrors: data.errors,
    };
  }

  if (!response.ok) {
    return {
      status: response.status,
      error: `HTTP ${response.status}`,
      data: data.data || null,
    };
  }

  return { status: response.status, data: data.data };
}

// ---------------------------------------------------------------------------
// Tool handler dispatch — maps MCP tool names to Railway GraphQL operations.
// Each handler validates required arguments, builds the GraphQL query,
// and returns structured results.
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Projects ---

    case "railway_list_projects": {
      const limit = args.limit || 25;
      const query = `
        query($after: String) {
          me {
            projects(first: ${limit}, after: $after) {
              edges {
                node {
                  id
                  name
                  description
                  createdAt
                  updatedAt
                  isPublic
                  environments {
                    edges {
                      node { id name }
                    }
                  }
                  services {
                    edges {
                      node { id name }
                    }
                  }
                }
              }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
      `;
      return railwayGQL(query, { after: args.after || null });
    }

    case "railway_get_project": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      const query = `
        query($projectId: String!) {
          project(id: $projectId) {
            id
            name
            description
            createdAt
            updatedAt
            isPublic
            environments {
              edges {
                node { id name }
              }
            }
            services {
              edges {
                node {
                  id
                  name
                  createdAt
                  updatedAt
                }
              }
            }
          }
        }
      `;
      return railwayGQL(query, { projectId: args.project_id });
    }

    case "railway_create_project": {
      if (!args.name) return { error: "Missing required field: name" };
      const query = `
        mutation($input: ProjectCreateInput!) {
          projectCreate(input: $input) {
            id
            name
            description
            createdAt
            environments {
              edges {
                node { id name }
              }
            }
          }
        }
      `;
      const input = { name: args.name };
      if (args.description) input.description = args.description;
      if (args.default_environment_name) input.defaultEnvironmentName = args.default_environment_name;
      if (args.is_public !== undefined) input.isPublic = args.is_public;
      if (args.repo) input.repo = args.repo;
      return railwayGQL(query, { input });
    }

    case "railway_delete_project": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      const query = `
        mutation($id: String!) {
          projectDelete(id: $id)
        }
      `;
      return railwayGQL(query, { id: args.project_id });
    }

    // --- Services ---

    case "railway_list_services": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      const query = `
        query($projectId: String!) {
          project(id: $projectId) {
            services {
              edges {
                node {
                  id
                  name
                  createdAt
                  updatedAt
                  icon
                }
              }
            }
          }
        }
      `;
      return railwayGQL(query, { projectId: args.project_id });
    }

    case "railway_get_service": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      const query = `
        query($serviceId: String!) {
          service(id: $serviceId) {
            id
            name
            createdAt
            updatedAt
            icon
            projectId
          }
        }
      `;
      return railwayGQL(query, { serviceId: args.service_id });
    }

    case "railway_create_service": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      if (!args.name) return { error: "Missing required field: name" };
      const query = `
        mutation($input: ServiceCreateInput!) {
          serviceCreate(input: $input) {
            id
            name
            createdAt
            projectId
          }
        }
      `;
      const input = {
        projectId: args.project_id,
        name: args.name,
      };
      if (args.source) input.source = args.source;
      return railwayGQL(query, { input });
    }

    case "railway_restart_service": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.environment_id) return { error: "Missing required field: environment_id" };
      const query = `
        mutation($serviceId: String!, $environmentId: String!) {
          serviceInstanceRedeploy(serviceId: $serviceId, environmentId: $environmentId)
        }
      `;
      return railwayGQL(query, {
        serviceId: args.service_id,
        environmentId: args.environment_id,
      });
    }

    // --- Deployments ---

    case "railway_list_deployments": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      const limit = args.limit || 10;
      const query = `
        query($input: DeploymentListInput!) {
          deployments(input: $input, first: ${limit}) {
            edges {
              node {
                id
                status
                createdAt
                updatedAt
                staticUrl
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
        }
      `;
      const input = { serviceId: args.service_id };
      if (args.environment_id) input.environmentId = args.environment_id;
      if (args.status) input.status = { in: [args.status] };
      return railwayGQL(query, { input });
    }

    case "railway_get_deployment": {
      if (!args.deployment_id) return { error: "Missing required field: deployment_id" };
      const query = `
        query($id: String!) {
          deployment(id: $id) {
            id
            status
            createdAt
            updatedAt
            staticUrl
            meta
          }
        }
      `;
      return railwayGQL(query, { id: args.deployment_id });
    }

    case "railway_redeploy": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.environment_id) return { error: "Missing required field: environment_id" };
      const query = `
        mutation($serviceId: String!, $environmentId: String!) {
          serviceInstanceRedeploy(serviceId: $serviceId, environmentId: $environmentId)
        }
      `;
      return railwayGQL(query, {
        serviceId: args.service_id,
        environmentId: args.environment_id,
      });
    }

    case "railway_rollback": {
      if (!args.deployment_id) return { error: "Missing required field: deployment_id" };
      const query = `
        mutation($id: String!) {
          deploymentRollback(id: $id) {
            id
            status
            createdAt
          }
        }
      `;
      return railwayGQL(query, { id: args.deployment_id });
    }

    // --- Environment Variables ---

    case "railway_list_variables": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.environment_id) return { error: "Missing required field: environment_id" };
      const query = `
        query($projectId: String!, $serviceId: String!, $environmentId: String!) {
          variables(
            projectId: $projectId,
            serviceId: $serviceId,
            environmentId: $environmentId
          )
        }
      `;
      return railwayGQL(query, {
        projectId: args.project_id,
        serviceId: args.service_id,
        environmentId: args.environment_id,
      });
    }

    case "railway_set_variable": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.environment_id) return { error: "Missing required field: environment_id" };
      if (!args.name) return { error: "Missing required field: name" };
      if (args.value === undefined) return { error: "Missing required field: value" };
      const query = `
        mutation($input: VariableCollectionUpsertInput!) {
          variableCollectionUpsert(input: $input)
        }
      `;
      return railwayGQL(query, {
        input: {
          projectId: args.project_id,
          serviceId: args.service_id,
          environmentId: args.environment_id,
          variables: { [args.name]: args.value },
        },
      });
    }

    case "railway_delete_variable": {
      if (!args.project_id) return { error: "Missing required field: project_id" };
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.environment_id) return { error: "Missing required field: environment_id" };
      if (!args.name) return { error: "Missing required field: name" };
      const query = `
        mutation($input: VariableDeleteInput!) {
          variableDelete(input: $input)
        }
      `;
      return railwayGQL(query, {
        input: {
          projectId: args.project_id,
          serviceId: args.service_id,
          environmentId: args.environment_id,
          name: args.name,
        },
      });
    }

    // --- Domains ---

    case "railway_list_domains": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.environment_id) return { error: "Missing required field: environment_id" };
      const query = `
        query($serviceId: String!, $environmentId: String!) {
          customDomains(serviceId: $serviceId, environmentId: $environmentId) {
            id
            domain
            status {
              dnsRecords {
                hostlabel
                requiredValue
                currentValue
                zone
                status
              }
            }
            createdAt
          }
        }
      `;
      return railwayGQL(query, {
        serviceId: args.service_id,
        environmentId: args.environment_id,
      });
    }

    case "railway_add_domain": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.environment_id) return { error: "Missing required field: environment_id" };
      if (!args.domain) return { error: "Missing required field: domain" };
      const query = `
        mutation($input: CustomDomainCreateInput!) {
          customDomainCreate(input: $input) {
            id
            domain
            createdAt
          }
        }
      `;
      return railwayGQL(query, {
        input: {
          serviceId: args.service_id,
          environmentId: args.environment_id,
          domain: args.domain,
        },
      });
    }

    // --- Logs ---

    case "railway_get_logs": {
      if (!args.deployment_id) return { error: "Missing required field: deployment_id" };
      const limit = args.limit || 100;
      const query = `
        query($deploymentId: String!, $limit: Int, $filter: String) {
          deploymentLogs(deploymentId: $deploymentId, limit: $limit, filter: $filter) {
            message
            timestamp
            severity
            attributes
          }
        }
      `;
      return railwayGQL(query, {
        deploymentId: args.deployment_id,
        limit,
        filter: args.filter || null,
      });
    }

    // --- Metrics ---

    case "railway_get_metrics": {
      if (!args.service_id) return { error: "Missing required field: service_id" };
      if (!args.environment_id) return { error: "Missing required field: environment_id" };
      const query = `
        query($serviceId: String!, $environmentId: String!, $startDate: DateTime!, $endDate: DateTime!) {
          metrics(
            serviceId: $serviceId,
            environmentId: $environmentId,
            startDate: $startDate,
            endDate: $endDate
          ) {
            cpuUsage { date value }
            memoryUsageMb { date value }
            networkRxMb { date value }
            networkTxMb { date value }
          }
        }
      `;
      // Default to last 24 hours if no dates specified
      const endDate = args.end_date || new Date().toISOString();
      const startDate = args.start_date || new Date(Date.now() - 86400000).toISOString();
      return railwayGQL(query, {
        serviceId: args.service_id,
        environmentId: args.environment_id,
        startDate,
        endDate,
      });
    }

    default:
      return { error: `Unknown railway-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Cartridge metadata export — used by the BoJ cartridge loader to register
// this cartridge's tools without reading cartridge.json separately.
// ---------------------------------------------------------------------------

export const metadata = {
  name: "railway-mcp",
  version: "0.1.0",
  domain: "Cloud",
  tier: "Ayo",
  protocols: ["MCP", "GraphQL"],
  toolCount: 19,
};

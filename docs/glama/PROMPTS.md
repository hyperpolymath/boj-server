<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# BoJ Server Interactive Prompts

## Project Analysis

### Analyze Repository
**Prompt**: `Analyze this repository and suggest improvements`
**Tools Used**: `boj_research`, `coderag_analyze_repository`
**Output**: Repository structure, language breakdown, quality metrics, improvement suggestions

### Recommend Team
**Prompt**: `Recommend a team for this project`
**Tools Used**: `claude_agents_analyze_project`, `claude_agents_recommend_by_keywords`
**Output**: List of recommended roles with justifications

## Code Quality

### Detect Code Smells
**Prompt**: `Find code smells in this repository`
**Tools Used**: `coderag_calculate_metrics`, `database_query`
**Output**: List of code smells with locations and severity

### Calculate Metrics
**Prompt**: `Calculate code quality metrics`
**Tools Used**: `coderag_calculate_metrics`
**Output**: CK metrics, package coupling, architectural patterns

## Research

### Academic Research
**Prompt**: `Research [topic] and summarize findings`
**Tools Used**: `boj_research`
**Output**: Summary of academic papers, citations, and references

### Market Research
**Prompt**: `Analyze market trends for [product]`
**Tools Used**: `boj_research`, `origenemcp_search_compound`
**Output**: Market analysis, competitor comparison, trend forecast

## Notification

### Send Alert
**Prompt**: `Send alert to #devops about [issue]`
**Tools Used**: `notifyhub_send_slack`, `notifyhub_send_discord`
**Output**: Confirmation of sent notifications

### Broadcast Message
**Prompt**: `Broadcast message to all channels`
**Tools Used**: `notifyhub_send_email`, `notifyhub_send_sms`, `notifyhub_send_slack`
**Output**: Confirmation of sent messages

## Data Analysis

### Query Dataset
**Prompt**: `Query [dataset] for [information]`
**Tools Used**: `opendatamcp_query_dataset`, `database_query`
**Output**: Dataset results with visualization suggestions

### Analyze Trends
**Prompt**: `Analyze trends in [dataset]`
**Tools Used**: `opendatamcp_search_datasets`, `database_query`
**Output**: Trend analysis with charts and insights

## Memory

### Start Session
**Prompt**: `Start memory session for [project]`
**Tools Used**: `memory_session_start`
**Output**: Session ID and context from previous sessions

### Record Learning
**Prompt**: `Remember that [fact]`
**Tools Used**: `memory_learn`
**Output**: Confirmation and related learnings

### Search Memory
**Prompt**: `What do I know about [topic]?`
**Tools Used**: `memory_search`, `memory_recall`
**Output**: List of relevant memories with confidence scores

## Git Operations

### Create Pull Request
**Prompt**: `Create PR from [branch] to [target]`
**Tools Used**: `boj_github_create_pr`
**Output**: PR link and summary

### Review Issues
**Prompt**: `Show open issues for [repo]`
**Tools Used**: `boj_github_list_issues`
**Output**: List of issues with status and assignees

## Cloud Management

### Deploy to Cloudflare
**Prompt**: `Deploy [project] to Cloudflare Workers`
**Tools Used**: `boj_cloud_cloudflare`
**Output**: Deployment status and URL

### Manage AWS Resources
**Prompt**: `List S3 buckets in [region]`
**Tools Used**: `boj_cloud_verpex`
**Output**: List of buckets with sizes and permissions

## Interactive Workflows

### Setup Project
**Workflow**:
1. Analyze repository
2. Recommend team
3. Set up notifications
4. Initialize memory session

**Prompt**: `Setup project [name]`
**Output**: Project dashboard with team, notifications, and memory

### Code Review
**Workflow**:
1. Detect code smells
2. Calculate metrics
3. Create GitHub issues
4. Record learnings

**Prompt**: `Review [repository]`
**Output**: Code review report with issues and metrics

### Research Paper
**Workflow**:
1. Search academic papers
2. Analyze references
3. Summarize findings
4. Store in memory

**Prompt**: `Research [topic]`
**Output**: Research report with citations and summary

## Template Syntax

### Variables
Use `{{variable}}` syntax for dynamic values:
- `{{project}}`: Current project name
- `{{user}}`: Current user
- `{{date}}`: Current date
- `{{time}}`: Current time

### Conditional Logic
Use `{{#if condition}}...{{/if}}` for conditional sections:
```
{{#if project}}
Project: {{project}}
{{/if}}
```

### Loops
Use `{{#each items}}...{{/each}}` for loops:
```
{{#each issues}}
- {{this.title}} ({{this.status}})
{{/each}}
```

## Best Practices

1. **Be Specific**: Include relevant details in prompts
2. **Use Templates**: Start with predefined templates
3. **Review Output**: Always verify tool outputs
4. **Store Learnings**: Record important insights
5. **Session Management**: Start/end sessions appropriately

## Examples

### Example 1: Project Setup
**User**: `Setup project my-app`
**BoJ**:
1. Analyzing repository...
2. Recommending team...
3. Setting up notifications...
4. Starting memory session...
**Output**: Project dashboard with team, notifications, and memory session ID

### Example 2: Code Review
**User**: `Review repository my-app`
**BoJ**:
1. Detecting code smells...
2. Calculating metrics...
3. Creating issues...
4. Recording learnings...
**Output**: Code review report with 5 issues and quality metrics

### Example 3: Research
**User**: `Research quantum computing`
**BoJ**:
1. Searching academic papers...
2. Analyzing references...
3. Summarizing findings...
4. Storing in memory...
**Output**: Research report with 10 papers and summary

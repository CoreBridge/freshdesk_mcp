# Freshdesk MCP Server
[![smithery badge](https://smithery.ai/badge/@effytech/freshdesk_mcp)](https://smithery.ai/server/@effytech/freshdesk_mcp)

[![Trust Score](https://archestra.ai/mcp-catalog/api/badge/quality/effytech/freshdesk_mcp)](https://archestra.ai/mcp-catalog/effytech__freshdesk_mcp)

An MCP server implementation that integrates with Freshdesk, enabling AI models to interact with Freshdesk modules and perform various support operations.

## Features

- **Freshdesk Integration**: Seamless interaction with Freshdesk API endpoints
- **AI Model Support**: Enables AI models to perform support operations through Freshdesk
- **Automated Ticket Management**: Handle ticket creation, updates, and responses

## Components

### Tools

The server offers several tools for Freshdesk operations:

- `create_ticket`: Create new support tickets
  - **Inputs**:
    - `subject` (string, required): Ticket subject
    - `description` (string, required): Ticket description
    - `source` (number, required): Ticket source code
    - `priority` (number, required): Ticket priority level
    - `status` (number, required): Ticket status code
    - `email` (string, optional): Email of the requester
    - `requester_id` (number, optional): ID of the requester
    - `custom_fields` (object, optional): Custom fields to set on the ticket
    - `additional_fields` (object, optional): Additional top-level fields

- `update_ticket`: Update existing tickets
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket to update
    - `ticket_fields` (object, required): Fields to update

- `delete_ticket`: Delete a ticket
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket to delete

- `search_tickets`: Search for tickets based on criteria
  - **Inputs**:
    - `query` (string, required): Search query string

- `get_ticket_fields`: Get all ticket fields
  - **Inputs**:
    - None

- `get_tickets`: Get all tickets
  - **Inputs**:
    - `page` (number, optional): Page number to fetch
    - `per_page` (number, optional): Number of tickets per page

- `get_ticket`: Get a single ticket
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket to get

- `get_ticket_conversation`: Get conversation for a ticket
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket

- `create_ticket_reply`: Reply to a ticket
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket
    - `body` (string, required): Content of the reply
    - `cc_emails` (array of strings, optional): Additional email addresses added to the 'cc' field of the outgoing email. These supplement the ticket requester, who always remains the primary recipient
    - `bcc_emails` (array of strings, optional): Additional email addresses added to the 'bcc' field of the outgoing email. These supplement the ticket requester, who always remains the primary recipient
    - `from_email` (string, optional): Email address the reply is sent from
    - `user_id` (number, optional): ID of the agent who is adding the reply

- `create_ticket_note`: Add a note to a ticket
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket
    - `body` (string, required): Content of the note

- `update_ticket_conversation`: Update a conversation
  - **Inputs**:
    - `conversation_id` (number, required): ID of the conversation
    - `body` (string, required): Updated content

- `view_ticket_summary`: Get the summary of a ticket
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket

- `update_ticket_summary`: Update the summary of a ticket
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket
    - `body` (string, required): New summary content

- `delete_ticket_summary`: Delete the summary of a ticket
  - **Inputs**:
    - `ticket_id` (number, required): ID of the ticket

- `get_agents`: Get all agents
  - **Inputs**:
    - `page` (number, optional): Page number
    - `per_page` (number, optional): Number of agents per page

- `view_agent`: Get a single agent
  - **Inputs**:
    - `agent_id` (number, required): ID of the agent

- `create_agent`: Create a new agent
  - **Inputs**:
    - `agent_fields` (object, required): Agent details

- `update_agent`: Update an agent
  - **Inputs**:
    - `agent_id` (number, required): ID of the agent
    - `agent_fields` (object, required): Fields to update

- `search_agents`: Search for agents
  - **Inputs**:
    - `query` (string, required): Search query

- `list_contacts`: Get all contacts
  - **Inputs**:
    - `page` (number, optional): Page number
    - `per_page` (number, optional): Contacts per page

- `get_contact`: Get a single contact
  - **Inputs**:
    - `contact_id` (number, required): ID of the contact

- `search_contacts`: Search for contacts
  - **Inputs**:
    - `query` (string, required): Search query

- `update_contact`: Update a contact
  - **Inputs**:
    - `contact_id` (number, required): ID of the contact
    - `contact_fields` (object, required): Fields to update

- `list_companies`: Get all companies
  - **Inputs**:
    - `page` (number, optional): Page number
    - `per_page` (number, optional): Companies per page

- `view_company`: Get a single company
  - **Inputs**:
    - `company_id` (number, required): ID of the company

- `search_companies`: Search for companies
  - **Inputs**:
    - `query` (string, required): Search query

- `find_company_by_name`: Find a company by name
  - **Inputs**:
    - `name` (string, required): Company name

- `list_company_fields`: Get all company fields
  - **Inputs**:
    - None

## Getting Started

### Installing via Smithery

To install freshdesk_mcp for Claude Desktop automatically via [Smithery](https://smithery.ai/server/@effytech/freshdesk_mcp):

```bash
npx -y @smithery/cli install @effytech/freshdesk_mcp --client claude
```

### Prerequisites

- A Freshdesk account (sign up at [freshdesk.com](https://freshdesk.com))
- Freshdesk API key
- `uvx` installed (`pip install uv` or `brew install uv`)

### Configuration

1. Generate your Freshdesk API key from the Freshdesk admin panel
2. Set up your domain and authentication details

### Usage with Claude Desktop

1. Install Claude Desktop if you haven't already
2. Add the following configuration to your `claude_desktop_config.json`:

```json
"mcpServers": {
  "freshdesk-mcp": {
    "command": "uvx",
    "args": [
        "freshdesk-mcp"
    ],
    "env": {
      "FRESHDESK_API_KEY": "<YOUR_FRESHDESK_API_KEY>",
      "FRESHDESK_DOMAIN": "<YOUR_FRESHDESK_DOMAIN>"
    }
  }
}
```

**Important Notes**:
- Replace `YOUR_FRESHDESK_API_KEY` with your actual Freshdesk API key
- Replace `YOUR_FRESHDESK_DOMAIN` with your Freshdesk domain (e.g., `yourcompany.freshdesk.com`)

### Using the CoreBridge Freshdesk gateway (Entra sign-in)

Instead of a Freshdesk API key, the server can call the CoreBridge Freshdesk gateway as the signed-in
user (Microsoft Entra ID). It switches automatically:

| Condition | Mode | Calls |
|---|---|---|
| `FRESHDESK_API_KEY` is missing/blank, **or** `FRESHDESK_DOMAIN` is an Azure host (`*.azurewebsites.net`) | `entra` | `https://<gateway>/staff/fd/api/v2/...` with `Authorization: Bearer <Entra token>` |
| otherwise | `apikey` | `https://<domain>/api/v2/...` with the Freshdesk API key (unchanged) |

```json
"freshdesk-mcp": {
  "command": "uvx",
  "args": ["--from", "git+https://github.com/CoreBridge/freshdesk_mcp", "freshdesk-mcp"],
  "env": {
    "FRESHDESK_DOMAIN": "<gateway host, e.g. cus-cb-fd-gateway-xxxx.centralus-01.azurewebsites.net>",
    "FRESHDESK_GATEWAY_ENV": "prod"
  }
}
```

`FRESHDESK_GATEWAY_ENV` is sent as the gateway's `X-CB-Env` header. **Without it the gateway puts an Entra
caller in a cache-only, non-production environment**: live ticket lists/searches return a bare `404` and
writes are refused. Set it to `prod` (or `preview`) to read and write live Freshdesk data. It is deliberately
not defaulted.

Sign in once up front (a browser window opens; the token is cached encrypted on disk and refreshed silently):

```bash
uvx --from git+https://github.com/CoreBridge/freshdesk_mcp freshdesk-mcp login
```

Optional environment variables:

| Variable | Purpose | Default |
|---|---|---|
| `FRESHDESK_AUTH_MODE` | Force `entra` or `apikey` (`auto` = detect) | `auto` |
| `FRESHDESK_GATEWAY_ENV` | Gateway environment (`dev`, `qa`, `preview`, `prod`), sent as `X-CB-Env` | unset (gateway default: cache-only `dev`) |
| `FRESHDESK_ENTRA_TENANT_ID` | Entra tenant | CoreBridge tenant |
| `FRESHDESK_ENTRA_CLIENT_ID` | Public client app registration | "Freshdesk Gateway Client" |
| `FRESHDESK_ENTRA_SCOPE` | Delegated scope on the gateway API | `api://1e49e52c-b843-401e-9f97-8983655c5260/access_as_user` |
| `FRESHDESK_ENTRA_AUTH_RECORD` | Where the sign-in record (account id, no tokens) is kept | `~/.freshdesk-mcp/entra_auth_record.json` |
| `FRESHDESK_ENTRA_FLOW` | `interactive` (browser window) or `device_code` (URL + one-time code printed to stderr, for machines with no browser) | `interactive` |
| `FRESHDESK_ENTRA_ALLOW_UNENCRYPTED_CACHE` | `1` lets the token cache fall back to a plain-text file when no OS keyring is usable. Leave unset unless you accept that | unset (encrypted only) |

Linux: the encrypted token cache uses the Secret Service keyring (gnome-keyring/KWallet) through
PyGObject, which `uvx` does not install by itself. Add `--with PyGObject` to the `uvx` arguments, e.g.
`"args": ["--with", "PyGObject", "--from", "git+https://github.com/CoreBridge/freshdesk_mcp", "freshdesk-mcp"]`
(and the same for `freshdesk-mcp login`). Without it the first tool call reports how to fix the cache
instead of signing in.

Notes:
- Entra mode refuses to run against a `*.freshdesk.com` host or over plain `http` (except `localhost`), so a
  token is never sent to the wrong place. A misconfiguration is reported on the first tool call.
- The gateway denies ticket deletion, so `delete_ticket` returns an error in Entra mode.
- The client app must be able to use the API's `access_as_user` scope (pre-authorized or consented), and the
  persistent token cache needs Windows, macOS Keychain, or Linux libsecret.

### Windows / Cursor: one-shot installer

`install-corebridge-freshdesk-mcp.ps1` writes the `freshdesk-mcp` entry into `%USERPROFILE%\.cursor\mcp.json`
(other servers are kept and the file is backed up), installs `uv` if needed, and signs you in.

**Default: gateway mode, no Freshdesk API key.** `-GatewayUrl` is **required** (there is no built-in
default, so you always choose what you point Cursor at). It writes `FRESHDESK_GATEWAY_ENV=prod` unless you pass
`-GatewayEnv`, then runs `freshdesk-mcp login` so a browser window opens once for your CoreBridge Microsoft
account (the "Freshdesk Gateway Client" app). The token is cached with Windows DPAPI. Ask the support lead or
platform team for the deployed gateway URL; it is not published here.

```powershell
powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -GatewayUrl https://<gateway-host>
```

**Test vs prod.** One deployed gateway serves every environment: `-GatewayUrl` picks the gateway, `-GatewayEnv`
picks the data.

| Goal | `-GatewayUrl` | `-GatewayEnv` | What you get |
|---|---|---|---|
| Day-to-day support work | deployed gateway | `prod` (default) | LIVE Freshdesk: lists, searches and writes (replies, notes, updates) are real and customer-visible |
| Try it safely, demo, training | deployed gateway | `dev` (or `qa`) | TEST: cache-only copy of production ticket data; requests the cache cannot answer are refused (403/404) and every write is refused (`403 env_restricted`), so nothing reaches Freshdesk |
| Preview environment | deployed gateway | `preview` | also LIVE: preview serves real customers on the same Freshdesk account, so treat it like prod |
| Gateway development | `http://localhost:<port>` | `dev` | a gateway you run locally (plain http is allowed only for localhost) |

| Parameter | Purpose | Default |
|---|---|---|
| `-GatewayUrl` | **Required in gateway mode.** Gateway base URL (https, or http for localhost only; a `*.freshdesk.com` host is refused) | none |
| `-GatewayEnv` | `dev`, `qa`, `preview` or `prod` (sent as `X-CB-Env`) | `prod` |
| `-DeviceCode` | Sign in with a URL + one-time code instead of a browser window | off |
| `-ClientId` | Entra public client app | `b00e08ff-9e23-42f4-97b2-da02455ae39b` ("Freshdesk Gateway Client") |
| `-Ref` | Install a specific branch/tag/commit of this repo | default branch |
| `-SkipVerify` (`-SkipSignIn`) | Gateway: skip the sign-in now (Cursor prompts on first use). API key: skip the key check | off |
| `-ApiKeyMode` | Legacy direct mode: call Freshdesk with your personal API key (no `-GatewayUrl`) | off |
| `-ApiKey`, `-Domain` | API-key mode only: key (prompted if omitted) and Freshdesk host | `atomology.freshdesk.com` |

```powershell
# try it safely against test data, device-code sign-in
powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -GatewayUrl https://<gateway-host> -GatewayEnv dev -DeviceCode
# legacy direct mode
powershell -ExecutionPolicy Bypass -File .\install-corebridge-freshdesk-mcp.ps1 -ApiKeyMode -ApiKey "YOUR_KEY_HERE"
```

`Get-Help .\install-corebridge-freshdesk-mcp.ps1 -Full` shows the same guidance.

Then reload Cursor (Command Palette -> Developer: Reload Window). The installer's checks (parse,
PSScriptAnalyzer, Pester) run with `pwsh -NoProfile -File tests/installer/Invoke-InstallerChecks.ps1`.

## Example Operations

Once configured, you can ask Claude to perform operations like:

- "Create a new ticket with subject 'Payment Issue for customer A101' and description as 'Reaching out for a payment issue in the last month for customer A101', where customer email is a101@acme.com and set priority to high"
- "Update the status of ticket #12345 to 'Resolved'"
- "List all high-priority tickets assigned to the agent John Doe"
- "List previous tickets of customer A101 in last 30 days"


## Testing

For testing purposes, you can start the server manually:

```bash
uvx freshdesk-mcp --env FRESHDESK_API_KEY=<your_api_key> --env FRESHDESK_DOMAIN=<your_domain>
```

## Troubleshooting

- Verify your Freshdesk API key and domain are correct
- Ensure proper network connectivity to Freshdesk servers
- Check API rate limits and quotas
- Verify the `uvx` command is available in your PATH

## License

This MCP server is licensed under the MIT License. See the LICENSE file in the project repository for full details.

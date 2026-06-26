# Remote models

Ripple can use any service that speaks the OpenAI Chat Completions API as a planner. Remote models
are defined as named entries in `settings.json` and are available to every project that picks up
that config file.

---

## Defining a remote model

Remote model entries live in the `models` array in `settings.json` (see
[Configuration](../config/index.md) for file locations and merge order). Each entry is an
`OpenAIModelConfig` object:

```json
{
  "models": [
    {
      "name": "gpt4o",
      "baseURL": "https://api.openai.com/v1",
      "model": "gpt-4o",
      "apiKey": "${OPENAI_API_KEY}",
      "vision": true,
      "reasoning": false,
      "temperature": 0.7,
      "maxTokens": 4096,
      "topP": 0.9,
      "provider": "openai",
      "contextWindow": 128000
    }
  ]
}
```

### Field reference

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Identifier used with `--model` and the `/model` picker |
| `baseURL` | string | yes | API base URL (e.g. `https://api.openai.com/v1`) |
| `model` | string | yes | Model id passed to the API (e.g. `gpt-4o`) |
| `apiKey` | string | yes | API key; use `${VAR}` env-var expansion to avoid writing keys to disk |
| `provider` | string | no | `openai` (default), `azure`, `anthropic`, or `bedrock` |
| `vision` | bool | no | Whether to send image content to this model |
| `reasoning` | bool | no | Mark as a reasoning/o-series model (affects prompt construction) |
| `temperature` | float | no | Sampling temperature |
| `maxTokens` | int | no | Maximum tokens in the response |
| `topP` | float | no | Nucleus sampling parameter |
| `contextWindow` | int | no | Override the context window (see inference rules below) |
| `anthropicVersion` | string | no | `anthropic-version` header value (Anthropic provider) |
| `betaHeaders` | array | no | `anthropic-beta` header values (Anthropic provider) |
| `azureDeployment` | string | no | Azure deployment name (Azure provider) |
| `apiVersion` | string | no | Azure API version string, e.g. `2024-10-21` (Azure provider) |
| `region` | string | no | AWS region (Bedrock provider; see also env vars below) |

---

## Providers

### openai (default)

The standard OpenAI Chat Completions API. Works with OpenAI directly and with any compatible
third-party provider (Together, Groq, Fireworks, self-hosted vLLM, etc.) by changing `baseURL`.

```json
{
  "name": "gpt4o",
  "baseURL": "https://api.openai.com/v1",
  "model": "gpt-4o",
  "apiKey": "${OPENAI_API_KEY}",
  "provider": "openai"
}
```

### azure

Azure OpenAI Service. Requires `azureDeployment` (the deployment name in your Azure resource)
and `apiVersion`.

```json
{
  "name": "azure-gpt4o",
  "baseURL": "https://<your-resource>.openai.azure.com",
  "model": "gpt-4o",
  "apiKey": "${AZURE_OPENAI_KEY}",
  "provider": "azure",
  "azureDeployment": "my-gpt4o-deployment",
  "apiVersion": "2024-10-21"
}
```

### anthropic

Anthropic's API via its OpenAI-compatible proxy. Requires `anthropicVersion`
(the `anthropic-version` header). Add `betaHeaders` for any `anthropic-beta` features you want
to enable (e.g. extended thinking).

```json
{
  "name": "claude-sonnet",
  "baseURL": "https://api.anthropic.com/v1",
  "model": "claude-sonnet-4-5",
  "apiKey": "${ANTHROPIC_API_KEY}",
  "provider": "anthropic",
  "anthropicVersion": "2023-06-01",
  "betaHeaders": []
}
```

### bedrock

Amazon Bedrock. Credentials are read from the environment - not from `apiKey`. Leave `apiKey`
as an empty string or omit it. Region comes from the `region` field, then `AWS_REGION`, then
`AWS_DEFAULT_REGION`, falling back to `us-east-1`.

```json
{
  "name": "bedrock-claude",
  "baseURL": "https://bedrock-runtime.us-east-1.amazonaws.com",
  "model": "anthropic.claude-sonnet-4-5-v1:0",
  "apiKey": "",
  "provider": "bedrock",
  "region": "us-east-1"
}
```

Required environment variables:

| Variable | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `AWS_SESSION_TOKEN` | Session token (required for assumed-role credentials) |
| `AWS_REGION` / `AWS_DEFAULT_REGION` | Region fallback if not set in config |

---

## Env-var expansion

Any string value in a model entry can embed environment variables using `${VAR}` or
`${VAR:-default}` syntax:

```json
"apiKey": "${OPENAI_API_KEY}",
"baseURL": "${OPENAI_BASE_URL:-https://api.openai.com/v1}"
```

Expansion happens at config load time from the process environment. **Keys are never written back
to disk.** This means you can commit `settings.json` to version control without leaking secrets,
as long as you use env-var references for all sensitive values.

!!! warning
    If a referenced variable is not set and no `:-default` is provided, the value becomes an
    empty string. Ripple will fail at the first API call with an authentication error, not at
    startup.

---

## Context-window inference

If you do not set `contextWindow`, Ripple infers it from the model id:

| Pattern | Inferred window |
|---|---|
| Anthropic models with `1m` in the id | 1,048,576 tokens |
| Other Anthropic models | 200,000 tokens |
| OpenAI `gpt-4o`, `gpt-4.1`, `gpt-4-turbo` | 128,000 tokens |
| OpenAI `o1`, `o3`, `o4` series | 200,000 tokens |
| OpenAI `gpt-3.5` | 16,384 tokens |
| OpenAI `gpt-4` (exact) | 8,192 tokens |
| Anything else | 128,000 tokens |

Set `contextWindow` explicitly if you are using a model that does not match any of these
patterns, or if the inference is wrong for your deployment.

---

## The `/model` Remote tab

Type `/model` inside an interactive session and switch to the **Remote** tab. It loads
OpenRouter's free model catalog and lets you browse available models. Selecting one adds it to
your `settings.json` `models` array with appropriate defaults. You can also remove registered
remote models from this tab.

!!! tip
    The Remote tab requires a network connection to fetch the OpenRouter catalog. Your actual
    API calls still go to whichever `baseURL` you configure - OpenRouter is only used to
    populate the browser.

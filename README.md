# afm-server

A macOS menu bar application that bridges Apple Intelligence (on-device Foundation Models) with OpenAI and Ollama-compatible API endpoints. Run AI locally on your Mac without sending data to external servers.

Built by [Techopolis](https://techopolisonline.com).

## Features

- **Local HTTP Server**: Exposes Apple Intelligence through standard API endpoints
- **OpenAI API Compatible**: Drop-in replacement for OpenAI API clients
- **Ollama API Compatible**: Works with applications that support Ollama
- **Menu Bar Integration**: Start, stop, and configure the server from your menu bar
- **Streaming Support**: True token-by-token streaming via Server-Sent Events (SSE)
- **Session Management**: Multi-turn conversation context via cached `LanguageModelSession` instances (30-min TTL, up to 50 concurrent sessions)
- **Guardrail Recovery**: Automatic session eviction on safety violations prevents refusal spirals — a single bad message does not poison the entire conversation
- **Soft Refusal Detection**: Detects when the model returns a refusal as normal text (not an exception) and resets the session to keep follow-up messages working
- **Concurrency Control**: Configurable semaphore limits concurrent inference calls (default 3) with FIFO queuing for additional requests
- **Tool Calling**: OpenAI-compatible delegated tool calls for agent harnesses, plus server-local file and terminal tools for built-in/local requests
- **Auto-Updates**: Sparkle 2 checks for updates daily and shows a dock badge when one is available
- **Privacy First**: All processing happens on-device — no data leaves your Mac

## Requirements

- macOS 26.0 (Tahoe) or later
- Apple Silicon Mac (M1 or later)
- Apple Intelligence enabled on your device
- Xcode 26.0 or later (for building from source)

## Installation

### Download

Download the latest release from the [Releases page](https://github.com/Techopolis/afm-server/releases).

1. Download `afm-server-X.X.zip` from the latest release
2. Unzip and move `afm-server.app` to `/Applications`
3. Launch from Applications — the server starts automatically

The app is signed with Developer ID and notarized by Apple, so it will pass Gatekeeper without issues. Sparkle auto-updater checks for new versions daily and notifies you when an update is available.

### Building from Source

1. Clone the repository:

```bash
git clone https://github.com/Techopolis/afm-server.git
cd afm-server
```

2. Open the project in Xcode:

```bash
open "afm-server.xcodeproj"
```

3. Select your development team in the project settings under Signing and Capabilities.

4. Build and run the project (Cmd + R).

### Building from Command Line

```bash
xcodebuild -project "afm-server.xcodeproj" -scheme "afm-server" -configuration Debug build
```

The built app will be in `~/Library/Developer/Xcode/DerivedData/`.

## Getting Started

### Starting the Server

1. Launch afm-server. The app appears in your menu bar with a lightning bolt icon.
2. The server starts automatically on port 11435 when the app launches.
3. Click the menu bar icon to view server status and controls.
4. The status indicator is green when the server is running.
5. Use the controls to stop, restart, or change the port if needed.

### Testing the API

You can test the server using curl or any HTTP client:

```bash
# Health check
curl http://127.0.0.1:11435/debug/health

# Simple chat completion
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple.local",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Configuring Settings

Open Settings (Cmd + ,) to configure:

- **Include System Prompt**: Toggle whether to send a system instruction with each request
- **Enable Debug Logging**: Print requests and responses to the console
- **Include Conversation History**: Send full conversation context or just the latest message
- **System Prompt**: Customize the AI behavior with your own instructions

## Architecture

### Session Management

The server caches `LanguageModelSession` instances by session ID so multi-turn conversations maintain context across requests. Sessions expire after 30 minutes of inactivity. The cache holds a maximum of 50 sessions — when full, the oldest session is evicted.

Pass a `session_id` in your request to maintain conversation context:

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple.local",
    "messages": [{"role": "user", "content": "What did I just ask?"}],
    "session_id": "my-conversation-123"
  }'
```

### Guardrail Recovery

Apple's Foundation Models include built-in safety guardrails. When a guardrail fires (either as a thrown exception or a soft text refusal), the server:

1. Detects the refusal (handles both thrown `GuardrailViolation` errors and text-based refusals like "I can't assist with that")
2. Evicts the poisoned session from the cache
3. Creates a fresh session with the same instructions
4. Returns a friendly message to the user

This prevents the "refusal spiral" where one bad message causes every subsequent message in the conversation to be refused.

### Concurrency Control

The inference semaphore limits how many LLM calls run simultaneously (default: 3). Additional requests wait in a FIFO queue. This prevents memory pressure when multiple users or applications are hitting the server at once.

Check queue status via the health endpoint:

```bash
curl http://127.0.0.1:11435/debug/health
```

Returns:

```json
{
  "status": "ok",
  "running": true,
  "port": 11435,
  "inference": {
    "running": 0,
    "queued": 0,
    "max_concurrent": 3,
    "total_completed": 42,
    "total_queued": 5
  }
}
```

## API Reference

The server exposes OpenAI and Ollama-compatible endpoints at `http://127.0.0.1:11435` (or your configured port).

### OpenAI-Compatible Endpoints

#### Chat Completions

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple.local",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello, how are you?"}
    ]
  }'
```

#### Chat Completions with Streaming

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple.local",
    "messages": [
      {"role": "user", "content": "Write a short poem about coding"}
    ],
    "stream": true
  }'
```

#### Text Completions

```bash
curl http://127.0.0.1:11435/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple.local",
    "prompt": "The quick brown fox"
  }'
```

#### List Models

```bash
curl http://127.0.0.1:11435/v1/models
```

#### Get Model Details

```bash
curl http://127.0.0.1:11435/v1/models/apple.local
```

### Ollama-Compatible Endpoints

#### Chat

```bash
curl http://127.0.0.1:11435/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple.local",
    "messages": [
      {"role": "user", "content": "Hello!"}
    ]
  }'
```

#### Generate

```bash
curl http://127.0.0.1:11435/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple.local",
    "prompt": "Explain quantum computing in simple terms"
  }'
```

#### List Tags (Models)

```bash
curl http://127.0.0.1:11435/api/tags
```

#### Version

```bash
curl http://127.0.0.1:11435/api/version
```

### Debug Endpoints

#### Health Check

```bash
curl http://127.0.0.1:11435/debug/health
```

#### Echo (for debugging requests)

```bash
curl -X POST http://127.0.0.1:11435/debug/echo \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}'
```

## Using with Third-Party Applications

### Xcode 26 Intelligence Mode

Xcode 26 introduces Intelligence Mode, an AI-powered assistant with Agent Mode that provides context-aware code suggestions. You can configure Xcode to use afm-server as a locally hosted model provider since it implements the Ollama-compatible API that Xcode expects.

#### Setup Instructions

1. Launch afm-server and ensure the server is running (green status indicator in menu bar).

2. Open Xcode 26 and go to **Xcode > Settings** (or press Cmd + ,).

3. Navigate to the **Intelligence Mode** tab.

4. Click **Add a Model Provider** and select **Locally Hosted**.

5. Enter the following configuration:

| Setting | Value |
|---------|-------|
| Port | 11435 (or your configured port) |
| Description | afm-server |

6. Click **Add** to save the configuration.

7. If successful, you should see **apple.local:latest** appear in the list of available models.

8. Select **apple.local:latest** as your active model.

**Important**: If you have Ollama running on port 11434, there is no conflict since afm-server defaults to port 11435. If you changed the port, make sure it matches your Xcode configuration.

#### Using Intelligence Mode

Once configured, you can access Intelligence Mode in Xcode:

- Press **Cmd + 0** to open the Coding Assistant panel
- Use Agent Mode to get context-aware suggestions based on your project
- The AI can assist with code generation, refactoring, and explanations

#### Benefits of Using afm-server with Xcode

- **Privacy**: All processing happens on-device using Apple Intelligence
- **No API Costs**: Unlike cloud-hosted models, there are no usage fees
- **No Internet Required**: Works completely offline after initial setup
- **Native Integration**: Leverages Apple's optimized on-device Foundation Models

#### Troubleshooting Xcode Integration

If the model does not appear in Xcode:

1. Verify afm-server is running (check the menu bar icon)
2. Confirm the port number matches your server configuration (default is 11435)
3. Make sure no other service is using the same port
4. Restart Xcode after adding the model provider
5. Check that Apple Intelligence is enabled on your Mac in System Settings

You can verify the server is working by running this command in Terminal:

```bash
curl http://127.0.0.1:11435/api/tags
```

You should see a response containing `apple.local:latest` in the models list.

#### Alternative: Cloud-Hosted Models in Xcode 26

For comparison, you can also configure cloud-hosted models in Xcode 26 Intelligence Mode using the **Internet Hosted** option:

**Anthropic Claude** (recommended for code):

| Setting | Value |
|---------|-------|
| URL | `https://api.anthropic.com/v1/messages` |
| API Key | Your Anthropic API key |
| API Key Header | `x-api-key` |
| Description | Anthropic |

**OpenAI**:

| Setting | Value |
|---------|-------|
| URL | `https://api.openai.com` |
| API Key | Your OpenAI API key |
| API Key Header | `x-api-key` |
| Description | OpenAI |

**OpenRouter** (middleware aggregator for multiple models):

Visit [OpenRouter.ai](https://openrouter.ai) to get an API key that provides access to models from Anthropic, OpenAI, Google, and others through a single endpoint.

However, afm-server offers the advantage of completely local, private AI assistance without cloud API keys or usage costs. The local server still uses a user-configurable API key to protect its loopback endpoints.

### Cursor IDE

Configure Cursor to use the local server:

1. Open Cursor Settings
2. Navigate to AI settings
3. Set the API base URL to `http://127.0.0.1:11435/v1`
4. Use `apple.local` as the model name

### Continue.dev

Add to your Continue configuration:

```json
{
  "models": [
    {
      "title": "Apple Intelligence (afm-server)",
      "provider": "openai",
      "model": "apple.local",
      "apiBase": "http://127.0.0.1:11435/v1"
    }
  ]
}
```

### Other OpenAI-Compatible Clients

Any application that supports custom OpenAI API endpoints can use afm-server:

- Set the API base URL to `http://127.0.0.1:11435/v1`
- Use `apple.local` as the model name
- Set the client API key to the value shown in afm-server Settings or the dashboard API Key card
- afm-server accepts that key as `Authorization: Bearer <API key>`

## Tool Calling

afm-server supports two tool paths:

### Client-Delegated Tools

When an OpenAI-compatible client sends a `tools` array to `POST /v1/chat/completions`, afm-server behaves like a model backend. It can return an assistant message with `tool_calls` and `finish_reason: "tool_calls"`. The connecting client, such as Pi, Hermes, OpenClaw, or another coding harness, is responsible for executing those tools on the client machine and sending the results back as `role: "tool"` messages.

This is the correct path for agentic coding work because the harness owns the workspace, terminal, approvals, and tool registry.

Streaming requests also emit OpenAI-style `delta.tool_calls` chunks so clients that keep `stream: true` can still see tool calls.

### Server-Local Tools

When no client tools are provided, afm-server can use Apple Foundation Models native Swift tools for local file and terminal requests. These tools run inside the afm-server process on the Mac hosting the server:

- `bash`: Execute a short shell command on the server Mac
- `read_file`: Read file contents on the server Mac
- `write_file`: Create or write content to a file on the server Mac
- `edit_file`: Modify a file by replacing text on the server Mac
- `delete_file`: Remove a file on the server Mac
- `move_file`: Move or rename a file on the server Mac
- `list_directory`: List directory contents on the server Mac
- `create_directory`: Create new directories on the server Mac
- `check_path`: Check if a path exists and get its type on the server Mac

### Workspace Configuration

Set the `PI_WORKSPACE_ROOT` environment variable to specify the root directory for server-local file operations. If not set, it defaults to your Documents folder.

```bash
export PI_WORKSPACE_ROOT=/path/to/your/workspace
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PI_WORKSPACE_ROOT` | Root directory for tool file operations | `~/Documents` |
| `PI_DEBUG_FULL_LOG` | Set to `1` to enable full request body logging | Disabled |

## Source Files

| File | Description |
|------|-------------|
| `FoundationModelsService.swift` | Core AI service — bridges OpenAI requests to Apple Foundation Models, manages sessions, handles guardrails |
| `LocalHTTPServer.swift` | HTTP server with OpenAI and Ollama-compatible routes, SSE streaming |
| `ServerApp.swift` | Server controller — start, stop, port management |
| `FileTools.swift` | File system tool implementations for tool calling |
| `ChatView.swift` | Built-in chat interface |
| `ChatCommands.swift` | macOS menu commands |
| `MenuBarContentView.swift` | Menu bar popover UI |
| `ServerDashboardView.swift` | Server status dashboard |
| `SettingsView.swift` | App settings UI |
| `ContentView.swift` | Main content view |

## Troubleshooting

### Server will not start

- Ensure you are running macOS 26.0 (Tahoe) or later on Apple Silicon
- Check that Apple Intelligence is enabled in System Settings
- Verify the port is not already in use by another application

### Model not available

If you see "Model not ready" errors:

1. Open System Settings
2. Navigate to Apple Intelligence and Siri
3. Ensure Apple Intelligence is enabled and fully downloaded

### Empty or fallback responses

The server returns a fallback response when:

- Apple Intelligence is not available on your device
- The on-device model is still downloading
- Safety guardrails block the request (the session is automatically reset for next message)

Check the console logs (enable Debug Logging in Settings) for more details.

### Refusal spiral

If every message in a conversation gets refused after a single guardrail hit, the session eviction may not be working. Check the server logs for `[fm-stream] Soft refusal detected` or `[fm-stream] Guardrail violation` messages. Restarting the server clears all cached sessions.

### Port conflicts

afm-server defaults to port 11435. If you need to use a different port, change it in the menu bar controls before starting the server.

## Contributing

Contributions are welcome. Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is proprietary software owned by Techopolis. All rights reserved.

## Acknowledgments

- Apple for Foundation Models and on-device AI capabilities
- The OpenAI API specification that enables broad compatibility
- The Ollama project for their API design inspiration

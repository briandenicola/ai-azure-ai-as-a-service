# User Proxy Agent Pattern

## Overview

The User Proxy Agent is a conversation management layer that sits between end users and the orchestrator system, providing enhanced user experience through intelligent clarification, context management, and response formatting.

## Architecture

```
┌──────────────┐
│     User     │
└──────┬───────┘
       │
       ↓
┌──────────────────────────────────────┐
│      User Proxy Agent                │
│  • Clarification requests            │
│  • Context management                │
│  • Response formatting               │
│  • Command handling                  │
└──────┬───────────────────────────────┘
       │
       ↓
┌──────────────────────────────────────┐
│       Orchestrator                   │
│  • Keyword-based routing             │
│  • LLM-powered routing               │
│  • Rule-based routing                │
└──────┬───────────────────────────────┘
       │
       ↓
┌──────────────────────────────────────┐
│    Specialized Agents                │
│  • GitHub Agent                      │
│  • Math Agent                        │
│  • (Future agents...)                │
└──────┬───────────────────────────────┘
       │
       ↓
┌──────────────────────────────────────┐
│         Tools & APIs                 │
│  • GitHub API                        │
│  • Math operations                   │
│  • (Future integrations...)          │
└──────────────────────────────────────┘
```

## Key Benefits

### 1. **Intelligent Clarification**
The proxy detects when user input is ambiguous and asks for clarification:

```python
User: "Show me the files"
Proxy: 🤔 Clarification Needed
       Which repository would you like to work with?
       
       Examples:
         • Provide a repo name (e.g., 'drewelewis/ContosoBankAPI')
         • Set a default repo for this session
         • Use the default suggested repo
       
       💡 Suggestion: drewelewis/ContosoBankAPI
```

### 2. **Context Management**
Remembers user preferences across conversations:

```python
# Set preference
proxy.set_user_preference('default_repo', 'drewelewis/ContosoBankAPI')

# Future queries automatically use this context
User: "list files"
Proxy: [Uses default_repo automatically]
```

### 3. **Response Formatting**
Consistently formats agent responses with agent info and suggestions:

```python
🤖 Routed to: GitHub Agent

[Agent response here...]

💡 What's next?
  1. Ask to view content of a specific file
  2. Request to create an issue
  3. Type 'list agents' to see available specialists
```

### 4. **Command Handling**
Built-in commands for user convenience:

```python
help          - Show available commands
status        - Show current session status
list agents   - List all specialized agents
clear         - Clear conversation history
set key=value - Set user preference
debug         - Toggle debug mode (see delegation flow)
stats         - Show delegation statistics
```

### 5. **Session Persistence**
In API mode, maintains separate sessions for different users:

```json
POST /agent_chat
{
  "session_id": "user-123",
  "message": "Show repos"
}
```

## Usage Examples

### CLI Usage

```bash
# Basic usage with keyword orchestrator
python chat_with_proxy.py

# The proxy handles everything:
You: help
🤖 Assistant: [Shows help text with commands]

You: set default_repo=microsoft/vscode
🤖 Assistant: ✅ Preference set: default_repo = microsoft/vscode

You: list files
🤖 Assistant: 🤖 Routed to: GitHub Agent
             [Shows files from microsoft/vscode]
             
             💡 What's next?
               1. Ask to view content of a specific file
               2. Request to create an issue

You: what's 25 * 4?
🤖 Assistant: 🤖 Routed to: Math Agent
             The result of 25 * 4 is 100
```

### Programmatic Usage

```python
from agents.user_proxy_agent import create_user_proxy_with_orchestrator

# Create proxy with keyword orchestrator
proxy = await create_user_proxy_with_orchestrator('keyword')

# Process messages
response = await proxy.process_message("list repos for microsoft")
print(response)

# Set preferences
proxy.set_user_preference('default_repo', 'microsoft/vscode')

# Check status
status = proxy.get_status()
print(status)
```

### API Usage

```bash
# Start API with proxy
python -m uvicorn api.main_with_proxy:app --host 0.0.0.0 --port 8989

# Use in API calls
curl -X POST "http://localhost:8989/agent_chat" \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "user-123",
    "message": "list repos for microsoft"
  }'

# Set preference via API
curl -X POST "http://localhost:8989/set_preference" \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "user-123",
    "key": "default_repo",
    "value": "microsoft/vscode"
  }'

# Get session status
curl "http://localhost:8989/session_status/user-123"
```

## Implementation Details

### Core Components

#### 1. UserProxyAgent Class
Loc ated in `agents/user_proxy_agent.py`:

```python
class UserProxyAgent:
    def __init__(self, orchestrator):
        self.orchestrator = orchestrator
        self.user_context = {}           # User preferences
        self.conversation_history = []   # Message history
        
    async def process_message(self, user_input: str, stream: bool = False):
        """Main message processing with clarification and formatting"""
        
    def _needs_clarification(self, user_input: str) -> Optional[Dict]:
        """Detect ambiguous input requiring clarification"""
        
    def _format_response(self, response: str, agent_info: str, original: str) -> str:
        """Format agent responses with suggestions"""
        
    def handle_command(self, command: str) -> Optional[str]:
        """Handle special commands (help, status, clear)"""
```

#### 2. Clarification Detection
The proxy detects several types of ambiguity:

- **Ambiguous references**: "it", "that", "this" without context
- **Missing parameters**: Repository operations without repo name
- **Vague requests**: Generic "help", "show me", etc.

#### 3. Context Application
Automatically applies user preferences to queries:

```python
def _preprocess_input(self, user_input: str) -> str:
    """Apply context to user input"""
    if self.user_context.get('default_repo'):
        if 'github' in user_input.lower():
            # Enhance query with default repo
            return f"{user_input} (using repository: {default_repo})"
    return user_input
```

#### 4. Response Enhancement
Adds helpful suggestions based on agent and response:

```python
def _get_follow_up_suggestions(self, response: str, agent_info: str) -> str:
    """Generate contextual follow-up suggestions"""
    # Analyze response and current agent
    # Return relevant next steps
```

## Configuration

### Environment Variables

```bash
# Required for agents
AZURE_PROJECT_ENDPOINT=https://your-project.cognitiveservices.azure.com
MODEL_DEPLOYMENT_NAME=gpt-4

# Optional for API
ORCHESTRATOR_TYPE=keyword  # keyword, llm, or rule
SERVICE_NAME=ai-agent-starter
SERVICE_VERSION=2.0.0
```

### Orchestrator Selection

The proxy supports three orchestrator types:

```python
# Keyword-based (fast, simple)
proxy = await create_user_proxy_with_orchestrator('keyword')

# LLM-powered (intelligent, context-aware)
proxy = await create_user_proxy_with_orchestrator('llm')

# Rule-based (business logic)
proxy = await create_user_proxy_with_orchestrator('rule')
```

## API Endpoints

### With User Proxy (`api/main_with_proxy.py`)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/agent_chat` | POST | Send message (with clarification & formatting) |
| `/session_status/{id}` | GET | Get session context and preferences |
| `/set_preference` | POST | Set user preference for session |
| `/execute_command` | POST | Execute proxy command |
| `/clear_chat_history` | POST | Clear conversation history |
| `/clear_session/{id}` | POST | Remove session completely |
| `/agent_status` | GET | Get global agent capabilities |

### Request Examples

**Chat with context:**
```json
POST /agent_chat
{
  "session_id": "user-123",
  "message": "list files in my repo",
  "stream": false
}
```

**Set preference:**
```json
POST /set_preference
{
  "session_id": "user-123",
  "key": "default_repo",
  "value": "microsoft/vscode"
}
```

**Execute command:**
```json
POST /execute_command
{
  "session_id": "user-123",
  "command": "status"
}
```

## Comparison: With vs Without Proxy

### Without Proxy (Original)
```
User → Orchestrator → Agent → Response
```
- Simple, direct routing
- No clarification handling
- No context persistence
- Basic response formatting

### With Proxy (Enhanced)
```
User → Proxy → Orchestrator → Agent → Proxy → Enhanced Response
```
- Intelligent clarification
- Session-aware context
- User preference tracking
- Response enhancement
- Command handling
- Follow-up suggestions

**IMPORTANT:** The proxy delegates all domain work to agents. It should NOT execute tools or make API calls directly.

## Delegation Flow & Separation of Concerns

### Clear Responsibilities

**User Proxy (Conversation Manager):**
- ✅ Handles: Commands (help, status, clear, set)
- ✅ Handles: Clarification requests
- ✅ Handles: Response formatting
- ✅ Handles: Context management
- ❌ NEVER: Domain work (GitHub API, calculations, etc.)

**Orchestrator (Router):**
- ✅ Routes queries to appropriate agent
- ❌ NEVER: Executes tools directly

**Specialized Agents (Domain Experts):**
- ✅ Have tools attached
- ✅ Execute domain-specific work
- ✅ Make API calls, perform calculations

### Debug Mode

Enable debug mode to see the delegation flow:

```python
# Create with debug enabled
proxy = await create_user_proxy_with_orchestrator('keyword', debug=True)

# Or toggle in CLI
You: debug
✅ Debug mode: ON

You: what is 25 + 17?
[DEBUG] User Proxy: Delegating to orchestrator → specialized agent
[DEBUG] Orchestrator routed to: Math Agent
```

### Delegation Statistics

Monitor delegation health:

```python
You: stats

📊 Delegation Statistics
Total Interactions: 10
  • Proxy Handled (commands): 3 (30%)
  • Delegated to Agents: 6 (60%)      ← Healthy!
  • Clarifications: 1 (10%)

💡 The proxy should primarily delegate to agents for domain work!
```

**Healthy System:** 60%+ queries delegated to agents  
**Unhealthy System:** Proxy handling majority of queries

### Verification Test

Run the delegation test:

```bash
python test_delegation.py
```

This verifies:
- Commands are handled by proxy
- Domain queries are delegated to agents
- Proper separation of concerns
- Delegation statistics

**See:** [Delegation Flow Documentation](DELEGATION_FLOW.md) for detailed information.

## Best Practices

### 1. Session Management
- Use consistent session IDs for each user
- Clear sessions when users log out
- Monitor active session count

### 2. Preference Setting
- Set default repository early in conversation
- Use preferences for frequently-used values
- Clear context when switching users

### 3. Error Handling
- The proxy gracefully handles orchestrator errors
- Returns user-friendly error messages
- Maintains conversation state on errors

### 4. Streaming Responses
- Use `stream=true` for better UX in real-time apps
- Proxy enhances streaming with suggestions at end

## Extension Points

### Adding Custom Clarification Logic

```python
class CustomUserProxyAgent(UserProxyAgent):
    def _needs_clarification(self, user_input: str) -> Optional[Dict]:
        # Add your custom clarification detection
        if self._is_my_special_case(user_input):
            return {
                "type": "custom",
                "message": "Your custom clarification message"
            }
        return super()._needs_clarification(user_input)
```

### Adding Custom Commands

```python
def handle_command(self, command: str) -> Optional[str]:
    # Handle custom commands
    if command.startswith('mycommand'):
        return self._handle_my_command(command)
    return super().handle_command(command)
```

### Adding Custom Response Formatting

```python
def _format_response(self, response: str, agent_info: str, original: str) -> str:
    # Add custom formatting
    formatted = super()._format_response(response, agent_info, original)
    return self._add_custom_branding(formatted)
```

## Testing

### Unit Tests
```python
import pytest
from agents.user_proxy_agent import UserProxyAgent

@pytest.mark.asyncio
async def test_clarification_detection():
    # Test that vague input triggers clarification
    proxy = await create_proxy()
    result = proxy._needs_clarification("show me that")
    assert result is not None
    assert result['type'] == 'ambiguous_reference'
```

### Integration Tests
```python
@pytest.mark.asyncio
async def test_full_conversation_flow():
    from agents.user_proxy_agent import create_user_proxy_with_orchestrator
    proxy = await create_user_proxy_with_orchestrator('keyword')
    
    # Set preference
    proxy.set_user_preference('default_repo', 'test/repo')
    
    # Process message
    response = await proxy.process_message("list files")
    
    # Verify context applied
    assert 'test/repo' in response
```

## Troubleshooting

### Issue: Proxy not detecting ambiguity
**Solution:** Enhance `_needs_clarification()` with more patterns

### Issue: Context not being applied
**Solution:** Check `_preprocess_input()` logic and user_context state

### Issue: Sessions not persisting in API
**Solution:** Verify session_id is consistent across requests

## Future Enhancements

- [ ] Multi-agent workflow coordination
- [ ] Cross-agent context sharing
- [ ] Advanced preference management
- [ ] Conversation analytics
- [ ] A/B testing for routing strategies
- [ ] User intent prediction
- [ ] Proactive suggestions

## Related Files

- `agents/user_proxy_agent.py` - Core proxy implementation
- `chat_with_proxy.py` - CLI interface with proxy
- `api/main_with_proxy.py` - API with proxy pattern
- `orchestrators/keyword_orchestrator.py` - Keyword routing
- `orchestrators/llm_orchestrator.py` - LLM routing
- `orchestrators/rule_based_orchestrator.py` - Rule routing

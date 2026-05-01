# Delegation Flow & Separation of Concerns

## Quick Reference: Who Does What?

### ✅ User Proxy Agent (Conversation Manager)
**Role:** Manages conversation, NOT domain work

**Handles:**
- 📋 **Commands:** help, status, clear, set preferences
- 🤔 **Clarification:** Detecting ambiguous queries and asking for details
- 🎨 **Formatting:** Adding agent info and follow-up suggestions to responses
- 💾 **Context:** Managing user preferences and conversation history
- 🔀 **Routing:** Delegates to orchestrator (doesn't route itself)

**NEVER Does:**
- ❌ GitHub API calls
- ❌ Math calculations
- ❌ Tool execution
- ❌ Domain-specific work

---

### 🎯 Orchestrator (Router)
**Role:** Routes queries to appropriate specialized agent

**Handles:**
- 🔍 Analyzing query to determine intent
- 🚦 Routing to GitHub Agent, Math Agent, etc.
- 🔄 Managing agent instances and threads

**NEVER Does:**
- ❌ Direct tool calls
- ❌ Domain operations
- ❌ User commands (help, status, etc.)

---

### 🔧 Specialized Agents (Domain Experts)
**Role:** Execute domain-specific work using tools

**Examples:**
- **GitHub Agent:** Has tools (`get_repos_by_user`, `get_files_by_repo`, `create_github_issue`)
- **Math Agent:** Has tools (`add`, `subtract`, `multiply`, `evaluate_expression`)

**Handles:**
- ✅ Domain-specific queries
- ✅ Tool execution (API calls, calculations)
- ✅ Result generation

---

## Delegation Flow Diagram

```
User Input: "show repos for microsoft"
     │
     ├─▶ Is it a command? (help, status, etc.)
     │   └─▶ YES → User Proxy handles ✅
     │
     └─▶ NO → User Proxy delegates
             │
             ├─▶ Orchestrator analyzes query
             │   └─▶ Routes to GitHub Agent
             │
             └─▶ GitHub Agent
                 ├─▶ Calls get_repos_by_user() tool
                 ├─▶ Makes GitHub API request
                 └─▶ Returns results
                     │
                     └─▶ User Proxy formats response ✅
```

---

## Debug Mode: Seeing the Flow

Enable debug mode to see exactly what's happening:

```bash
python chat_with_proxy.py
# Choose orchestrator: 1
# Enable debug? y
```

### Example Debug Output

```
You: help
[DEBUG] User Proxy: Handling 'help' command (not delegating)
🤖 Assistant: [Help text...]

You: what is 25 + 17?
[DEBUG] User Proxy: Delegating to orchestrator → specialized agent
[DEBUG] Orchestrator routed to: Math Agent
🤖 Assistant: 🤖 Routed to: Math Agent
              The result is 42
```

---

## Statistics Command

Check delegation stats to ensure proper separation:

```
You: stats

📊 Delegation Statistics

Total Interactions: 10
  • Proxy Handled (commands): 3
  • Delegated to Agents: 6
  • Clarifications Requested: 1

Delegation Ratio: 6/10 queries sent to specialized agents

💡 The proxy should primarily delegate to agents for domain work!
```

**Good Ratio:** Most queries should be delegated (60%+)  
**Bad Ratio:** Proxy handling most queries means it's doing too much

---

## Test Script

Run the delegation test to verify proper flow:

```bash
python test_delegation.py
```

This will:
1. Run test cases with debug mode ON
2. Show which queries are handled vs delegated
3. Display delegation statistics
4. Verify separation of concerns

---

## Code Examples

### ✅ CORRECT: User Proxy delegates

```python
async def process_message(self, user_input: str):
    """User Proxy delegates to orchestrator"""
    
    # Check for meta-commands only
    if user_input == "help":
        return self._get_help_text()  # Proxy handles
    
    # Everything else → delegate
    response, agent_info = await self.orchestrator.route_query(user_input)
    return self._format_response(response, agent_info)
```

### ❌ WRONG: User Proxy doing domain work

```python
# DON'T DO THIS!
async def process_message(self, user_input: str):
    if "github" in user_input:
        # ❌ Proxy should NOT call tools directly!
        repos = await get_repos_by_user("microsoft")
        return repos
```

### ✅ CORRECT: Agent has tools

```python
# In github_agent.py
agent = client.create_agent(
    name="GitHubAgent",
    instructions="GitHub expert...",
    tools=[
        get_repos_by_user,      # ✅ Agent has tools
        get_files_by_repo,
        get_file_content,
        create_github_issue
    ]
)
```

---

## Verification Checklist

Use this to verify proper delegation:

- [ ] User Proxy has NO tools attached
- [ ] User Proxy ONLY handles commands (help, status, clear, set)
- [ ] User Proxy delegates all domain queries to orchestrator
- [ ] Orchestrator routes to specialized agents
- [ ] Specialized agents have tools attached
- [ ] Debug mode shows "Delegating to orchestrator" for domain queries
- [ ] Stats show 60%+ delegation ratio
- [ ] Test script passes all delegation tests

---

## Common Mistakes to Avoid

### ❌ Mistake 1: Proxy intercepting domain queries

```python
# WRONG
def handle_command(self, command: str):
    if "calculate" in command:  # ❌ domain query, not a command!
        return self._do_math(command)
```

**Fix:** Only intercept exact commands like "help", "status"

### ❌ Mistake 2: Proxy calling tools directly

```python
# WRONG
async def process_message(self, user_input: str):
    if "repos" in user_input:
        return await get_repos_by_user("user")  # ❌ Proxy using tools!
```

**Fix:** Always delegate to orchestrator → agent

### ❌ Mistake 3: Too much preprocessing

```python
# WRONG
def _preprocess_input(self, user_input: str):
    # ❌ Proxy analyzing and transforming domain queries
    if "error" in user_input:
        return f"search elasticsearch for {self._extract_error(user_input)}"
```

**Fix:** Keep preprocessing minimal (context only)

---

## Architecture Principles

1. **User Proxy = Conversation Manager**
   - Manages flow, context, formatting
   - Thin layer, no domain logic

2. **Orchestrator = Router**
   - Makes routing decisions only
   - No tool execution

3. **Specialized Agents = Domain Experts**
   - Have tools attached
   - Execute all domain work

4. **Clear Boundaries**
   - Each layer has distinct responsibility
   - No overlap in concerns

---

## Monitoring Delegation Health

### Healthy System
```
📊 Delegation Statistics
Total Interactions: 20
  • Proxy Handled: 4 (20%)    ← Commands only
  • Delegated: 15 (75%)       ← Domain work
  • Clarifications: 1 (5%)    ← UX flow
```

### Unhealthy System
```
📊 Delegation Statistics
Total Interactions: 20
  • Proxy Handled: 15 (75%)   ← ⚠️ Too much!
  • Delegated: 4 (20%)        ← ⚠️ Too little!
  • Clarifications: 1 (5%)
```

If proxy is handling most interactions, it's doing too much domain work!

---

## Related Files

- `agents/user_proxy_agent.py` - Proxy implementation
- `orchestrators/keyword_orchestrator.py` - Router implementation
- `agents/github_agent.py` - Example specialized agent with tools
- `test_delegation.py` - Test script to verify delegation
- `chat_with_proxy.py` - CLI with debug mode

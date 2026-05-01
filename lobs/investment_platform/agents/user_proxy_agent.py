"""
User Proxy Agent - Conversation Manager
Acts as an intermediary between end users and the orchestrator system

ARCHITECTURE:
User Input → User Proxy Agent → Orchestrator → Specialized Agents → Tools
                   ↑                                                    ↓
                   └──────────── Response Formatting ──────────────────┘

RESPONSIBILITIES:
1. User Conversation Management
   - Handle multi-turn conversations
   - Ask clarifying questions when needed
   - Remember user context and preferences
   
2. Input Preprocessing
   - Validate user input
   - Extract intent and parameters
   - Handle ambiguous queries
   
3. Orchestrator Coordination
   - Delegate to appropriate orchestrator
   - Handle orchestrator responses
   - Manage agent switching
   
4. Response Post-processing
   - Format responses consistently
   - Add helpful context and suggestions
   - Translate technical errors to user-friendly messages
   
5. Session Management
   - Track user preferences (default repo, settings)
   - Maintain conversation history
   - Handle authentication/authorization context

BENEFITS:
- Clean separation of concerns (UI vs routing vs execution)
- Enables rich multi-turn conversations
- Consistent user experience across interfaces
- Easier to add new interfaces (CLI, API, bot)
- Centralized user context management
"""

import re
from typing import Optional, Dict, Any, Tuple, AsyncGenerator
from datetime import datetime


class UserProxyAgent:
    """
    User Proxy Agent that manages user conversations and coordinates with orchestrators.
    
    This agent sits between the user and the orchestration layer, providing:
    - Intelligent conversation management
    - Clarification requests when needed
    - User context and preference tracking
    - Response formatting and enhancement
    - Multi-agent workflow coordination
    """
    
    def __init__(self, orchestrator, debug=False):
        """
        Initialize the User Proxy Agent
        
        Args:
            orchestrator: The orchestrator instance to delegate to
            debug: Enable debug logging to show delegation flow
        """
        self.orchestrator = orchestrator
        self.user_context = {}
        self.conversation_history = []
        self.waiting_for_clarification = False
        self.clarification_context = {}
        self.debug = debug
        self.delegation_stats = {
            'proxy_handled': 0,      # Commands handled by proxy
            'agent_delegated': 0,    # Queries delegated to agents
            'clarifications': 0      # Clarification requests
        }
        
    async def initialize(self):
        """Initialize the proxy and its orchestrator"""
        await self.orchestrator.initialize()
        
    async def process_message(self, user_input: str, stream: bool = False):
        """
        Main entry point for processing user messages
        
        Args:
            user_input: The user's message
            stream: Whether to return streaming response
            
        Returns:
            If stream=False: Formatted response string
            If stream=True: Async generator yielding response chunks
        """
        # Add to conversation history
        self._add_to_history("user", user_input)
        
        # Handle clarification responses
        if self.waiting_for_clarification:
            return await self._handle_clarification_response(user_input, stream)
        
        # Check if we need clarification
        clarification = self._needs_clarification(user_input)
        if clarification:
            if self.debug:
                print("[DEBUG] User Proxy: Requesting clarification (not delegating to agent)")
            self.waiting_for_clarification = True
            self.delegation_stats['clarifications'] += 1
            response = self._format_clarification_request(clarification)
            self._add_to_history("assistant", response)
            
            if stream:
                async def clarification_generator():
                    yield response
                return clarification_generator()
            return response
        
        # Preprocess input (expand context, apply preferences)
        processed_input = self._preprocess_input(user_input)
        
        if self.debug:
            print(f"[DEBUG] User Proxy: Delegating to orchestrator → specialized agent")
            if processed_input != user_input:
                print(f"[DEBUG] Context applied: '{user_input}' → '{processed_input}'")
        
        # Delegate to orchestrator → specialized agent
        self.delegation_stats['agent_delegated'] += 1
        
        if stream:
            return self._stream_with_formatting(processed_input)
        else:
            response, agent_info = await self.orchestrator.route_query(processed_input, stream=False)
            if self.debug and agent_info:
                print(f"[DEBUG] Orchestrator routed to: {agent_info}")
            formatted = self._format_response(response, agent_info, user_input)
            self._add_to_history("assistant", formatted)
            return formatted
    
    async def _stream_with_formatting(self, processed_input: str) -> AsyncGenerator[str, None]:
        """Stream response with formatting applied"""
        # Note: Current agent implementation doesn't support streaming,
        # so we get the full response and yield it in chunks
        response, agent_info = await self.orchestrator.route_query(processed_input, stream=False)
        
        if self.debug and agent_info:
            print(f"[DEBUG] Orchestrator routed to: {agent_info}")
        
        # Yield the response (could chunk it here if needed)
        yield response
        
        # Add suggestions at the end
        suggestions = self._get_follow_up_suggestions(response, agent_info)
        if suggestions:
            yield f"\n\n{suggestions}"
        
        # Add to history
        self._add_to_history("assistant", response)
    
    def _needs_clarification(self, user_input: str) -> Optional[Dict[str, Any]]:
        """
        Determine if user input needs clarification
        
        Returns:
            Dictionary with clarification details, or None
        """
        user_lower = user_input.lower()
        
        # Ambiguous pronouns without context
        if re.search(r'\b(it|that|this|there)\b', user_lower) and len(self.conversation_history) < 2:
            return {
                "type": "ambiguous_reference",
                "message": "I need more context. What specifically are you referring to?",
                "examples": [
                    "A specific repository?",
                    "A particular file or function?",
                    "A mathematical expression?"
                ]
            }
        
        # Repository operations without repo name
        github_keywords = ['file', 'commit', 'branch', 'pull request', 'issue']
        if any(keyword in user_lower for keyword in github_keywords):
            if not re.search(r'repo|repository|[\w-]+/[\w-]+', user_input):
                # Check if we have a default repo in context
                if not self.user_context.get('default_repo'):
                    return {
                        "type": "missing_repository",
                        "message": "Which repository would you like to work with?",
                        "examples": [
                            "Provide a repo name (e.g., 'drewelewis/ContosoBankAPI')",
                            "Set a default repo for this session",
                            "Use the default suggested repo"
                        ],
                        "suggestion": "drewelewis/ContosoBankAPI"
                    }
        
        # Vague requests
        vague_patterns = [
            r'^(help|info|tell me|show me|what)(\s+about)?$',
            r'^(yes|no|ok|okay|sure)$'
        ]
        if any(re.match(pattern, user_lower.strip()) for pattern in vague_patterns):
            return {
                "type": "vague_request",
                "message": "I'd be happy to help! Could you be more specific?",
                "examples": [
                    "Ask about GitHub repositories",
                    "Request a mathematical calculation",
                    "Get help with available commands"
                ]
            }
        
        return None
    
    def _format_clarification_request(self, clarification: Dict[str, Any]) -> str:
        """Format a clarification request for the user"""
        message = f"🤔 **Clarification Needed**\n\n{clarification['message']}\n"
        
        if clarification.get('examples'):
            message += "\n**Examples:**\n"
            for example in clarification['examples']:
                message += f"  • {example}\n"
        
        if clarification.get('suggestion'):
            message += f"\n💡 **Suggestion:** {clarification['suggestion']}"
            self.clarification_context['suggestion'] = clarification['suggestion']
        
        self.clarification_context['type'] = clarification['type']
        
        return message
    
    async def _handle_clarification_response(self, user_input: str, stream: bool) -> str:
        """Handle user's response to a clarification request"""
        self.waiting_for_clarification = False
        
        # Check if user accepted suggestion
        if user_input.lower() in ['yes', 'y', 'ok', 'sure', 'default', 'suggested']:
            if 'suggestion' in self.clarification_context:
                # Use the suggestion
                if self.clarification_context['type'] == 'missing_repository':
                    self.user_context['default_repo'] = self.clarification_context['suggestion']
                    return f"✅ Set default repository to: {self.clarification_context['suggestion']}\n\nWhat would you like to do with this repository?"
        
        # Process their clarification as a new message
        self.clarification_context = {}
        return await self.process_message(user_input, stream)
    
    def _preprocess_input(self, user_input: str) -> str:
        """
        Preprocess user input by applying context and preferences
        
        Returns:
            Enhanced user input with context applied
        """
        processed = user_input
        
        # Apply default repository if relevant
        if self.user_context.get('default_repo'):
            github_keywords = ['file', 'commit', 'branch', 'repo', 'code']
            if any(keyword in user_input.lower() for keyword in github_keywords):
                # Check if repo already specified
                if not re.search(r'[\w-]+/[\w-]+', user_input):
                    processed = f"{user_input} (using repository: {self.user_context['default_repo']})"
        
        return processed
    
    def _format_response(self, response: str, agent_info: Optional[str], original_input: str) -> str:
        """
        Format the orchestrator response for the user
        
        Args:
            response: Raw response from agent
            agent_info: Agent switching information
            original_input: Original user input
            
        Returns:
            Formatted response string
        """
        formatted_parts = []
        
        # Add agent info if present
        if agent_info:
            formatted_parts.append(agent_info)
            formatted_parts.append("")  # Blank line
        
        # Add main response
        formatted_parts.append(response)
        
        # Add follow-up suggestions
        suggestions = self._get_follow_up_suggestions(response, agent_info)
        if suggestions:
            formatted_parts.append("")
            formatted_parts.append(suggestions)
        
        return "\n".join(formatted_parts)
    
    def _get_follow_up_suggestions(self, response: str, agent_info: Optional[str]) -> Optional[str]:
        """
        Generate helpful follow-up suggestions based on the response
        
        Returns:
            Formatted suggestions string or None
        """
        suggestions = []
        
        # Determine current agent from agent_info
        current_agent = None
        if agent_info and "github" in agent_info.lower():
            current_agent = "github"
        elif agent_info and "math" in agent_info.lower():
            current_agent = "math"
        
        # Agent-specific suggestions
        if current_agent == "github":
            if "repositories" in response.lower():
                suggestions.append("Ask to browse files in a specific repository")
                suggestions.append("Request file content from a repository")
            elif "files" in response.lower():
                suggestions.append("Ask to view content of a specific file")
                suggestions.append("Request to create an issue")
        elif current_agent == "math":
            if any(op in response for op in ['+', '-', '*', '/', '=']):
                suggestions.append("Try another calculation")
                suggestions.append("Ask to evaluate a complex expression")
        
        # General suggestions
        if not suggestions:
            suggestions.append("Type 'list agents' to see available specialists")
            suggestions.append("Type 'clear' to start fresh")
        
        if suggestions:
            suggestion_text = "**💡 What's next?**\n"
            for i, suggestion in enumerate(suggestions[:3], 1):  # Limit to 3
                suggestion_text += f"  {i}. {suggestion}\n"
            return suggestion_text.rstrip()
        
        return None
    
    def _add_to_history(self, role: str, content: str):
        """Add message to conversation history"""
        self.conversation_history.append({
            "role": role,
            "content": content,
            "timestamp": datetime.now().isoformat()
        })
        
        # Keep last 20 messages
        if len(self.conversation_history) > 20:
            self.conversation_history = self.conversation_history[-20:]
    
    def set_user_preference(self, key: str, value: Any):
        """Set a user preference"""
        self.user_context[key] = value
        return f"✅ Preference set: {key} = {value}"
    
    def get_user_preference(self, key: str) -> Optional[Any]:
        """Get a user preference"""
        return self.user_context.get(key)
    
    def clear_history(self):
        """Clear conversation history"""
        self.conversation_history = []
        self.orchestrator.clear_all_history()
        return "✅ Conversation history cleared"
    
    def clear_context(self):
        """Clear user context and preferences"""
        self.user_context = {}
        return "✅ User context cleared"
    
    def get_delegation_stats(self) -> str:
        """Get statistics on proxy vs agent handling"""
        total = sum(self.delegation_stats.values())
        return f"""**📊 Delegation Statistics**

**Total Interactions:** {total}
  • Proxy Handled (commands): {self.delegation_stats['proxy_handled']}
  • Delegated to Agents: {self.delegation_stats['agent_delegated']}
  • Clarifications Requested: {self.delegation_stats['clarifications']}

**Delegation Ratio:** {self.delegation_stats['agent_delegated']}/{total} queries sent to specialized agents

💡 The proxy should primarily delegate to agents for domain work!
"""
    
    def get_status(self) -> str:
        """Get current status and context"""
        status_parts = [
            "**📊 User Proxy Status**",
            "",
            f"**Current Agent:** {self.orchestrator.get_current_agent_name() or 'None'}",
            f"**Conversation Messages:** {len(self.conversation_history)}",
            f"**User Preferences:** {len(self.user_context)}",
            f"**Debug Mode:** {'ON' if self.debug else 'OFF'}",
        ]
        
        if self.user_context:
            status_parts.append("")
            status_parts.append("**Active Preferences:**")
            for key, value in self.user_context.items():
                status_parts.append(f"  • {key}: {value}")
        
        return "\n".join(status_parts)
    
    def handle_command(self, command: str) -> Optional[str]:
        """
        Handle special commands (help, status, clear, etc.)
        
        Returns:
            Command response or None if not a command
        """
        cmd = command.lower().strip()
        
        if cmd in ['help', '?']:
            if self.debug:
                print("[DEBUG] User Proxy: Handling 'help' command (not delegating)")
            self.delegation_stats['proxy_handled'] += 1
            return self._get_help_text()
        elif cmd == 'status':
            if self.debug:
                print("[DEBUG] User Proxy: Handling 'status' command (not delegating)")
            self.delegation_stats['proxy_handled'] += 1
            return self.get_status()
        elif cmd in ['clear', 'reset']:
            if self.debug:
                print("[DEBUG] User Proxy: Handling 'clear' command (not delegating)")
            self.delegation_stats['proxy_handled'] += 1
            return self.clear_history()
        elif cmd == 'clear context':
            if self.debug:
                print("[DEBUG] User Proxy: Handling 'clear context' command (not delegating)")
            self.delegation_stats['proxy_handled'] += 1
            return self.clear_context()
        elif cmd == 'list agents':
            if self.debug:
                print("[DEBUG] User Proxy: Delegating 'list agents' to orchestrator")
            return self.orchestrator.list_agents()
        elif cmd.startswith('switch '):
            if self.debug:
                print("[DEBUG] User Proxy: Delegating 'switch' to orchestrator")
            agent_name = cmd.replace('switch ', '').strip()
            success, message = self.orchestrator.switch_agent(agent_name)
            return message
        elif cmd.startswith('set '):
            if self.debug:
                print("[DEBUG] User Proxy: Handling 'set preference' command (not delegating)")
            self.delegation_stats['proxy_handled'] += 1
            # Parse "set key=value"
            parts = cmd.replace('set ', '').split('=', 1)
            if len(parts) == 2:
                key, value = parts[0].strip(), parts[1].strip()
                return self.set_user_preference(key, value)
        elif cmd == 'debug':
            self.debug = not self.debug
            return f"✅ Debug mode: {'ON' if self.debug else 'OFF'}"
        elif cmd == 'stats':
            return self.get_delegation_stats()
        
        return None
    
    def _get_help_text(self) -> str:
        """Get help text for available commands"""
        return """**🤖 User Proxy Agent - Help**

**Proxy Commands (handled by proxy, not delegated):**
  • `help` or `?` - Show this help message
  • `status` - Show current agent and context
  • `clear` or `reset` - Clear conversation history
  • `clear context` - Clear user preferences
  • `set <key>=<value>` - Set a user preference
  • `debug` - Toggle debug mode (shows delegation flow)
  • `stats` - Show delegation statistics

**Orchestrator Commands (delegated to orchestrator):**
  • `list agents` - List all available specialized agents
  • `switch <agent>` - Manually switch to a specific agent

**User Preferences:**
  • `set default_repo=owner/repo` - Set default GitHub repository
  • `set format=detailed` - Set response format preference

**Natural Queries:**
  Just ask naturally! The proxy will route you to the right specialist:
  • "Show me repositories for drewelewis" → GitHub Agent
  • "What's 25 * 4?" → Math Agent
  • "List files in my repo" → GitHub Agent (with context)

**Tips:**
  • The proxy remembers your conversation context
  • It will ask for clarification when needed
  • Suggestions appear after each response to guide you
"""


# Example usage and integration
async def create_user_proxy_with_orchestrator(orchestrator_type='keyword', debug=False):
    """
    Factory function to create a UserProxyAgent with specified orchestrator
    
    Args:
        orchestrator_type: 'keyword', 'llm', or 'rule' (rule based)
        debug: Enable debug mode to show delegation flow
        
    Returns:
        Initialized UserProxyAgent instance
    """
    # Import appropriate orchestrator
    if orchestrator_type == 'keyword':
        from orchestrators.keyword_orchestrator import KeywordOrchestrator
        orchestrator = KeywordOrchestrator()
    elif orchestrator_type == 'llm':
        from orchestrators.llm_orchestrator import LLMOrchestrator
        orchestrator = LLMOrchestrator()
    elif orchestrator_type == 'rule':
        from orchestrators.rule_based_orchestrator import RuleBasedOrchestrator
        orchestrator = RuleBasedOrchestrator()
    else:
        raise ValueError(f"Unknown orchestrator type: {orchestrator_type}")
    
    # Create and initialize proxy
    proxy = UserProxyAgent(orchestrator, debug=debug)
    await proxy.initialize()
    
    if debug:
        print("[DEBUG] User Proxy initialized with debug mode ON")
        print("[DEBUG] Proxy will show delegation flow for all interactions")
    
    return proxy

"""
Rule-Based Orchestrator - Agent Framework Version
An orchestrator using complex business rules and priority-based routing

ORCHESTRATION STRATEGY:
- Priority-ordered business rules with conditional logic
- Each rule has: condition function, target agent, priority level
- Rules checked in priority order (highest first)
- Supports complex conditional logic and context awareness
- Fallback rules provide safety net for simple keyword matching

RULE CATEGORIES:
- High Priority (100+): Critical incidents, emergency scenarios
- Medium Priority (50-99): Specific operation patterns
- Low Priority (1-49): Simple keyword fallbacks

PROS:
- Highly flexible and configurable
- Business context aware routing
- Supports complex conditional logic
- Priority-based rule ordering
- Easy to add new business rules
- Deterministic and auditable decisions

CONS:
- Requires manual rule configuration
- Can become complex with many rules
- Rules need maintenance as business logic evolves
- May require domain expertise to configure properly

BEST FOR:
- Enterprise environments with complex business logic
- Scenarios requiring priority-based routing
- Auditable and compliant routing decisions
- Custom business workflow integration

EXAMPLE RULES:
- "critical + calculate" → Math (Priority 100)
- "analyze + code" → GitHub (Priority 90)
- "error + logs" → GitHub (Priority 90)
- Simple "github" → GitHub (Priority 10)
"""

import os
import re
from typing import Optional, Dict, List, Callable
from azure.identity.aio import DefaultAzureCredential
from azure.ai.projects.aio import AIProjectClient
from azure.core.pipeline.policies import HeadersPolicy
from azure.core.pipeline.transport import AioHttpTransport
from agent_framework.azure import AzureAIClient

from agents.github_agent import create_github_agent
from agents.math_agent import create_math_agent


class RoutingRule:
    """Represents a single routing rule"""
    
    def __init__(self, name: str, condition: Callable[[str], bool], agent_key: str, priority: int = 0):
        self.name = name
        self.condition = condition
        self.agent_key = agent_key
        self.priority = priority  # Higher priority rules are checked first


class RuleBasedOrchestrator:
    """Orchestrator that uses complex business rules for agent routing"""
    
    def __init__(self):
        """Initialize the rule-based orchestrator"""
        self.agents: Dict[str, any] = {}
        self.current_agent_name: Optional[str] = None
        self.routing_rules: List[RoutingRule] = []
        self._initialized = False
        
    async def initialize(self):
        """Initialize all specialized agents"""
        if self._initialized:
            return
        
        # Get configuration from environment
        project_endpoint = os.getenv('AZURE_PROJECT_ENDPOINT')
        model_deployment_name = os.getenv('MODEL_DEPLOYMENT_NAME', 'gpt-4o')
        apim_key = os.getenv('APIM_SUBSCRIPTION_KEY')

        if not project_endpoint:
            raise ValueError("AZURE_PROJECT_ENDPOINT environment variable is not set")

        # Build a shared async AIProjectClient that injects the APIM subscription key on
        # every outbound request so traffic is metered and governed by the gateway.
        credential = DefaultAzureCredential()
        headers_policy = HeadersPolicy(base_headers={'Ocp-Apim-Subscription-Key': apim_key}) if apim_key else None
        ssl_verify = os.getenv('AZURE_SSL_VERIFY', 'true').lower() != 'false'
        transport = None if ssl_verify else AioHttpTransport(connection_verify=False)
        project_client = AIProjectClient(
            endpoint=project_endpoint,
            credential=credential,
            **(({'headers_policy': headers_policy}) if headers_policy else {}),
            **(({'transport': transport}) if transport else {})
        )
        if apim_key:
            ssl_verify = os.getenv('AZURE_SSL_VERIFY', 'true').lower() != 'false'
            _bound_get_openai = project_client.get_openai_client
            def _get_openai_with_apim_key(**kwargs):
                kwargs.setdefault('default_headers', {})
                kwargs['default_headers'].setdefault('Ocp-Apim-Subscription-Key', apim_key)
                kwargs.setdefault('default_query', {'api-version': '2025-03-01-preview'})
                openai_client = _bound_get_openai(**kwargs)
                if not ssl_verify:
                    import httpx
                    openai_client._client = httpx.AsyncClient(
                        verify=False,
                        headers=openai_client._client.headers,
                        timeout=openai_client._client.timeout,
                    )
                return openai_client
            project_client.get_openai_client = _get_openai_with_apim_key

        # Initialize GitHub Agent
        github_client = AzureAIClient(
            project_client=project_client,
            model_deployment_name=model_deployment_name,
            credential=credential
        )
        self.agents['github'] = create_github_agent(github_client)

        # Initialize Math Agent (shares the same project_client / gateway connection)
        math_client = AzureAIClient(
            project_client=project_client,
            model_deployment_name=model_deployment_name,
            credential=credential
        )
        self.agents['math'] = create_math_agent(math_client)
        
        # Setup routing rules after agents are initialized
        self.setup_rules()
        
        self._initialized = True
        print(f"Initialized {len(self.agents)} specialized agent(s) with rule-based routing")
        
    def setup_rules(self):
        """Setup business rules for routing"""
        # High priority rules (checked first)
        self.routing_rules.extend([
            # Math calculation rules
            RoutingRule(
                "Complex Math Expression",
                lambda text: re.search(r'\d+\s*[\+\-\*\/\^%]\s*\d+', text) is not None,
                "math",
                priority=95
            ),
            
            # Code analysis rules
            RoutingRule(
                "Code Analysis Rule",
                lambda text: (any(word in text.lower() for word in ["analyze", "review", "check", "show", "browse"]) 
                             and any(word in text.lower() for word in ["code", "repository", "file", "function", "class"])),
                "github",
                priority=90
            ),
            
            # Repository operations
            RoutingRule(
                "Repository Operations",
                lambda text: any(word in text.lower() for word in ["repository", "repo", "commit", "branch", "pull request", "fork"]),
                "github",
                priority=85
            ),
            
            # Math keywords with numbers
            RoutingRule(
                "Math with Keywords",
                lambda text: any(word in text.lower() for word in ["calculate", "compute", "math", "equation"]),
                "math",
                priority=80
            )
        ])
        
        # Medium priority rules
        self.routing_rules.extend([
            # GitHub file operations
            RoutingRule(
                "GitHub File Operations",
                lambda text: any(phrase in text.lower() for phrase in ["show me", "get file", "browse", "list repos", "github"]),
                "github",
                priority=50
            ),
            
            # Math operations
            RoutingRule(
                "Math Operations",
                lambda text: any(word in text.lower() for word in ["add", "subtract", "multiply", "divide", "power", "modulo"]),
                "math",
                priority=50
            )
        ])
        
        # Low priority fallback rules (simple keyword matching)
        self.routing_rules.extend([
            RoutingRule(
                "GitHub Fallback",
                lambda text: any(word in text.lower() for word in ["github", "git", "repo", "code", "file"]),
                "github",
                priority=10
            ),
            
            RoutingRule(
                "Math Fallback",
                lambda text: any(word in text.lower() for word in ["math", "number", "expression"]),
                "math",
                priority=10
            )
        ])
        
        # Sort rules by priority (highest first)
        self.routing_rules.sort(key=lambda rule: rule.priority, reverse=True)
        print(f"Configured {len(self.routing_rules)} routing rules")
    
    def get_agent_by_rules(self, user_input: str) -> Optional[str]:
        """
        Determine which agent should handle the query based on business rules
        
        Args:
            user_input: The user's query
            
        Returns:
            Agent name or None
        """
        # Check rules in priority order
        for rule in self.routing_rules:
            if rule.condition(user_input):
                print(f"🎯 Matched rule: {rule.name} (priority: {rule.priority})")
                return rule.agent_key
        
        return None
    
    async def route_query(self, user_input: str, stream: bool = False):
        """
        Route the user query to the appropriate agent using business rules
        
        Args:
            user_input: The user's message
            stream: Whether to return a streaming response (not currently supported)
            
        Returns:
            Tuple of (response_text, agent_switch_info)
        """
        # Ensure initialization
        if not self._initialized:
            await self.initialize()
        
        # Try to determine the best agent using rules
        selected_agent_name = self.get_agent_by_rules(user_input)
        
        if not selected_agent_name:
            # No rule matched - return help info
            help_response = self.get_agent_selection_help()
            return help_response, None
        
        # Check if we switched agents
        agent_switch_info = None
        if self.current_agent_name != selected_agent_name:
            self.current_agent_name = selected_agent_name
            agent_switch_info = f"🤖 Rule-based routing to: {selected_agent_name.title()} Agent"
        
        # Get agent
        agent = self.agents[selected_agent_name]
        
        # Get response from agent
        response = await agent.run(user_input)
        
        # Convert AgentRunResponse to string
        response_text = str(response) if hasattr(response, '__str__') else response
        
        return response_text, agent_switch_info
    
    def get_agent_selection_help(self) -> str:
        """Provide help for selecting an agent"""
        help_text = "No routing rule matched your query. Here's what I can help with:\n\n"
        
        help_text += "**GitHub Agent**: Repository management and code analysis\n"
        help_text += "**Math Agent**: Mathematical calculations and expressions\n\n"
        
        help_text += "Example queries:\n"
        help_text += "- 'Show me the repositories for drewelewis'\n"
        help_text += "- 'Analyze the code in main.py'\n"
        help_text += "- 'Calculate 25 * 4 + 10'\n"
        help_text += "- 'What is 156 divided by 12?'\n\n"
        help_text += "Try being more specific about what you want to accomplish."
        
        return help_text
    
    def switch_agent(self, agent_identifier: str) -> tuple[bool, str]:
        """Manually switch to a specific agent"""
        agent_map = {
            'github': 'github', 'git': 'github', 'code': 'github',
            'math': 'math', 'calc': 'math', 'calculator': 'math'
        }
        
        agent_key = agent_map.get(agent_identifier.lower())
        if agent_key and agent_key in self.agents:
            self.current_agent_name = agent_key
            return True, f"✅ Switched to {agent_key.title()} Agent"
        else:
            available = ', '.join(agent_map.keys())
            return False, f"❌ Unknown agent: {agent_identifier}. Available: {available}"
    
    def list_agents(self) -> str:
        """List all available agents with their status"""
        agent_list = "Available Specialized Agents (Rule-Based Routing):\n\n"
        for i, agent_name in enumerate(self.agents.keys(), 1):
            status = "🟢 ACTIVE" if self.current_agent_name == agent_name else "⚪ Available"
            agent_list += f"{i}. **{agent_name.title()} Agent** {status}\n"
        return agent_list
    
    def clear_all_history(self):
        """Clear all agent conversation histories"""
        for agent_name in self.agents:
            self.threads[agent_name] = self.agents[agent_name].get_new_thread()
        self.current_agent_name = None
    
    def get_current_agent_name(self) -> Optional[str]:
        """Get the name of the currently active agent"""
        return self.current_agent_name
    
    def list_rules(self) -> str:
        """List all routing rules for debugging"""
        rules_text = "Active Routing Rules (in priority order):\n\n"
        for i, rule in enumerate(self.routing_rules, 1):
            rules_text += f"{i}. **{rule.name}** (Priority: {rule.priority}) → {rule.agent_key}\n"
        return rules_text
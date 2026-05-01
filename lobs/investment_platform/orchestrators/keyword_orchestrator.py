"""
Keyword Orchestrator - Agent Framework Version
An intelligent routing system for specialized AI agents using keyword-based matching

ORCHESTRATION STRATEGY:
- Simple keyword matching against predefined agent domain keywords
- Scores each agent based on number of keyword matches in user input
- Routes to agent with highest score (if any matches found)
- Fast and predictable routing decisions
- Pattern detection for numeric expressions (math agent)

PROS:
- Very fast routing (no LLM calls required)
- Predictable and deterministic behavior
- Easy to debug and understand
- Low computational overhead
- No additional API costs

CONS:
- Limited context understanding
- May miss nuanced intent
- Relies on exact keyword presence
- Cannot handle complex multi-domain queries well

BEST FOR:
- Simple, clear-cut routing needs
- High-volume environments where speed matters
- Predictable user query patterns
- Cost-conscious deployments

EXAMPLE ROUTING:
- "show github repositories" → GitHub Agent (matches: github, repositories)
- "calculate 5 + 3" → Math Agent (matches: calculate, numeric pattern)
- "what is 25 * 4" → Math Agent (matches: numeric pattern)
"""

import os
import re
from typing import Optional, Dict
from azure.identity.aio import DefaultAzureCredential
from azure.ai.projects.aio import AIProjectClient
from azure.core.pipeline.policies import HeadersPolicy
from azure.core.pipeline.transport import AioHttpTransport
from agent_framework.azure import AzureAIClient

from agents.github_agent import create_github_agent
from agents.math_agent import create_math_agent



class KeywordOrchestrator:
    """Orchestrator that manages multiple specialized agents with keyword-based routing"""
    
    def __init__(self):
        """Initialize the keyword-based orchestrator"""
        self.agents: Dict[str, any] = {}
        self.current_agent_name: Optional[str] = None
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
        github_agent = create_github_agent(github_client)
        self.agents['github'] = github_agent
        print(f"[DEBUG] Created GitHub agent: {github_agent}, name: {getattr(github_agent, 'name', 'N/A')}")

        # Initialize Math Agent (shares the same project_client / gateway connection)
        math_client = AzureAIClient(
            project_client=project_client,
            model_deployment_name=model_deployment_name,
            credential=credential
        )
        math_agent = create_math_agent(math_client)
        self.agents['math'] = math_agent
        print(f"[DEBUG] Created Math agent: {math_agent}, name: {getattr(math_agent, 'name', 'N/A')}")
        
        self._initialized = True
        print(f"Initialized {len(self.agents)} specialized agent(s)")
        print(f"[DEBUG] Agent keys: {list(self.agents.keys())}")
    
    def get_agent_keywords(self) -> Dict[str, list]:
        """Return keyword mappings for agent routing"""
        return {
            'github': ['github', 'repository', 'repo', 'code', 'file', 'branch', 'commit', 'pull', 'issue', 'fork'],
            'math': ['calculate', 'math', 'add', 'subtract', 'multiply', 'divide', 'equation', 'expression', 'number', 'compute']
        }
        
    def get_agent_by_keywords(self, user_input: str) -> Optional[str]:
        """
        Determine which agent should handle the query based on keywords
        
        Args:
            user_input: The user's query
            
        Returns:
            Agent name or None
        """
        user_lower = user_input.lower()
        keywords = self.get_agent_keywords()
        
        # Score each agent based on keyword matches
        scores = {}
        for agent_name, agent_keywords in keywords.items():
            score = sum(1 for keyword in agent_keywords if keyword in user_lower)
            scores[agent_name] = score
        
        # Boost math agent score if input contains numbers with operators
        math_pattern = r'\d+\s*[\+\-\*\/\^%]\s*\d+'
        if re.search(math_pattern, user_input):
            scores['math'] = scores.get('math', 0) + 5
        
        # Boost math agent for "what is" followed by numbers
        if re.search(r'what\s+is\s+\d+', user_lower):
            scores['math'] = scores.get('math', 0) + 3
        
        # Debug output
        print(f"[DEBUG] Routing scores for '{user_input}': {scores}")
        
        # Return agent with highest score (if any matches)
        max_score = max(scores.values())
        if max_score > 0:
            selected = max(scores, key=scores.get)
            print(f"[DEBUG] Selected agent: {selected}")
            return selected
        
        return None
    
    async def route_query(self, user_input: str, stream: bool = False):
        """
        Route the user query to the appropriate agent
        
        Args:
            user_input: The user's message
            stream: Whether to return a streaming response (not currently supported)
            
        Returns:
            Tuple of (response_text, agent_switch_info)
        """
        # Ensure initialization
        if not self._initialized:
            await self.initialize()
        
        # Try to determine the best agent automatically
        selected_agent_name = self.get_agent_by_keywords(user_input)
        
        if not selected_agent_name:
            # No agent matched - return help info
            help_response = self.get_agent_selection_help()
            return help_response, None
        
        # Check if we switched agents
        agent_switch_info = None
        if self.current_agent_name != selected_agent_name:
            self.current_agent_name = selected_agent_name
            agent_switch_info = f"🤖 Routed to: {selected_agent_name.title()} Agent"
        
        # Get agent
        agent = self.agents[selected_agent_name]
        print(f"[DEBUG] Retrieved agent for '{selected_agent_name}': {agent}, name: {getattr(agent, 'name', 'N/A')}")
        
        # Get response from agent
        response = await agent.run(user_input)
        
        # Convert AgentRunResponse to string
        response_text = str(response) if hasattr(response, '__str__') else response
        
        return response_text, agent_switch_info
    
    def get_agent_selection_help(self) -> str:
        """Provide help for selecting an agent"""
        keywords = self.get_agent_keywords()
        help_text = "I'm not sure which specialist can help you best. Here are your options:\n\n"
        
        for agent_name, agent_keywords in keywords.items():
            help_text += f"**{agent_name.title()} Agent**\n"
            help_text += f"Keywords: {', '.join(agent_keywords[:5])}\n"
            if agent_name == 'math':
                help_text += "Also detects: numeric expressions (e.g., 5 + 3, 12 * 4)\n"
            help_text += "\n"
        
        help_text += "Try using specific keywords in your question to help me route you correctly."
        
        return help_text
    
    def switch_agent(self, agent_identifier: str) -> tuple[bool, str]:
        """
        Manually switch to a specific agent
        
        Args:
            agent_identifier: Agent name or alias
            
        Returns:
            Tuple of (success, message)
        """
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
        agent_list = "Available Specialized Agents:\n\n"
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
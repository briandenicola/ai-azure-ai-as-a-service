"""
LLM Orchestrator - Agent Framework Version
An orchestrator using LLM intelligence for sophisticated routing decisions

ORCHESTRATION STRATEGY:
- Uses dedicated LLM instance for routing decisions
- Analyzes user intent and context, not just keywords
- Provides detailed agent descriptions to LLM for informed routing
- Low temperature (0.1) for consistent, deterministic routing
- Fallback to keyword matching if LLM routing fails
- Separate routing call to avoid interference with agent conversations

LLM ROUTING PROCESS:
1. User query analyzed by routing LLM
2. LLM considers agent capabilities and user intent
3. Returns agent name or 'none' if uncertain
4. Fallback to keyword matching on LLM failure

PROS:
- Understands user intent and context
- Handles complex and ambiguous queries
- Natural language understanding
- Can reason about multi-domain requests
- Adapts to new query patterns without rule changes
- Most intelligent routing decisions

CONS:
- Slower than other methods (requires LLM call)
- Additional API costs for routing decisions
- Potential for inconsistent routing (mitigated by low temperature)
- Depends on LLM service availability
- Harder to debug routing decisions

BEST FOR:
- Complex, ambiguous user queries
- Natural language heavy environments
- Scenarios where routing accuracy is critical
- Applications with unpredictable query patterns
- User-facing systems requiring natural interaction

EXAMPLE ROUTING:
- "Help me understand why the login is failing" → GitHub (intent: troubleshoot code)
- "I need to review the authentication logic" → GitHub (intent: code review)
- "What's 25 plus 17?" → Math (intent: calculation)
"""

import os
from typing import Optional, Dict
from azure.identity.aio import DefaultAzureCredential
from azure.ai.projects.aio import AIProjectClient
from azure.core.pipeline.policies import HeadersPolicy
from azure.core.pipeline.transport import AioHttpTransport
from dotenv import load_dotenv

load_dotenv(override=True)


class _DirectResponsesAgent:
    """
    Minimal agent that calls the OpenAI Responses API directly.

    Replaces AzureAIClient/ChatAgent for the specialized agents because
    agent_framework_azure_ai calls project_client.agents.create_version()
    (api-version 2025-11-15-preview only) which is not available in our
    Foundry instance.  The Responses API itself works fine at 2025-03-01-preview
    through APIM once the model/instructions are passed explicitly.
    """

    def __init__(self, openai_client, model: str, instructions: str) -> None:
        self._client = openai_client
        self._model = model
        self._instructions = instructions

    async def run(self, user_input: str) -> str:
        resp = await self._client.responses.create(
            model=self._model,
            instructions=self._instructions,
            input=user_input,
        )
        return resp.output[0].content[0].text


class LLMOrchestrator:
    """Orchestrator that uses LLM intelligence to make routing decisions"""
    
    def __init__(self):
        """Initialize the LLM-based orchestrator"""
        self.agents: Dict[str, any] = {}
        self.current_agent_name: Optional[str] = None
        self._initialized = False
        self._routing_openai_client = None
        self._routing_model = None
        
    async def initialize(self):
        """Initialize all specialized agents and routing logic"""
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
        # Patch get_openai_client to forward the APIM subscription key.
        # The headers_policy injects the key for Agents API calls through the
        # AIProjectClient pipeline, but the AsyncOpenAI client returned by
        # get_openai_client() is a separate httpx client that requires the key
        # to be set via default_headers.
        if apim_key:
            ssl_verify = os.getenv('AZURE_SSL_VERIFY', 'true').lower() != 'false'
            _bound_get_openai = project_client.get_openai_client
            def _get_openai_with_apim_key(**kwargs):
                kwargs.setdefault('default_headers', {})
                kwargs['default_headers'].setdefault('Ocp-Apim-Subscription-Key', apim_key)
                # Override api-version: SDK default (2025-11-15-preview) is unreleased;
                # Foundry supports Responses API at 2025-03-01-preview.
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
        # Build a plain AsyncOpenAI client that authenticates to APIM using the
        # subscription key (always present) plus an optional user Entra Bearer token
        # (present when the console app performs interactive login via chat.py).
        # We cannot use project_client.get_openai_client() here because it injects
        # a DefaultAzureCredential token — that is a service identity, not a user
        # identity, and is not what the APIM validate-jwt policy expects.
        import httpx as _httpx
        from openai import AsyncOpenAI as _AsyncOpenAI
        _apim_base = project_endpoint.rstrip('/') + '/openai/'
        # Build the default headers for every outbound APIM request.
        # The subscription key is always required for quota/product routing.
        # If the user authenticated via Entra (chat.py sets ENTRA_ACCESS_TOKEN),
        # we also attach the Bearer token so APIM can log user identity and,
        # optionally, validate the JWT via validate-jwt policy.
        # The WAF Authorization-header exclusion (waf-appgw.bicep) allows JWTs
        # through without triggering OWASP rules.
        _default_headers: dict = {'Ocp-Apim-Subscription-Key': apim_key}
        _access_token = os.getenv('ENTRA_ACCESS_TOKEN', '')
        if _access_token:
            _default_headers['Authorization'] = f'Bearer {_access_token}'
        _oi_client = _AsyncOpenAI(
            base_url=_apim_base,
            api_key=apim_key,
            default_headers=_default_headers,
            default_query={'api-version': '2025-03-01-preview'},
            timeout=60.0,
            http_client=_httpx.AsyncClient(
                verify=ssl_verify,
                timeout=_httpx.Timeout(60.0),
            ),
        )
        self._routing_openai_client = _oi_client
        self._routing_model = model_deployment_name

        # Initialize specialized agents using _DirectResponsesAgent so that all
        # inference calls go through APIM via the patched openai client.
        self.agents['github'] = _DirectResponsesAgent(
            openai_client=self._routing_openai_client,
            model=model_deployment_name,
            instructions=(
                "You are a specialized GitHub Assistant Agent. Help users with repository "
                "management, code analysis, and file browsing. Be thorough and actionable."
            ),
        )
        self.agents['math'] = _DirectResponsesAgent(
            openai_client=self._routing_openai_client,
            model=model_deployment_name,
            instructions=(
                "You are a specialized Math Assistant Agent. Perform arithmetic and "
                "mathematical calculations accurately. Always show the result clearly."
            ),
        )
        
        self._initialized = True
        print(f"Initialized {len(self.agents)} specialized agent(s) with LLM routing")
    
    _ROUTING_INSTRUCTIONS = (
        "You are a routing classifier. Read the user message and reply with exactly one word: "
        "github for questions about source code or repositories, "
        "math for arithmetic or numeric calculations, "
        "or none if neither applies."
    )

    def get_routing_prompt(self, user_input: str) -> str:
        """Return the user input unchanged; routing instructions are passed via the system prompt."""
        return user_input
    
    async def get_agent_by_llm(self, user_input: str) -> Optional[str]:
        """
        Use LLM intelligence to determine which agent should handle the query
        
        Args:
            user_input: The user's query
            
        Returns:
            Agent name or None
        """
        try:
            # Create a routing prompt
            routing_prompt = self.get_routing_prompt(user_input)
            
            # Call the Responses API directly to get a routing decision.
            # Using run_stream via ChatAgent/AzureAIClient would trigger
            # project_client.agents.create_version which requires api-version
            # 2025-11-15-preview — not available in our Foundry instance.
            routing_resp = await self._routing_openai_client.responses.create(
                model=self._routing_model,
                instructions=self._ROUTING_INSTRUCTIONS,
                input=routing_prompt,
                temperature=0.1,
            )
            response_text = routing_resp.output[0].content[0].text
            
            decision = response_text.strip().lower()
            print(f"🧠 LLM routing decision: {decision}")
            
            if decision in self.agents:
                return decision
            elif decision == "none":
                return None
            else:
                raise ValueError(f"LLM returned unexpected routing decision: {decision!r}")

        except ValueError:
            raise
        except Exception as e:
            raise RuntimeError(f"LLM routing failed: {e}") from e
    
    async def route_query(self, user_input: str, stream: bool = False):
        """
        Route the user query using LLM intelligence
        
        Args:
            user_input: The user's message
            stream: Whether to return a streaming response (not currently supported)
            
        Returns:
            Tuple of (response_text, agent_switch_info)
        """
        # Ensure initialization
        if not self._initialized:
            await self.initialize()
        
        # Use LLM to determine the best agent
        selected_agent_name = await self.get_agent_by_llm(user_input)
        
        if not selected_agent_name:
            raise ValueError("LLM routing returned no matching agent for this request")
        
        # Check if we switched agents
        agent_switch_info = None
        if self.current_agent_name != selected_agent_name:
            self.current_agent_name = selected_agent_name
            agent_switch_info = f"🤖 LLM routed to: {selected_agent_name.title()} Agent"
        
        # Get agent
        agent = self.agents[selected_agent_name]
        
        # Get response from agent
        response = await agent.run(user_input)
        
        # Convert AgentRunResponse to string
        response_text = str(response) if hasattr(response, '__str__') else response
        
        return response_text, agent_switch_info
    
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
        agent_list = "Available Specialized Agents (LLM-Powered Routing):\n\n"
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
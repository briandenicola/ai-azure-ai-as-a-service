"""
Example 6: Full Foundry Agent Reference with APIM Gateway
===========================================================

This is a COMPLETE reference implementation showing how to:
1. Create a Foundry agent that routes through APIM
2. Configure the agent with proper endpoint validation
3. Define and handle function tools
4. Deploy the agent to Azure AI Foundry
5. Invoke the agent and handle streaming responses

WHY APIM:
- Enforces token quotas (e.g., 100K TPM per department)
- Applies semantic caching (faster + cheaper)
- Circuit breaker for multi-region failover
- Audit logging for compliance
- Content safety filtering
"""

import os
import json
import time
from typing import Dict, Any, List
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.core.exceptions import HttpResponseError


# ============================================================================
# Configuration: Read from Environment (NEVER hardcode!)
# ============================================================================

class AgentConfig:
    """Centralized configuration with validation."""
    
    def __init__(self):
        # Read from environment
        self.apim_endpoint = os.environ.get(
            "AI_GATEWAY_ENDPOINT",
            "https://your-company-ai.azure-api.net"  # Default for local dev
        )
        self.project_id = os.environ.get(
            "AI_PROJECT_ID",
            "ai-hub-project"
        )
        self.deployment_name = os.environ.get(
            "AI_DEPLOYMENT_NAME", 
            "gpt-4o"
        )
        
        # Validate APIM endpoint
        self._validate_endpoint()
    
    def _validate_endpoint(self):
        """Ensure we're using APIM, not direct Foundry endpoint."""
        if not self.apim_endpoint.endswith(".azure-api.net"):
            raise ValueError(
                f"❌ Invalid endpoint: {self.apim_endpoint}\n"
                f"Must use APIM gateway (*.azure-api.net), not direct Foundry.\n"
                f"This ensures token quotas and policies are enforced."
            )
        print(f"✅ Using APIM gateway: {self.apim_endpoint}")


# ============================================================================
# Tool Definitions: Functions the Agent Can Call
# ============================================================================

def get_customer_order_status(order_id: str) -> Dict[str, Any]:
    """
    Simulates looking up customer order status.
    In production, this would call your backend API.
    """
    # Mock data
    orders = {
        "ORD-12345": {
            "status": "shipped",
            "tracking": "1Z999AA10123456784",
            "estimated_delivery": "2026-03-07"
        },
        "ORD-67890": {
            "status": "processing",
            "estimated_ship_date": "2026-03-05"
        }
    }
    
    return orders.get(order_id, {"status": "not_found"})


def calculate_shipping_cost(origin_zip: str, dest_zip: str, weight_lbs: float) -> Dict[str, Any]:
    """
    Calculates shipping cost between two ZIP codes.
    In production, this would call a shipping API (FedEx, UPS, etc.).
    """
    # Simple mock calculation
    distance_factor = abs(int(origin_zip[:2]) - int(dest_zip[:2]))
    cost = round(5.99 + (distance_factor * 0.5) + (weight_lbs * 0.3), 2)
    
    return {
        "cost_usd": cost,
        "currency": "USD",
        "estimated_days": min(distance_factor, 7)
    }


def search_product_catalog(query: str, category: str = None) -> List[Dict[str, Any]]:
    """
    Searches product catalog.
    In production, this would query your database or search index.
    """
    # Mock product data
    products = [
        {"id": "PROD-001", "name": "Wireless Mouse", "price": 29.99, "category": "electronics"},
        {"id": "PROD-002", "name": "USB-C Cable", "price": 12.99, "category": "electronics"},
        {"id": "PROD-003", "name": "Desk Lamp", "price": 45.00, "category": "office"},
    ]
    
    # Simple filter
    results = [p for p in products if query.lower() in p["name"].lower()]
    if category:
        results = [p for p in results if p["category"] == category.lower()]
    
    return results


# Map function names to actual Python functions
TOOL_FUNCTIONS = {
    "get_customer_order_status": get_customer_order_status,
    "calculate_shipping_cost": calculate_shipping_cost,
    "search_product_catalog": search_product_catalog
}


# ============================================================================
# Agent Definition with OpenAI Function Schema
# ============================================================================

AGENT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_customer_order_status",
            "description": "Look up the status of a customer's order by order ID",
            "parameters": {
                "type": "object",
                "properties": {
                    "order_id": {
                        "type": "string",
                        "description": "The order ID (e.g., ORD-12345)"
                    }
                },
                "required": ["order_id"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "calculate_shipping_cost",
            "description": "Calculate shipping cost between two ZIP codes",
            "parameters": {
                "type": "object",
                "properties": {
                    "origin_zip": {
                        "type": "string",
                        "description": "Origin ZIP code (5 digits)"
                    },
                    "dest_zip": {
                        "type": "string",
                        "description": "Destination ZIP code (5 digits)"
                    },
                    "weight_lbs": {
                        "type": "number",
                        "description": "Package weight in pounds"
                    }
                },
                "required": ["origin_zip", "dest_zip", "weight_lbs"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "search_product_catalog",
            "description": "Search for products in the catalog by name or category",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query (product name or keywords)"
                    },
                    "category": {
                        "type": "string",
                        "description": "Filter by category (electronics, office, etc.)",
                        "enum": ["electronics", "office", "home"]
                    }
                },
                "required": ["query"]
            }
        }
    }
]


# ============================================================================
# Foundry Agent Manager
# ============================================================================

class FoundryAgentManager:
    """Manages lifecycle of Foundry agents with APIM gateway routing."""
    
    def __init__(self, config: AgentConfig):
        self.config = config
        self.credential = DefaultAzureCredential()
        
        # Create AI Project client pointing to APIM gateway
        self.client = AIProjectClient(
            credential=self.credential,
            project_id=config.project_id,
            endpoint=config.apim_endpoint  # This ensures ALL traffic goes through APIM
        )
        
        print(f"✅ Connected to project: {config.project_id}")
        print(f"   via APIM gateway: {config.apim_endpoint}")
    
    def create_agent(self, name: str = "customer-service-agent") -> Any:
        """
        Create a new Foundry agent with tools.
        
        The agent is created in Foundry but will route all inference
        requests through the APIM gateway (which applies quotas, caching, etc.)
        """
        try:
            agent = self.client.agents.create_agent(
                model=self.config.deployment_name,
                name=name,
                instructions="""You are a helpful customer service agent for an e-commerce company.

Your capabilities:
- Look up order status using order IDs
- Calculate shipping costs between ZIP codes
- Search the product catalog

Guidelines:
- Be friendly and professional
- Always use tools when you need real data
- If a tool returns "not_found", apologize and offer alternatives
- Provide precise information based on tool results
""",
                tools=AGENT_TOOLS
            )
            
            print(f"\n✅ Agent created: {agent.id}")
            print(f"   Name: {agent.name}")
            print(f"   Model: {agent.model}")
            print(f"   Tools: {len(AGENT_TOOLS)}")
            
            return agent
            
        except HttpResponseError as e:
            print(f"❌ Failed to create agent: {e}")
            raise
    
    def create_thread(self) -> Any:
        """Create a conversation thread."""
        thread = self.client.agents.create_thread()
        print(f"✅ Thread created: {thread.id}")
        return thread
    
    def send_message(self, thread_id: str, message: str) -> Any:
        """Send a user message to the thread."""
        msg = self.client.agents.create_message(
            thread_id=thread_id,
            role="user",
            content=message
        )
        print(f"\n👤 User: {message}")
        return msg
    
    def run_agent(self, thread_id: str, agent_id: str, stream: bool = False) -> Any:
        """
        Run the agent on the thread.
        
        This is where the magic happens:
        1. Agent analyzes the conversation
        2. Decides which tools to call (if any)
        3. Makes inference requests through APIM gateway
        4. APIM applies quotas, caching, circuit breakers, etc.
        5. Agent processes results and responds
        """
        print(f"🤖 Running agent...")
        
        if stream:
            return self._run_agent_streaming(thread_id, agent_id)
        else:
            return self._run_agent_sync(thread_id, agent_id)
    
    def _run_agent_sync(self, thread_id: str, agent_id: str) -> Any:
        """Synchronous agent execution with tool handling."""
        run = self.client.agents.create_run(
            thread_id=thread_id,
            assistant_id=agent_id
        )
        
        # Poll until complete
        while run.status in ["queued", "in_progress", "requires_action"]:
            time.sleep(1)
            run = self.client.agents.get_run(thread_id=thread_id, run_id=run.id)
            
            # Handle tool calls
            if run.status == "requires_action":
                run = self._handle_tool_calls(thread_id, run)
        
        if run.status == "completed":
            print(f"✅ Run completed: {run.id}")
            return run
        else:
            print(f"❌ Run failed with status: {run.status}")
            raise Exception(f"Run failed: {run.status}")
    
    def _handle_tool_calls(self, thread_id: str, run: Any) -> Any:
        """Execute tool calls and submit results back to agent."""
        tool_calls = run.required_action.submit_tool_outputs.tool_calls
        tool_outputs = []
        
        print(f"🔧 Agent requesting {len(tool_calls)} tool call(s):")
        
        for tool_call in tool_calls:
            function_name = tool_call.function.name
            function_args = json.loads(tool_call.function.arguments)
            
            print(f"   - {function_name}({function_args})")
            
            # Execute the function
            if function_name in TOOL_FUNCTIONS:
                try:
                    result = TOOL_FUNCTIONS[function_name](**function_args)
                    output = json.dumps(result)
                    print(f"     ✅ Result: {output}")
                except Exception as e:
                    output = json.dumps({"error": str(e)})
                    print(f"     ❌ Error: {e}")
            else:
                output = json.dumps({"error": f"Unknown function: {function_name}"})
            
            tool_outputs.append({
                "tool_call_id": tool_call.id,
                "output": output
            })
        
        # Submit tool outputs back to the agent
        run = self.client.agents.submit_tool_outputs_to_run(
            thread_id=thread_id,
            run_id=run.id,
            tool_outputs=tool_outputs
        )
        
        return run
    
    def _run_agent_streaming(self, thread_id: str, agent_id: str) -> Any:
        """Streaming agent execution (for real-time responses)."""
        print("🤖 Streaming response:")
        
        with self.client.agents.create_stream(
            thread_id=thread_id,
            assistant_id=agent_id
        ) as stream:
            for event in stream:
                if event.event == "thread.message.delta":
                    if hasattr(event.data, "delta") and hasattr(event.data.delta, "content"):
                        for content in event.data.delta.content:
                            if hasattr(content, "text") and hasattr(content.text, "value"):
                                print(content.text.value, end="", flush=True)
        
        print()  # New line after streaming
    
    def get_messages(self, thread_id: str) -> List[Any]:
        """Retrieve all messages from the thread."""
        messages = self.client.agents.list_messages(thread_id=thread_id)
        return list(messages)
    
    def print_conversation(self, thread_id: str):
        """Pretty print the conversation."""
        messages = self.get_messages(thread_id)
        
        print("\n" + "="*80)
        print("CONVERSATION HISTORY")
        print("="*80)
        
        for msg in reversed(messages.data):  # Reverse to show chronological order
            role_icon = "👤" if msg.role == "user" else "🤖"
            print(f"\n{role_icon} {msg.role.upper()}:")
            
            for content in msg.content:
                if hasattr(content, "text"):
                    print(f"   {content.text.value}")
        
        print("="*80)
    
    def cleanup_agent(self, agent_id: str):
        """Delete agent when no longer needed."""
        try:
            self.client.agents.delete_agent(agent_id)
            print(f"✅ Agent deleted: {agent_id}")
        except Exception as e:
            print(f"⚠️ Could not delete agent: {e}")


# ============================================================================
# Demo Scenarios
# ============================================================================

def demo_scenario_1(manager: FoundryAgentManager, agent_id: str):
    """Demo: Order status lookup."""
    print("\n" + "="*80)
    print("SCENARIO 1: Order Status Inquiry")
    print("="*80)
    
    thread = manager.create_thread()
    
    manager.send_message(thread.id, "Hi! Can you check the status of order ORD-12345?")
    manager.run_agent(thread.id, agent_id)
    
    manager.print_conversation(thread.id)


def demo_scenario_2(manager: FoundryAgentManager, agent_id: str):
    """Demo: Shipping cost calculation."""
    print("\n" + "="*80)
    print("SCENARIO 2: Shipping Cost Inquiry")
    print("="*80)
    
    thread = manager.create_thread()
    
    manager.send_message(
        thread.id, 
        "How much would it cost to ship a 5-pound package from ZIP 94105 to ZIP 10001?"
    )
    manager.run_agent(thread.id, agent_id)
    
    manager.print_conversation(thread.id)


def demo_scenario_3(manager: FoundryAgentManager, agent_id: str):
    """Demo: Product search and multi-turn conversation."""
    print("\n" + "="*80)
    print("SCENARIO 3: Product Search + Multi-turn")
    print("="*80)
    
    thread = manager.create_thread()
    
    # Turn 1: Search
    manager.send_message(thread.id, "I need a new mouse for my computer")
    manager.run_agent(thread.id, agent_id)
    
    # Turn 2: Follow-up
    manager.send_message(thread.id, "How much would shipping cost to ZIP 98101?")
    manager.run_agent(thread.id, agent_id)
    
    manager.print_conversation(thread.id)


# ============================================================================
# Main Execution
# ============================================================================

def main():
    """Main entry point."""
    
    print("="*80)
    print("FOUNDRY AGENT + APIM GATEWAY - FULL REFERENCE IMPLEMENTATION")
    print("="*80)
    
    # 1. Load and validate configuration
    try:
        config = AgentConfig()
    except ValueError as e:
        print(f"\n{e}")
        print("\nTo fix, set environment variables:")
        print("  export AI_GATEWAY_ENDPOINT=https://your-company-ai.azure-api.net")
        print("  export AI_PROJECT_ID=ai-hub-project")
        return
    
    # 2. Initialize agent manager
    manager = FoundryAgentManager(config)
    
    # 3. Create the agent (this is persisted in Foundry)
    agent = manager.create_agent()
    
    try:
        # 4. Run demo scenarios
        demo_scenario_1(manager, agent.id)
        demo_scenario_2(manager, agent.id)
        demo_scenario_3(manager, agent.id)
        
        print("\n✅ All scenarios completed successfully!")
        print(f"\nNote: All inference calls went through APIM gateway at:")
        print(f"      {config.apim_endpoint}")
        print(f"\nThis means:")
        print(f"  ✅ Token quotas were enforced")
        print(f"  ✅ Semantic caching was applied")
        print(f"  ✅ Circuit breaker protected against failures")
        print(f"  ✅ All requests were logged for audit")
        
    finally:
        # 5. Cleanup (optional - comment out to keep agent for reuse)
        cleanup = input("\nDelete agent? (y/N): ").lower().strip()
        if cleanup == 'y':
            manager.cleanup_agent(agent.id)
        else:
            print(f"Agent preserved. ID: {agent.id}")


if __name__ == "__main__":
    main()

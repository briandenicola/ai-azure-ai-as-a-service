"""
Example 2: Agent with Tools
============================

Show how developers create agents that can call tools (functions).
This is where the real power comes in—agents that can take actions.

The APIM gateway:
- Routes the agent requests securely
- Logs all tool calls
- Tracks token usage
- Caches repeated queries
"""

import json
import os
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

# Read from environment - NEVER hardcode direct endpoints!
PROJECT_ID = os.environ.get("AI_PROJECT_ID", "my-hub-project")
APIM_GATEWAY_URL = os.environ.get("AI_GATEWAY_ENDPOINT", "https://your-company-ai.azure-api.net")

# Validate endpoint is APIM, not direct Foundry
if not APIM_GATEWAY_URL.endswith(".azure-api.net"):
    raise ValueError(
        f"Invalid endpoint: {APIM_GATEWAY_URL}. "
        "Must use APIM gateway (*.azure-api.net), not direct Foundry endpoint."
    )

def create_agent_with_tools():
    """Create an agent that can use tools."""
    
    credential = DefaultAzureCredential()
    client = AIProjectClient(
        credential=credential,
        project_id=PROJECT_ID,
        endpoint=APIM_GATEWAY_URL  # Always APIM - enforces quotas & policies
    )
    
    # 1. Define tools (functions the agent can call)
    tools = [
        {
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "Get the current weather for a location",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "location": {
                            "type": "string",
                            "description": "City name (e.g., New York, London)"
                        },
                        "unit": {
                            "type": "string",
                            "enum": ["celsius", "fahrenheit"],
                            "description": "Temperature unit"
                        }
                    },
                    "required": ["location"]
                }
            }
        },
        {
            "type": "function",
            "function": {
                "name": "get_flight_price",
                "description": "Check flight price from origin to destination",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "origin": {"type": "string", "description": "Airport code (e.g., SFO)"},
                        "destination": {"type": "string", "description": "Airport code"},
                        "date": {"type": "string", "description": "Travel date (YYYY-MM-DD)"}
                    },
                    "required": ["origin", "destination", "date"]
                }
            }
        }
    ]
    
    # 2. Create the agent with tools
    agent = client.agents.create_agent(
        name="travel-assistant",
        model="gpt-4o",
        instructions="Help users plan travel. Check weather and flights using available tools.",
        tools=tools
    )
    
    print(f"✓ Agent created: {agent.id}")
    print(f"  Name: {agent.name}")
    print(f"  Model: {agent.model}")
    print(f"  Tools: {len(tools)}")
    
    return client, agent.id

def run_agent_conversation(client, agent_id):
    """Run a conversation with the agent."""
    
    # 1. Create a conversation thread
    thread = client.agents.create_thread()
    print(f"\n✓ Thread created: {thread.id}")
    
    # 2. Send a user message
    user_message = "What's the weather in London? And how much does a flight from NYC to London cost on March 15?"
    
    message = client.agents.create_message(
        thread_id=thread.id,
        role="user",
        content=user_message
    )
    
    print(f"\nUser: {user_message}")
    
    # 3. Run the agent
    run = client.agents.create_run(
        thread_id=thread.id,
        assistant_id=agent_id
    )
    
    print(f"\nAgent is processing...")
    
    # 4. Handle tool calls (the agent will call get_weather and get_flight_price)
    max_iterations = 10
    iterations = 0
    
    while run.status in ["queued", "in_progress", "requires_action"]:
        iterations += 1
        if iterations > max_iterations:
            print("Max iterations reached")
            break
        
        # Get updated run status
        run = client.agents.get_run(thread_id=thread.id, run_id=run.id)
        
        if run.status == "requires_action":
            print(f"\nAgent needs to call tools...")
            
            tool_calls = run.required_action.submit_tool_outputs.tool_calls
            tool_outputs = []
            
            for tool_call in tool_calls:
                tool_name = tool_call.function.name
                tool_args = json.loads(tool_call.function.arguments)
                
                print(f"  → Calling {tool_name}({tool_args})")
                
                # Simulate tool results (in real app, call actual APIs)
                if tool_name == "get_weather":
                    result = f"Sunny, 15°C in {tool_args['location']}"
                elif tool_name == "get_flight_price":
                    result = f"$450 for flight {tool_args['origin']}-{tool_args['destination']} on {tool_args['date']}"
                else:
                    result = "Unknown tool"
                
                print(f"    ← Result: {result}")
                
                tool_outputs.append({
                    "tool_call_id": tool_call.id,
                    "output": result
                })
            
            # Submit tool results back to the agent
            run = client.agents.submit_tool_outputs(
                thread_id=thread.id,
                run_id=run.id,
                tool_outputs=tool_outputs
            )
    
    # 5. Get the final response
    if run.status == "completed":
        messages = client.agents.list_messages(thread_id=thread.id)
        
        print(f"\nAgent Response:")
        for msg in messages.data:
            if msg.role == "assistant":
                print(f"  {msg.content[0].text}")
    else:
        print(f"Run ended with status: {run.status}")

if __name__ == "__main__":
    # Create agent
    client, agent_id = create_agent_with_tools()
    
    # Run conversation
    run_agent_conversation(client, agent_id)
    
    print("\n" + "="*60)
    print("What happened behind the scenes:")
    print("="*60)
    print("1. Your agent ran through APIM (Azure API Management)")
    print("2. Every request was logged for audit")
    print("3. Token count was tracked for chargeback")
    print("4. Response was cached (future similar queries will be faster)")
    print("5. All data passed through your company's governance policies")
    print("6. You can see the full trace in Application Insights")

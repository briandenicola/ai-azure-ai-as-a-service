"""
Math Agent - Microsoft Agent Framework Version
A specialized AI agent for mathematical calculations and operations
"""

import os
import asyncio
from dotenv import load_dotenv
from azure.identity.aio import DefaultAzureCredential
from agent_framework.azure import AzureAIClient
from agent_framework import ChatAgent

# Import math tools
from tools.math_tool import (
    add,
    subtract,
    multiply,
    divide,
    power,
    modulo,
    evaluate_expression
)

# Load environment variables
load_dotenv(override=True)


AGENT_NAME = "MathAgent"
AGENT_DESCRIPTION = "Handles mathematical operations like addition, subtraction, multiplication, division, powers, modulo, and complex expression evaluation."


def create_math_agent(client: AzureAIClient) -> ChatAgent:
    """
    Create and configure the Math Agent with calculation tools.
    
    Args:
        client: AzureAIClient instance for model inference
    
    Returns:
        Configured ChatAgent instance
    """
    # Define agent instructions
    instructions = """You are a specialized Math Assistant Agent. You are an expert in:
- Basic arithmetic operations (addition, subtraction, multiplication, division)
- Advanced operations (exponents, modulo)
- Complex mathematical expression evaluation
- Order of operations and parentheses handling

**Your Capabilities:**
- Perform arithmetic calculations on numbers
- Evaluate complex mathematical expressions like "(2 + 3) * 4"
- Handle operations: +, -, *, /, ** (power), % (modulo)
- Support parentheses and proper order of operations
- Provide clear, formatted results

**Instructions:**
- Focus exclusively on mathematical calculations and operations
- Always show the calculation clearly in your response
- For complex expressions, break down the steps if helpful
- Handle division by zero gracefully with clear error messages
- If asked about non-math topics, politely redirect to your math expertise
- Be precise with numbers and maintain accuracy

**Usage Examples:**
- "What is 15 + 27?" → Use add tool
- "Calculate 100 / 4" → Use divide tool
- "Evaluate (5 + 3) * 2" → Use evaluate_expression tool
- "What's 2 to the power of 10?" → Use power tool

Always provide helpful, accurate mathematical results."""
    
    # Create local agent with math tools
    agent = ChatAgent(
        chat_client=client,
        name=AGENT_NAME,
        instructions=instructions,
        tools=[
            add,
            subtract,
            multiply,
            divide,
            power,
            modulo,
            evaluate_expression
        ]
    )
    
    return agent


async def main():
    """
    Main entry point for running the Math Agent in interactive mode.
    For HTTP server mode, use a server wrapper instead.
    """
    print("\n" + "="*60)
    print("Math Assistant Agent - Microsoft Agent Framework")
    print("="*60 + "\n")
    
    # Get configuration from environment
    project_endpoint = os.getenv('AZURE_PROJECT_ENDPOINT')
    model_deployment_name = os.getenv('MODEL_DEPLOYMENT_NAME', 'gpt-4.1')
    
    if not project_endpoint:
        raise ValueError("AZURE_PROJECT_ENDPOINT environment variable is not set")
    
    # Create credential and client
    credential = DefaultAzureCredential()
    client = AzureAIClient(
        project_endpoint=project_endpoint,
        model_deployment_name=model_deployment_name,
        credential=credential
    )
    
    # Create the local agent
    agent = create_math_agent(client)
    
    print("✅ Math Agent initialized successfully!")
    print("💬 Type your math questions (or 'quit' to exit)\n")
    
    # Interactive chat loop
    while True:
        try:
            user_input = input("You: ")
            print()
            
            if user_input.lower() in ['quit', 'exit', 'q']:
                print("Goodbye!")
                break
            
            if not user_input.strip():
                continue
            
            # Get response from agent
            print("Agent: ", end="", flush=True)
            response = await agent.run(user_input)
            print(response)
            print("\n")
            
        except KeyboardInterrupt:
            print("\n\nGoodbye!")
            break
        except Exception as e:
            print(f"❌ Error: {e}\n")


if __name__ == "__main__":
    asyncio.run(main())

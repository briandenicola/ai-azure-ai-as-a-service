"""
Chat Interface with User Proxy Agent
Demonstrates the User Proxy Agent pattern with intelligent conversation management

ARCHITECTURE:
User → User Proxy Agent → Orchestrator → Specialized Agents → Tools
        ↑                                                        ↓
        └───────────── Enhanced Response ──────────────────────┘

FEATURES:
- Intelligent clarification requests
- User context and preference management
- Response formatting and suggestions
- Command handling (help, status, clear, etc.)
- Multi-turn conversation support
- Agent routing visibility (shows which agent is handling the query)
- Tool call tracking (shows which tools the agents are using)
"""

import asyncio
import sys
from dotenv import load_dotenv

from agents.user_proxy_agent import create_user_proxy_with_orchestrator

# Load environment variables
load_dotenv(override=True)


def print_banner():
    """Print welcome banner"""
    print("\n" + "=" * 70)
    print("🤖 AI Agent System with User Proxy")
    print("=" * 70)
    print("Architecture: User → Proxy → Orchestrator → Specialized Agents")
    print()
    print("Type 'help' for commands, 'quit' to exit")
    print("=" * 70 + "\n")


async def main():
    """Main chat loop with User Proxy Agent"""
    
    # Choose orchestrator type
    print("Choose orchestrator type:")
    print("  1. Keyword-based (fast, simple)")
    print("  2. LLM-based (intelligent, context-aware)")
    print("  3. Rule-based (business logic)")
    
    choice = input("\nEnter choice [1-3] (default: 1): ").strip()
    
    orchestrator_map = {
        '1': 'keyword',
        '2': 'llm',
        '3': 'rule',
        '': 'keyword'  # default
    }
    
    orchestrator_type = orchestrator_map.get(choice, 'keyword')
    
    # Ask about debug mode
    debug_choice = input("Enable debug mode to see delegation flow? [y/N]: ").strip().lower()
    debug = debug_choice == 'y'
    
    print(f"\n✅ Using {orchestrator_type} orchestrator")
    if debug:
        print("🐛 Debug mode: ON (will show proxy → agent delegation)")
    print("🔄 Initializing User Proxy Agent...")
    
    # Create and initialize user proxy with orchestrator
    try:
        proxy = await create_user_proxy_with_orchestrator(orchestrator_type, debug=debug)
        print("✅ User Proxy Agent initialized successfully!\n")
    except Exception as e:
        print(f"❌ Failed to initialize: {e}")
        return
    
    print_banner()
    
    # Main conversation loop
    while True:
        try:
            # Get user input
            user_input = input("You: ").strip()
            
            if not user_input:
                continue
            
            # Handle exit commands
            if user_input.lower() in ['quit', 'exit', 'bye']:
                print("\n👋 Goodbye!")
                break
            
            # Check for special commands first
            command_response = proxy.handle_command(user_input)
            if command_response:
                print(f"\n{command_response}\n")
                continue
            
            # Process message through proxy (non-streaming for simplicity)
            print("\n🤖 Assistant: ", end="", flush=True)
            response = await proxy.process_message(user_input, stream=False)
            print(response)
            print()  # Blank line for readability
            
        except KeyboardInterrupt:
            print("\n\n👋 Interrupted. Goodbye!")
            break
        except Exception as e:
            print(f"\n❌ Error: {e}\n")
            continue


async def main_streaming():
    """Main chat loop with streaming responses"""
    
    print("Choose orchestrator type:")
    print("  1. Keyword-based (fast, simple)")
    print("  2. LLM-based (intelligent, context-aware)")
    print("  3. Rule-based (business logic)")
    
    choice = input("\nEnter choice [1-3] (default: 1): ").strip()
    
    orchestrator_map = {
        '1': 'keyword',
        '2': 'llm',
        '3': 'rule',
        '': 'keyword'
    }
    
    orchestrator_type = orchestrator_map.get(choice, 'keyword')
    
    print(f"\n✅ Using {orchestrator_type} orchestrator")
    print("🔄 Initializing User Proxy Agent...")
    
    try:
        proxy = await create_user_proxy_with_orchestrator(orchestrator_type)
        print("✅ User Proxy Agent initialized successfully!\n")
    except Exception as e:
        print(f"❌ Failed to initialize: {e}")
        return
    
    print_banner()
    
    # Main conversation loop with streaming
    while True:
        try:
            user_input = input("You: ").strip()
            
            if not user_input:
                continue
            
            if user_input.lower() in ['quit', 'exit', 'bye']:
                print("\n👋 Goodbye!")
                break
            
            # Check for special commands
            command_response = proxy.handle_command(user_input)
            if command_response:
                print(f"\n{command_response}\n")
                continue
            
            # Process with streaming
            print("\n🤖 Assistant: ", end="", flush=True)
            
            generator = await proxy.process_message(user_input, stream=True)
            async for chunk in generator:
                print(chunk, end="", flush=True)
            
            print("\n")  # Blank line after response
            
        except KeyboardInterrupt:
            print("\n\n👋 Interrupted. Goodbye!")
            break
        except Exception as e:
            print(f"\n❌ Error: {e}\n")
            continue


if __name__ == "__main__":
    # Choose between streaming and non-streaming mode
    mode = input("Use streaming mode? [y/N]: ").strip().lower()
    
    if mode == 'y':
        asyncio.run(main_streaming())
    else:
        asyncio.run(main())

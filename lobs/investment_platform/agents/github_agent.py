"""
GitHub Agent - Microsoft Agent Framework Version
A specialized AI agent for GitHub repository management and code analysis
"""

import os
import asyncio
from dotenv import load_dotenv
from azure.identity.aio import DefaultAzureCredential
from agent_framework.azure import AzureAIClient
from agent_framework import ChatAgent

# Import GitHub tools
from tools.github_tool import (
    get_repos_by_user,
    get_files_by_repo,
    get_file_content,
    create_github_issue
)

# Load environment variables
load_dotenv(override=True)


def create_github_agent(client: AzureAIClient) -> ChatAgent:
    """
    Create and configure the GitHub Agent with tools.
    
    Args:
        client: AzureAIClient instance for model inference
    
    Returns:
        Configured ChatAgent instance
    """
    # Define agent instructions
    instructions = """You are a specialized GitHub Assistant Agent. You are an expert in:
- Repository management and navigation
- Code analysis and review
- File browsing and content retrieval
- GitHub best practices and workflows

**Your Capabilities:**
- List repositories for any GitHub user
- Browse repository structure and files
- Retrieve and analyze file contents
- Create GitHub issues
- Provide insights about code organization

**Default Configuration:**
- Default GitHub user: drewelewis
- Default repository: drewelewis/ContosoBankAPI
- Always verify with users if they want to use different repositories

**Your Expertise:**
- Code structure analysis
- Repository organization patterns
- File dependency mapping
- Code quality assessment
- Development workflow guidance

**Instructions:**
- Focus exclusively on GitHub-related tasks and questions
- Provide detailed insights about repository structure and code
- Help users understand codebases and find specific files or functions
- Offer suggestions for code organization and best practices
- Be thorough in your analysis and explanations
- If asked about non-GitHub topics, politely redirect to your GitHub expertise

Always think step by step when analyzing repositories and provide clear, actionable insights."""
    
    # Create local agent with tools
    agent = ChatAgent(
        chat_client=client,
        name="GitHubAgent",
        instructions=instructions,
        tools=[
            get_repos_by_user,
            get_files_by_repo,
            get_file_content,
            create_github_issue
        ]
    )
    
    return agent


async def main():
    """
    Main entry point for running the GitHub Agent in interactive mode.
    For HTTP server mode, use server.py instead.
    """
    print("\n" + "="*60)
    print("GitHub Assistant Agent - Microsoft Agent Framework")
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
    agent = create_github_agent(client)
    
    print("✅ GitHub Agent initialized successfully!")
    print("💬 Type your questions (or 'quit' to exit)\n")
    
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

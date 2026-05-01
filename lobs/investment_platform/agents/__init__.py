"""
AI Agent League - Agent Framework Agents

This package contains specialized agents built with Microsoft Agent Framework:
- GitHub Agent: Repository management and code operations
- Math Agent: Mathematical calculations and expressions

Each agent is initialized via async factory functions.
"""

from .github_agent import create_github_agent
from .math_agent import create_math_agent

__all__ = [
    'create_github_agent',
    'create_math_agent'
]
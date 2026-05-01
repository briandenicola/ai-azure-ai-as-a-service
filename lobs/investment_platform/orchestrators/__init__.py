"""
Orchestrators Package

This package contains orchestration strategies for managing multiple AI agents:
- KeywordOrchestrator: Fast keyword-based routing with pattern detection
- LLMOrchestrator: Intelligent LLM-based routing for complex intent
- RuleBasedOrchestrator: Priority-based business rules for routing

All orchestrators use Microsoft Agent Framework.
"""

from .keyword_orchestrator import KeywordOrchestrator
from .llm_orchestrator import LLMOrchestrator
from .rule_based_orchestrator import RuleBasedOrchestrator

__all__ = [
    'KeywordOrchestrator',
    'LLMOrchestrator',
    'RuleBasedOrchestrator'
]
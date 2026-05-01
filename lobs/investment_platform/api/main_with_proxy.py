"""
FastAPI Server with User Proxy Agent
Production-ready REST API using User Proxy pattern for enhanced conversation management

ARCHITECTURE:
API Request → User Proxy Agent → Orchestrator → Specialized Agents → Tools
                     ↑                                                    ↓
                     └───────────── Enhanced Response ───────────────────┘

BENEFITS:
- Session-aware conversation management
- Automatic clarification requests
- User context persistence across requests
- Consistent response formatting
- Command handling (status, preferences, etc.)
"""

import os
import asyncio
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from typing import Dict, Any, Optional
from dotenv import load_dotenv
from pydantic import BaseModel

from models.chat_models import Message, Session, AgentStatusResponse, HealthResponse
from agents.user_proxy_agent import create_user_proxy_with_orchestrator

# Load environment variables
load_dotenv(override=True)

# Service metadata
service_name = os.getenv("SERVICE_NAME", "ai-agent-starter")
service_version = os.getenv("SERVICE_VERSION", "2.0.0")

# Create FastAPI app
app = FastAPI(
    title="AI Agent Starter API with User Proxy",
    description="Multi-agent system with intelligent user proxy for conversation management",
    version=service_version,
    docs_url="/docs",
    redoc_url="/redoc"
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Global user proxy manager (maps session_id to UserProxyAgent)
session_proxies: Dict[str, Any] = {}
default_orchestrator_type = os.getenv("ORCHESTRATOR_TYPE", "keyword")


# Additional models for proxy features
class PreferenceRequest(BaseModel):
    session_id: str
    key: str
    value: str


class CommandRequest(BaseModel):
    session_id: str
    command: str


async def get_or_create_proxy(session_id: str, orchestrator_type: Optional[str] = None):
    """
    Get existing proxy for session or create new one
    
    Args:
        session_id: Session identifier
        orchestrator_type: Optional orchestrator type override
        
    Returns:
        UserProxyAgent instance
    """
    if session_id not in session_proxies:
        orch_type = orchestrator_type or default_orchestrator_type
        proxy = await create_user_proxy_with_orchestrator(orch_type)
        session_proxies[session_id] = proxy
        print(f"✅ Created new proxy for session: {session_id} (orchestrator: {orch_type})")
    
    return session_proxies[session_id]


@app.on_event("startup")
async def startup_event():
    """Initialize on startup"""
    print(f"🚀 Starting {service_name} v{service_version}")
    print(f"📦 Framework: Microsoft Agent Framework with User Proxy")
    print(f"🎯 Default Orchestrator: {default_orchestrator_type}")
    
    # Validate required environment variables
    required_vars = ["AZURE_PROJECT_ENDPOINT", "MODEL_DEPLOYMENT_NAME"]
    missing = [var for var in required_vars if not os.getenv(var)]
    
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")
    
    print("✅ API ready to accept connections")
    print(f"🌐 API Documentation: http://localhost:8989/docs")


@app.on_event("shutdown")
async def shutdown_event():
    """Cleanup on shutdown"""
    print(f"👋 Shutting down {service_name}")
    print(f"📊 Active sessions: {len(session_proxies)}")
    session_proxies.clear()


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """
    Health check endpoint
    
    Returns:
        Service status and metadata
    """
    return HealthResponse(
        status="healthy",
        service=service_name,
        version=service_version,
        framework="Microsoft Agent Framework with User Proxy"
    )


@app.post("/agent_chat")
async def agent_chat(message: Message):
    """
    Multi-agent chat with User Proxy pattern
    
    The User Proxy manages conversation flow and routes to appropriate agents:
    - Handles clarification requests automatically
    - Remembers user context and preferences
    - Formats responses consistently
    - Provides follow-up suggestions
    
    Request body:
    {
        "session_id": "user-123",
        "message": "List repos for microsoft",
        "stream": false,
        "orchestrator_type": "keyword"  // optional: keyword, llm, or rule
    }
    
    Returns:
        Enhanced response with formatting and suggestions
    """
    try:
        # Get or create proxy for this session
        proxy = await get_or_create_proxy(
            message.session_id,
            getattr(message, 'orchestrator_type', None)
        )
        
        # Check if it's a command
        command_response = proxy.handle_command(message.message)
        if command_response:
            return {
                "status": "success",
                "session_id": message.session_id,
                "response": command_response,
                "type": "command"
            }
        
        # Process message through proxy
        if message.stream:
            # Return streaming response
            async def generate():
                generator = await proxy.process_message(message.message, stream=True)
                async for chunk in generator:
                    yield chunk
            
            return StreamingResponse(
                generate(),
                media_type="text/plain"
            )
        else:
            # Non-streaming response
            response = await proxy.process_message(message.message, stream=False)
            
            return {
                "status": "success",
                "session_id": message.session_id,
                "response": response,
                "type": "message",
                "agent_used": proxy.orchestrator.get_current_agent_name() or "auto-routed"
            }
        
    except Exception as e:
        print(f"❌ Error in agent_chat: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Error processing request: {str(e)}"
        )


@app.get("/session_status/{session_id}")
async def session_status(session_id: str):
    """
    Get status for a specific session
    
    Returns:
        Session context, preferences, and current agent
    """
    if session_id not in session_proxies:
        raise HTTPException(status_code=404, detail=f"Session not found: {session_id}")
    
    try:
        proxy = session_proxies[session_id]
        status_text = proxy.get_status()
        
        return {
            "status": "success",
            "session_id": session_id,
            "details": status_text,
            "current_agent": proxy.orchestrator.get_current_agent_name(),
            "message_count": len(proxy.conversation_history),
            "preferences": proxy.user_context
        }
        
    except Exception as e:
        print(f"❌ Error getting session status: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/set_preference")
async def set_preference(request: PreferenceRequest):
    """
    Set a user preference for a session
    
    Request body:
    {
        "session_id": "user-123",
        "key": "default_repo",
        "value": "drewelewis/ContosoBankAPI"
    }
    
    Common preferences:
    - default_repo: Default GitHub repository
    - format: Response format (brief, detailed)
    - language: Preferred language for responses
    """
    try:
        proxy = await get_or_create_proxy(request.session_id)
        result = proxy.set_user_preference(request.key, request.value)
        
        return {
            "status": "success",
            "session_id": request.session_id,
            "message": result,
            "preferences": proxy.user_context
        }
        
    except Exception as e:
        print(f"❌ Error setting preference: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/execute_command")
async def execute_command(request: CommandRequest):
    """
    Execute a proxy command for a session
    
    Request body:
    {
        "session_id": "user-123",
        "command": "status"
    }
    
    Available commands:
    - status: Get current status
    - list agents: List available agents
    - clear: Clear conversation history
    - clear context: Clear user preferences
    - switch <agent>: Switch to specific agent
    """
    try:
        proxy = await get_or_create_proxy(request.session_id)
        result = proxy.handle_command(request.command)
        
        if result is None:
            raise HTTPException(status_code=400, detail=f"Unknown command: {request.command}")
        
        return {
            "status": "success",
            "session_id": request.session_id,
            "response": result
        }
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Error executing command: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/agent_status")
async def agent_status():
    """
    Get global agent status and capabilities
    
    Returns:
        Agent availability and capabilities across all orchestrator types
    """
    return {
        "status": "operational",
        "architecture": "User Proxy → Orchestrator → Specialized Agents",
        "orchestrator_types": {
            "keyword": {
                "description": "Fast keyword-based routing",
                "pros": ["Very fast", "Predictable", "No API costs"],
                "best_for": "High-volume, predictable queries"
            },
            "llm": {
                "description": "Intelligent LLM-powered routing",
                "pros": ["Context-aware", "Natural language", "Intent understanding"],
                "best_for": "Complex, ambiguous queries"
            },
            "rule": {
                "description": "Business rule-based routing",
                "pros": ["Priority-based", "Business logic", "Auditable"],
                "best_for": "Enterprise with complex routing rules"
            }
        },
        "agents": {
            "github_agent": {
                "status": "ready",
                "capabilities": [
                    "list_repositories",
                    "view_files",
                    "read_content",
                    "create_issues"
                ],
                "keywords": ["github", "repo", "repository", "issue", "file"]
            },
            "math_agent": {
                "status": "ready",
                "capabilities": [
                    "arithmetic",
                    "expression_evaluation"
                ],
                "keywords": ["calculate", "math", "add", "subtract", "multiply", "divide"]
            }
        },
        "proxy_features": [
            "Clarification requests",
            "User context management",
            "Response formatting",
            "Follow-up suggestions",
            "Command handling",
            "Session persistence"
        ],
        "active_sessions": len(session_proxies)
    }


@app.post("/clear_session/{session_id}")
async def clear_session(session_id: str):
    """
    Clear/remove a session completely
    
    This removes the session proxy and all associated context
    """
    if session_id in session_proxies:
        del session_proxies[session_id]
        return {
            "status": "success",
            "message": f"Session {session_id} cleared completely"
        }
    
    raise HTTPException(status_code=404, detail=f"Session not found: {session_id}")


@app.post("/clear_chat_history")
async def clear_chat_history(session: Session):
    """
    Clear chat history for a session (keeps preferences)
    
    Request body:
    {
        "session_id": "user-123"
    }
    """
    if session.session_id not in session_proxies:
        return {
            "status": "success",
            "message": f"No history found for session {session.session_id}"
        }
    
    try:
        proxy = session_proxies[session.session_id]
        result = proxy.clear_history()
        
        return {
            "status": "success",
            "session_id": session.session_id,
            "message": result
        }
        
    except Exception as e:
        print(f"❌ Error clearing history: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/")
async def root():
    """Root endpoint with API information"""
    return {
        "service": service_name,
        "version": service_version,
        "framework": "Microsoft Agent Framework",
        "architecture": "User Proxy Pattern",
        "docs": "/docs",
        "health": "/health",
        "endpoints": {
            "chat": "POST /agent_chat",
            "session_status": "GET /session_status/{session_id}",
            "agent_status": "GET /agent_status",
            "set_preference": "POST /set_preference",
            "execute_command": "POST /execute_command",
            "clear_history": "POST /clear_chat_history",
            "clear_session": "POST /clear_session/{session_id}"
        },
        "features": [
            "Session-aware conversations",
            "Automatic clarification handling",
            "User context management",
            "Multiple orchestrator types",
            "Response formatting & suggestions"
        ],
        "active_sessions": len(session_proxies)
    }

"""
FastAPI Server for AI Agent League
Production-ready REST API with Microsoft Agent Framework
"""
import os
import asyncio
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from typing import Dict, Any
from dotenv import load_dotenv
from azure.identity.aio import DefaultAzureCredential
from agent_framework.azure import AzureAIClient

from models.chat_models import Message, Session, AgentStatusResponse, HealthResponse
from orchestrators.keyword_orchestrator import KeywordOrchestrator

# Load environment variables
load_dotenv(override=True)

# Service metadata
service_name = os.getenv("SERVICE_NAME", "ai-agent-starter")
service_version = os.getenv("SERVICE_VERSION", "1.0.0")

# Create FastAPI app
app = FastAPI(
    title="AI Agent Starter API",
    description="Multi-agent system powered by Microsoft Agent Framework with intelligent routing",
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

# Global orchestrator (initialized on startup)
orchestrator: KeywordOrchestrator = None


@app.on_event("startup")
async def startup_event():
    """Initialize orchestrator on startup"""
    global orchestrator
    
    print(f"🚀 Starting {service_name} v{service_version}")
    print(f"📦 Framework: Microsoft Agent Framework")
    
    # Validate required environment variables
    required_vars = ["AZURE_PROJECT_ENDPOINT", "MODEL_DEPLOYMENT_NAME"]
    missing = [var for var in required_vars if not os.getenv(var)]
    
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")
    
    # Initialize orchestrator
    orchestrator = KeywordOrchestrator()
    await orchestrator.initialize()
    
    print("✅ Orchestrator initialized successfully")
    print(f"🌐 API Documentation: http://localhost:8989/docs")


@app.on_event("shutdown")
async def shutdown_event():
    """Cleanup on shutdown"""
    print(f"👋 Shutting down {service_name}")


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """
    Health check endpoint
    
    Returns:
        Service status and metadata
    """
    return HealthResponse(
        status="healthy" if orchestrator else "initializing",
        service=service_name,
        version=service_version,
        framework="Microsoft Agent Framework"
    )


@app.post("/agent_chat")
async def agent_chat(message: Message):
    """
    Multi-agent chat endpoint with intelligent routing
    
    The orchestrator automatically routes messages to the appropriate agent:
    - GitHub queries → GitHub Agent
    - Math operations → Math Agent
    
    Request body:
    {
        "session_id": "user-123",
        "message": "List repos for microsoft",
        "stream": false
    }
    
    Returns:
        Response from the appropriate agent
    """
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Orchestrator not initialized")
    
    try:
        # Route the query through the orchestrator
        response, agent_info = await orchestrator.route_query(
            user_input=message.message,
            stream=message.stream
        )
        
        return {
            "status": "success",
            "session_id": message.session_id,
            "response": response,
            "agent_used": agent_info or "auto-routed"
        }
        
    except Exception as e:
        print(f"❌ Error in agent_chat: {e}")
        raise HTTPException(
            status_code=500,
            detail=f"Error processing request: {str(e)}"
        )


@app.get("/agent_status")
async def agent_status():
    """
    Get status of all agents
    
    Returns:
        Agent availability and capabilities
    """
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Orchestrator not initialized")
    
    try:
        return {
            "status": "operational",
            "orchestrator": "KeywordOrchestrator",
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
            "routing": "keyword-based"
        }
        
    except Exception as e:
        print(f"❌ Error getting agent status: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/clear_chat_history")
async def clear_chat_history(session: Session):
    """
    Clear chat history for a session
    
    Note: Currently not implemented as we don't persist history in this version.
    Included for API compatibility.
    
    Request body:
    {
        "session_id": "user-123"
    }
    """
    return {
        "status": "success",
        "message": f"Chat history cleared for session {session.session_id}",
        "note": "History persistence not implemented in current version"
    }


@app.get("/")
async def root():
    """Root endpoint with API information"""
    return {
        "service": service_name,
        "version": service_version,
        "framework": "Microsoft Agent Framework",
        "docs": "/docs",
        "health": "/health",
        "endpoints": {
            "chat": "POST /agent_chat",
            "status": "GET /agent_status",
            "clear_history": "POST /clear_chat_history"
        }
    }

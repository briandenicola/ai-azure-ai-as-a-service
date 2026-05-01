"""
Main Entry Point for AI Agent Starter
Starts the FastAPI HTTP server with Microsoft Agent Framework
"""

import os
from dotenv import load_dotenv

# Load environment variables FIRST
load_dotenv(override=True)

if __name__ == "__main__":
    import uvicorn
    
    print("🚀 AI Agent Starter - FastAPI Server")
    print("=" * 50)
    print(f"📦 Framework: Microsoft Agent Framework")
    print(f"🌐 Port: 8989")
    print(f"📚 API Docs: http://localhost:8989/docs")
    print(f"💚 Health Check: http://localhost:8989/health")
    print("=" * 50)
    print()
    
    # Get configuration from environment
    host = os.getenv("SERVER_HOST", "0.0.0.0")
    port = int(os.getenv("SERVER_PORT", "8989"))
    reload = os.getenv("SERVER_RELOAD", "false").lower() == "true"
    
    # Start uvicorn server
    uvicorn.run(
        "api.main:app",
        host=host,
        port=port,
        reload=reload,
        log_level="info",
        timeout_keep_alive=60
    )

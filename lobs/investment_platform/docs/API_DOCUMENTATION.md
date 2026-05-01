# AI Agent Starter - API Documentation

## 🎯 Overview

AI Agent Starter is a multi-agent system built with **Microsoft Agent Framework** and **FastAPI**, providing intelligent routing between specialized agents through a production-ready REST API.

**Architecture:**
- **Framework:** Microsoft Agent Framework (not Semantic Kernel)
- **API Server:** FastAPI with uvicorn (production-ready)
- **Orchestration:** Keyword-based intelligent routing
- **Agents:** GitHub Agent, Math Agent (extensible)
- **Deployment:** Docker/docker-compose ready

---

## 🚀 Quick Start

### Local Development

```bash
# 1. Install dependencies
pip install -r requirements.txt

# 2. Configure environment
cp env.sample .env
# Edit .env with your Azure credentials

# 3. Run the server
python main.py
```

Server starts at: **http://localhost:8989**

### Docker Deployment

```bash
# Build and start services
_build.bat  # Build Docker image
_up.bat     # Start all services

# Or use docker-compose directly
docker-compose up -d

# View logs
_logs.bat
docker logs -f ai-agent-starter

# Stop services
_down.bat
```

---

## 🌐 API Endpoints

### Base URL
```
http://localhost:8989
```

### Interactive Documentation
- **Swagger UI:** http://localhost:8989/docs
- **ReDoc:** http://localhost:8989/redoc

---

### 1. Root Information
```http
GET /
```

Returns API information and available endpoints.

**Response:**
```json
{
  "service": "ai-agent-starter",
  "version": "1.0.0",
  "framework": "Microsoft Agent Framework",
  "docs": "/docs",
  "health": "/health",
  "endpoints": {
    "chat": "POST /agent_chat",
    "status": "GET /agent_status",
    "clear_history": "POST /clear_chat_history"
  }
}
```

---

### 2. Health Check
```http
GET /health
```

Check service health and status.

**Response:**
```json
{
  "status": "healthy",
  "service": "ai-agent-starter",
  "version": "1.0.0",
  "framework": "Microsoft Agent Framework"
}
```

---

### 3. Agent Chat (Main Endpoint)
```http
POST /agent_chat
```

Send messages to the multi-agent system. The orchestrator automatically routes to the appropriate agent.

**Request Body:**
```json
{
  "session_id": "user-123",
  "message": "List repos for microsoft",
  "stream": false
}
```

**Parameters:**
- `session_id` (string, required): Unique identifier for the conversation session
- `message` (string, required): User's query or message
- `stream` (boolean, optional): Enable streaming response (default: false)

**Response:**
```json
{
  "status": "success",
  "session_id": "user-123",
  "response": "Here are the repositories...",
  "agent_used": "auto-routed"
}
```

**Examples:**

**Math Query:**
```bash
curl -X POST http://localhost:8989/agent_chat \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "demo-001",
    "message": "Calculate 25 * 4"
  }'
```

**GitHub Query:**
```bash
curl -X POST http://localhost:8989/agent_chat \
  -H "Content-Type: application/json" \
  -d '{
    "session_id": "demo-001",
    "message": "Show me repositories for openai"
  }'
```

---

### 4. Agent Status
```http
GET /agent_status
```

Get information about available agents and their capabilities.

**Response:**
```json
{
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
```

---

### 5. Clear Chat History
```http
POST /clear_chat_history
```

Clear chat history for a specific session.

**Request Body:**
```json
{
  "session_id": "user-123"
}
```

**Response:**
```json
{
  "status": "success",
  "message": "Chat history cleared for session user-123",
  "note": "History persistence not implemented in current version"
}
```

---

## 🤖 Agent Routing

The **KeywordOrchestrator** automatically routes queries to specialized agents:

### GitHub Agent
**Triggers:** github, repo, repository, issue, file, pull request, commit
**Capabilities:**
- List user repositories
- Browse repository files
- Read file contents
- Create issues

**Example Queries:**
- "List repos for microsoft"
- "Show files in openai/gpt-3 repo"
- "Create an issue in my-repo"

### Math Agent
**Triggers:** calculate, math, add, subtract, multiply, divide, compute
**Capabilities:**
- Arithmetic operations (add, subtract, multiply, divide, power, modulo)
- Expression evaluation
- Complex calculations

**Example Queries:**
- "Calculate 15 + 27"
- "What is 100 * 5?"
- "Compute 2^8"

---

## 📦 Environment Configuration

Create a `.env` file with the following variables:

```env
# Azure AI Configuration (Required)
AZURE_PROJECT_ENDPOINT=https://your-project.azure.com
MODEL_DEPLOYMENT_NAME=gpt-4o
AZURE_CLIENT_ID=your-client-id
AZURE_TENANT_ID=your-tenant-id
AZURE_CLIENT_SECRET=your-client-secret

# GitHub Configuration (Optional)
GITHUB_TOKEN=your-github-token

# Server Configuration (Optional)
SERVER_HOST=0.0.0.0
SERVER_PORT=8989
SERVICE_NAME=ai-agent-starter
SERVICE_VERSION=1.0.0
```

---

## 🐳 Docker Configuration

### Dockerfile
The project includes a production-ready Dockerfile with:
- Python 3.11 slim base image
- Non-root user for security
- Health check endpoint
- Optimized layer caching

### docker-compose.yaml
Multi-service setup:
- **ai-agent-starter:** FastAPI server (port 8989)
- **postgres:** PostgreSQL database (port 5000)
- **adminer:** Database UI (port 8888)

**Environment Variables:**
All Azure and service configuration passed through `.env` file.

---

## 🧪 Testing the API

### Automated Test Suite
```bash
python test_api.py
```

Tests all endpoints:
- Health check
- Agent status
- Chat with math queries
- Chat with GitHub queries

### Manual Testing with curl

**Health Check:**
```bash
curl http://localhost:8989/health
```

**Agent Status:**
```bash
curl http://localhost:8989/agent_status
```

**Chat:**
```bash
curl -X POST http://localhost:8989/agent_chat \
  -H "Content-Type: application/json" \
  -d '{"session_id": "test-001", "message": "Calculate 50 * 2"}'
```

### Interactive API Documentation
Visit **http://localhost:8989/docs** for:
- Interactive endpoint testing
- Request/response schemas
- Example payloads
- Authentication testing

---

## 📊 Architecture Comparison

### This Implementation (FastAPI)
```
User Request → FastAPI → KeywordOrchestrator → Specialized Agents → Response
```

**Advantages:**
- Full control over API design
- Standard FastAPI patterns
- Production-ready with uvicorn
- Easy to extend with custom endpoints
- Compatible with standard Python ecosystem
- OpenAPI/Swagger documentation automatically generated

### Previous Implementation (azure-ai-agentserver)
```
User Request → azure-ai-agentserver → Unified Agent → Response
```

**Limitations:**
- Beta package with minimal documentation
- Limited control over routing
- Single unified agent (no orchestration)
- Non-standard API patterns

---

## 🛠️ Development Workflow

### Adding New Agents

1. **Create Tool Functions:**
```python
# tools/myagent_tool.py
from typing import Annotated

def my_function(param: Annotated[str, "Parameter description"]) -> str:
    """Function description"""
    return "result"
```

2. **Create Agent:**
```python
# agents/myagent_agent.py
from agent_framework.azure import AzureAIClient
from tools.myagent_tool import my_function

async def create_myagent_agent(client: AzureAIClient):
    agent = await client.create_agent(
        name="MyAgent",
        instructions="Agent instructions...",
        tools=[my_function]
    )
    return agent
```

3. **Update Orchestrator:**
Add routing keywords to `orchestrators/keyword_orchestrator.py`

---

## 🔒 Security Considerations

**Docker:**
- Runs as non-root user (appuser)
- Health checks configured
- Environment variables not baked into image

**API:**
- CORS configured (adjust for production)
- Input validation with Pydantic models
- Error handling and logging

**Authentication:**
- Uses Azure DefaultAzureCredential
- Supports managed identity
- Client secrets in .env (not committed)

---

## 🚀 Deployment

### Local Development
```bash
python main.py
```

### Docker (Development)
```bash
docker-compose up -d
```

### Docker (Production)
```bash
# Build production image
docker build -t drewl/ai-agent-starter:latest -f dockerfile .

# Push to Docker Hub
docker push drewl/ai-agent-starter:latest

# Run from Docker Hub
docker run -d \
  --name ai-agent-starter \
  -p 8989:8989 \
  --env-file .env.production \
  drewl/ai-agent-starter:latest
```

### Azure Container Apps
```bash
az containerapp create \
  --name ai-agent-starter \
  --resource-group your-rg \
  --environment your-env \
  --image drewl/ai-agent-starter:latest \
  --target-port 8989 \
  --ingress external \
  --env-vars-file .env.production
```

---

## 📚 Additional Resources

- **FastAPI Documentation:** https://fastapi.tiangolo.com/
- **Microsoft Agent Framework:** (internal documentation)
- **Docker Documentation:** https://docs.docker.com/
- **Azure Container Apps:** https://learn.microsoft.com/azure/container-apps/

---

## 🤝 Support

For issues or questions:
- Check `/docs` endpoint for interactive API documentation
- Review `test_api.py` for usage examples
- Examine `api/main.py` for implementation details

Built with ❤️ using Microsoft Agent Framework and FastAPI

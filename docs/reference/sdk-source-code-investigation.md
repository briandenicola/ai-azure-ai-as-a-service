# Azure AI Projects SDK Source Code Investigation Guide

This guide helps you verify how `azure-ai-projects` SDK uses the `endpoint` parameter.

## Quick Investigation

### Step 1: Clone the Azure SDK Repository

```bash
git clone https://github.com/Azure/azure-sdk-for-python
cd azure-sdk-for-python
```

### Step 2: Navigate to azure-ai-projects

```bash
cd sdk/ai/azure-ai-projects/azure/ai/projects
```

### Step 3: Key Files to Examine

#### Main Client (`_client.py`)

```bash
# Look for how the client initializes
cat _client.py | grep -A 20 "class AIProjectClient"
cat _client.py | grep "endpoint"
```

**What to look for:**
- Does it store `self._endpoint` or similar?
- Does it pass the endpoint to sub-clients (agents, inference)?

#### Agents Client (`agents/_client.py` or `agents/_operations.py`)

```bash
# Find the agents implementation
find . -name "*agent*" -type f

# Check how URLs are constructed
grep -r "api.azureml.ms" agents/
grep -r "base_url" agents/
grep -r "endpoint" agents/
```

**What to look for:**
- `create_agent`, `create_thread`, `create_run` methods
- How they construct request URLs
- Do they use the parent client's endpoint or construct their own?

#### Inference Client (`inference/_client.py`)

```bash
grep -r "endpoint" inference/
grep -r "url" inference/ | grep -v "http_url"
```

**What to look for:**
- Does `get_chat_completions_client()` honor the endpoint?
- Are there any hardcoded Azure service URLs?

### Step 4: Search for URL Construction Patterns

```bash
# From the azure/ai/projects directory:

# Pattern 1: Hardcoded Azure URLs
grep -r "https://.*azure" . | grep -v ".pyc" | grep -v "__pycache__"

# Pattern 2: URL construction
grep -r "f\"http" . | grep -v ".pyc"
grep -r "format.*http" . | grep -v ".pyc"

# Pattern 3: Discovery endpoint usage
grep -r "discovery" . | grep -v ".pyc"
grep -r "azureml.ms" . | grep -v ".pyc"

# Pattern 4: How endpoint is used
grep -r "self\._endpoint" . | grep -v ".pyc"
grep -r "self\.endpoint" . | grep -v ".pyc"
```

## What Good Behavior Looks Like

### ✅ Endpoint is respected everywhere

```python
# In _client.py
class AIProjectClient:
    def __init__(self, credential, project_id, endpoint):
        self._endpoint = endpoint  # ✅ Stores it
        self._agents_client = AgentsClient(
            credential=credential,
            endpoint=self._endpoint  # ✅ Passes to sub-client
        )

# In agents/_client.py
class AgentsClient:
    def __init__(self, credential, endpoint):
        self._base_url = endpoint  # ✅ Uses provided endpoint
    
    def create_agent(self, ...):
        url = f"{self._base_url}/agents"  # ✅ Uses the provided endpoint
        return self._session.post(url, ...)
```

### ❌ Red Flags to Watch For

```python
# RED FLAG 1: Hardcoded Azure URLs
class AgentsClient:
    BASE_URL = "https://westus.api.azureml.ms"  # ❌ Ignores endpoint!

# RED FLAG 2: Discovery API that might bypass
def _discover_endpoint(self, project_id):
    # Queries Azure directly to find the "real" endpoint
    discovery_url = f"https://{region}.api.azureml.ms/discovery/..."  # ❌
    response = requests.get(discovery_url)
    return response.json()['endpoint']

# RED FLAG 3: Constructor that ignores endpoint
class AgentsClient:
    def __init__(self, credential, project_id):
        # Note: no endpoint parameter!  # ❌
        self._url = self._build_url(project_id)  # Constructs its own
```

## Alternative: Check Package Installation

If you have `azure-ai-projects` installed:

```bash
# Find where it's installed
python -c "import azure.ai.projects; print(azure.ai.projects.__file__)"

# Output example: /usr/local/lib/python3.11/site-packages/azure/ai/projects/__init__.py

# Navigate there
cd /usr/local/lib/python3.11/site-packages/azure/ai/projects

# Investigate
grep -r "endpoint" .
grep -r "api.azureml.ms" .
grep -r "base_url" .
```

## Questions to Answer

### Question 1: Client Initialization
```bash
# Does AIProjectClient store the endpoint?
grep -A 10 "def __init__" _client.py | grep endpoint
```

**Expected:** Something like `self._endpoint = endpoint`

### Question 2: Agents Operations
```bash
# How does create_agent construct URLs?
grep -A 20 "def create_agent" agents/*.py
```

**Expected:** Should use `self._endpoint` or similar, NOT hardcoded URLs

### Question 3: Inference Operations
```bash
# How does inference client use endpoint?
grep -A 20 "get_chat_completions_client" inference/*.py
```

**Expected:** Should pass endpoint parameter through

### Question 4: Thread/Run Operations
```bash
# Do create_thread and create_run use provided endpoint?
grep -A 10 "def create_thread" agents/*.py
grep -A 10 "def create_run" agents/*.py
```

**Expected:** Should construct URLs from provided endpoint

## Report Your Findings

Create an issue or update `docs/reference/sdk-endpoint-verification.md` with your findings:

```markdown
## SDK Investigation Results

**Date:** 2026-03-04
**SDK Version:** [check with `pip show azure-ai-projects`]
**Investigator:** [Your name]

### Findings:

1. **AIProjectClient Initialization:**
   - [ ] ✅ Stores endpoint parameter
   - [ ] ❌ Does not store endpoint
   - Code snippet:
     ```python
     # Paste relevant code here
     ```

2. **AgentsClient URL Construction:**
   - [ ] ✅ Uses provided endpoint
   - [ ] ❌ Constructs own URLs
   - [ ] ⚠️ Uses discovery API
   - Code snippet:
     ```python
     # Paste relevant code here
     ```

3. **Inference Client:**
   - [ ] ✅ Honors endpoint parameter
   - [ ] ❌ Uses hardcoded URLs
   - Code snippet:
     ```python
     # Paste relevant code here
     ```

### Conclusion:

[Based on code review, does the SDK honor endpoint for ALL operations?]

### Recommendation:

[Keep using endpoint parameter / Add network enforcement / Contact Microsoft]
```

## Contact Microsoft

If code review is unclear, open a GitHub issue:

```bash
# Open issue on Azure SDK repo
# Go to: https://github.com/Azure/azure-sdk-for-python/issues/new

**Title:** AIProjectClient endpoint parameter behavior clarification

**Body:**
We are using AIProjectClient with a custom endpoint (Azure API Management gateway) 
for governance and cost control:

```python
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    endpoint="https://our-apim.azure-api.net",  # Custom APIM gateway
    project_id="our-project"
)
```

**Questions:**

1. Does the SDK honor this endpoint for ALL operations (create_agent, create_thread, 
   create_run, list_messages, inference calls, etc.)?

2. Are there any operations that construct Azure-specific URLs internally 
   (like *.api.azureml.ms) that would bypass the custom endpoint?

3. Is there official documentation showing custom endpoints with AIProjectClient?

**Use case:** Enterprise architecture requiring all AI traffic through APIM gateway 
for token quotas, semantic caching, and audit logging.

**Critical:** If any operations bypass the endpoint parameter, our governance controls fail.
```

## Summary

**Before production deployment:**

1. ✅ Clone Azure SDK repo and review source code
2. ✅ Check for hardcoded URLs or discovery APIs
3. ✅ Verify all operations use provided endpoint
4. ✅ Test with traffic capture (mitmproxy)
5. ✅ Deploy with `publicNetworkAccess: Disabled` as backup
6. ✅ Contact Microsoft if unclear
7. ✅ Document findings for your team

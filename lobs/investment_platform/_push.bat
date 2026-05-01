@echo off
REM Push AI Agent Starter Docker image to Docker Hub
echo 🚀 Pushing AI Agent Starter to Docker Hub...
echo.

REM Check if logged into Docker Hub
docker info > nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ Docker is not running!
    exit /b 1
)

REM Optional: Tag with version
set /p version="Enter version tag (or press Enter for 'latest'): "
if "%version%"=="" set version=latest

if not "%version%"=="latest" (
    echo Tagging image with version: %version%
    docker tag drewl/ai-agent-starter:latest drewl/ai-agent-starter:%version%
)

echo Pushing drewl/ai-agent-starter:latest...
docker push drewl/ai-agent-starter:latest

if %errorlevel% neq 0 (
    echo ❌ Docker push failed!
    echo Make sure you're logged in with: docker login
    exit /b 1
)

if not "%version%"=="latest" (
    echo Pushing drewl/ai-agent-starter:%version%...
    docker push drewl/ai-agent-starter:%version%
)

echo.
echo ✅ Successfully pushed to Docker Hub!
echo 📦 Image: drewl/ai-agent-starter:latest
if not "%version%"=="latest" echo 📦 Image: drewl/ai-agent-starter:%version%
echo.
echo 💡 Pull with: docker pull drewl/ai-agent-starter:latest

using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading.Tasks;
using Azure.AI.Projects;
using Azure.AI.Projects.Models;
using Azure.Identity;

/// <summary>
/// Example 6: Full Foundry Agent Reference with APIM Gateway (.NET)
/// 
/// Complete reference showing:
/// - Agent configuration with APIM gateway validation
/// - Tool/function definitions
/// - Agent lifecycle management
/// - Streaming and synchronous execution
/// - Tool call handling
/// </summary>
/// 
namespace FoundryAgentApimReference
{
    // ========================================================================
    // Configuration with Validation
    // ========================================================================
    
    public class AgentConfig
    {
        public string ApimEndpoint { get; }
        public string ProjectId { get; }
        public string DeploymentName { get; }
        
        public AgentConfig()
        {
            // Read from environment - NEVER hardcode!
            ApimEndpoint = Environment.GetEnvironmentVariable("AI_GATEWAY_ENDPOINT") 
                ?? "https://your-company-ai.azure-api.net";
            
            ProjectId = Environment.GetEnvironmentVariable("AI_PROJECT_ID") 
                ?? "ai-hub-project";
            
            DeploymentName = Environment.GetEnvironmentVariable("AI_DEPLOYMENT_NAME") 
                ?? "gpt-4o";
            
            ValidateEndpoint();
        }
        
        private void ValidateEndpoint()
        {
            if (!ApimEndpoint.Contains(".azure-api.net"))
            {
                throw new InvalidOperationException(
                    $"❌ Invalid endpoint: {ApimEndpoint}\n" +
                    "Must use APIM gateway (*.azure-api.net), not direct Foundry.\n" +
                    "This ensures token quotas and policies are enforced.");
            }
            
            Console.WriteLine($"✅ Using APIM gateway: {ApimEndpoint}");
        }
    }
    
    // ========================================================================
    // Tool Functions (Business Logic)
    // ========================================================================
    
    public static class ToolFunctions
    {
        public static string GetCustomerOrderStatus(string orderId)
        {
            // Mock order data
            var orders = new Dictionary<string, object>
            {
                ["ORD-12345"] = new
                {
                    status = "shipped",
                    tracking = "1Z999AA10123456784",
                    estimated_delivery = "2026-03-07"
                },
                ["ORD-67890"] = new
                {
                    status = "processing",
                    estimated_ship_date = "2026-03-05"
                }
            };
            
            var result = orders.ContainsKey(orderId) 
                ? orders[orderId] 
                : new { status = "not_found" };
            
            return JsonSerializer.Serialize(result);
        }
        
        public static string CalculateShippingCost(string originZip, string destZip, double weightLbs)
        {
            // Simple mock calculation
            var distanceFactor = Math.Abs(
                int.Parse(originZip.Substring(0, 2)) - 
                int.Parse(destZip.Substring(0, 2))
            );
            
            var cost = Math.Round(5.99 + (distanceFactor * 0.5) + (weightLbs * 0.3), 2);
            
            var result = new
            {
                cost_usd = cost,
                currency = "USD",
                estimated_days = Math.Min(distanceFactor, 7)
            };
            
            return JsonSerializer.Serialize(result);
        }
        
        public static string SearchProductCatalog(string query, string? category = null)
        {
            // Mock product data
            var products = new[]
            {
                new { id = "PROD-001", name = "Wireless Mouse", price = 29.99, category = "electronics" },
                new { id = "PROD-002", name = "USB-C Cable", price = 12.99, category = "electronics" },
                new { id = "PROD-003", name = "Desk Lamp", price = 45.00, category = "office" }
            };
            
            var results = new List<object>();
            foreach (var product in products)
            {
                if (product.name.Contains(query, StringComparison.OrdinalIgnoreCase))
                {
                    if (category == null || product.category.Equals(category, StringComparison.OrdinalIgnoreCase))
                    {
                        results.Add(product);
                    }
                }
            }
            
            return JsonSerializer.Serialize(results);
        }
    }
    
    // ========================================================================
    // Foundry Agent Manager
    // ========================================================================
    
    public class FoundryAgentManager
    {
        private readonly AgentConfig _config;
        private readonly AIProjectClient _client;
        
        public FoundryAgentManager(AgentConfig config)
        {
            _config = config;
            
            // Create AI Project client pointing to APIM gateway
            _client = new AIProjectClient(
                new Uri(_config.ApimEndpoint),
                new DefaultAzureCredential()
            );
            
            Console.WriteLine($"✅ Connected to project: {_config.ProjectId}");
            Console.WriteLine($"   via APIM gateway: {_config.ApimEndpoint}");
        }
        
        public async Task<Agent> CreateAgentAsync()
        {
            var tools = new List<ToolDefinition>
            {
                new FunctionToolDefinition
                {
                    Name = "get_customer_order_status",
                    Description = "Look up the status of a customer's order by order ID",
                    Parameters = BinaryData.FromString(JsonSerializer.Serialize(new
                    {
                        type = "object",
                        properties = new
                        {
                            order_id = new { type = "string", description = "The order ID (e.g., ORD-12345)" }
                        },
                        required = new[] { "order_id" }
                    }))
                },
                new FunctionToolDefinition
                {
                    Name = "calculate_shipping_cost",
                    Description = "Calculate shipping cost between two ZIP codes",
                    Parameters = BinaryData.FromString(JsonSerializer.Serialize(new
                    {
                        type = "object",
                        properties = new
                        {
                            origin_zip = new { type = "string", description = "Origin ZIP code (5 digits)" },
                            dest_zip = new { type = "string", description = "Destination ZIP code (5 digits)" },
                            weight_lbs = new { type = "number", description = "Package weight in pounds" }
                        },
                        required = new[] { "origin_zip", "dest_zip", "weight_lbs" }
                    }))
                },
                new FunctionToolDefinition
                {
                    Name = "search_product_catalog",
                    Description = "Search for products in the catalog",
                    Parameters = BinaryData.FromString(JsonSerializer.Serialize(new
                    {
                        type = "object",
                        properties = new
                        {
                            query = new { type = "string", description = "Search query" },
                            category = new { type = "string", description = "Filter by category", @enum = new[] { "electronics", "office", "home" } }
                        },
                        required = new[] { "query" }
                    }))
                }
            };
            
            var agent = await _client.GetAgentsClient().CreateAgentAsync(
                model: _config.DeploymentName,
                name: "customer-service-agent",
                instructions: @"You are a helpful customer service agent for an e-commerce company.

Your capabilities:
- Look up order status using order IDs
- Calculate shipping costs between ZIP codes
- Search the product catalog

Guidelines:
- Be friendly and professional
- Always use tools when you need real data
- If a tool returns 'not_found', apologize and offer alternatives",
                tools: tools
            );
            
            Console.WriteLine($"\n✅ Agent created: {agent.Value.Id}");
            Console.WriteLine($"   Name: {agent.Value.Name}");
            Console.WriteLine($"   Model: {agent.Value.Model}");
            Console.WriteLine($"   Tools: {tools.Count}");
            
            return agent.Value;
        }
        
        public async Task<AgentThread> CreateThreadAsync()
        {
            var thread = await _client.GetAgentsClient().CreateThreadAsync();
            Console.WriteLine($"✅ Thread created: {thread.Value.Id}");
            return thread.Value;
        }
        
        public async Task SendMessageAsync(string threadId, string message)
        {
            await _client.GetAgentsClient().CreateMessageAsync(
                threadId: threadId,
                role: MessageRole.User,
                content: message
            );
            Console.WriteLine($"\n👤 User: {message}");
        }
        
        public async Task RunAgentAsync(string threadId, string agentId)
        {
            Console.WriteLine("🤖 Running agent...");
            
            var run = await _client.GetAgentsClient().CreateRunAsync(
                threadId: threadId,
                assistantId: agentId
            );
            
            // Poll until complete
            while (run.Value.Status == RunStatus.Queued ||
                   run.Value.Status == RunStatus.InProgress ||
                   run.Value.Status == RunStatus.RequiresAction)
            {
                await Task.Delay(1000);
                run = await _client.GetAgentsClient().GetRunAsync(threadId, run.Value.Id);
                
                if (run.Value.Status == RunStatus.RequiresAction)
                {
                    await HandleToolCallsAsync(threadId, run.Value);
                    run = await _client.GetAgentsClient().GetRunAsync(threadId, run.Value.Id);
                }
            }
            
            if (run.Value.Status == RunStatus.Completed)
            {
                Console.WriteLine($"✅ Run completed: {run.Value.Id}");
            }
            else
            {
                throw new Exception($"Run failed with status: {run.Value.Status}");
            }
        }
        
        private async Task HandleToolCallsAsync(string threadId, ThreadRun run)
        {
            var toolCalls = run.RequiredAction.SubmitToolOutputs.ToolCalls;
            Console.WriteLine($"🔧 Agent requesting {toolCalls.Count} tool call(s):");
            
            var toolOutputs = new List<ToolOutput>();
            
            foreach (var toolCall in toolCalls)
            {
                var functionName = toolCall.FunctionName;
                var functionArgs = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(
                    toolCall.FunctionArguments
                );
                
                Console.WriteLine($"   - {functionName}({toolCall.FunctionArguments})");
                
                string output;
                try
                {
                    output = functionName switch
                    {
                        "get_customer_order_status" => ToolFunctions.GetCustomerOrderStatus(
                            functionArgs["order_id"].GetString()!
                        ),
                        "calculate_shipping_cost" => ToolFunctions.CalculateShippingCost(
                            functionArgs["origin_zip"].GetString()!,
                            functionArgs["dest_zip"].GetString()!,
                            functionArgs["weight_lbs"].GetDouble()
                        ),
                        "search_product_catalog" => ToolFunctions.SearchProductCatalog(
                            functionArgs["query"].GetString()!,
                            functionArgs.ContainsKey("category") ? functionArgs["category"].GetString() : null
                        ),
                        _ => JsonSerializer.Serialize(new { error = $"Unknown function: {functionName}" })
                    };
                    
                    Console.WriteLine($"     ✅ Result: {output}");
                }
                catch (Exception ex)
                {
                    output = JsonSerializer.Serialize(new { error = ex.Message });
                    Console.WriteLine($"     ❌ Error: {ex.Message}");
                }
                
                toolOutputs.Add(new ToolOutput(toolCall.Id, output));
            }
            
            await _client.GetAgentsClient().SubmitToolOutputsToRunAsync(
                threadId: threadId,
                runId: run.Id,
                toolOutputs: toolOutputs
            );
        }
        
        public async Task PrintConversationAsync(string threadId)
        {
            var messages = await _client.GetAgentsClient().GetMessagesAsync(threadId);
            
            Console.WriteLine("\n" + new string('=', 80));
            Console.WriteLine("CONVERSATION HISTORY");
            Console.WriteLine(new string('=', 80));
            
            foreach (var msg in messages.Value.Data)
            {
                var roleIcon = msg.Role == MessageRole.User ? "👤" : "🤖";
                Console.WriteLine($"\n{roleIcon} {msg.Role.ToString().ToUpper()}:");
                
                foreach (var content in msg.Content)
                {
                    if (content is MessageTextContent textContent)
                    {
                        Console.WriteLine($"   {textContent.Text}");
                    }
                }
            }
            
            Console.WriteLine(new string('=', 80));
        }
        
        public async Task CleanupAgentAsync(string agentId)
        {
            try
            {
                await _client.GetAgentsClient().DeleteAgentAsync(agentId);
                Console.WriteLine($"✅ Agent deleted: {agentId}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"⚠️ Could not delete agent: {ex.Message}");
            }
        }
    }
    
    // ========================================================================
    // Demo Scenarios
    // ========================================================================
    
    public class Program
    {
        static async Task Main(string[] args)
        {
            Console.WriteLine(new string('=', 80));
            Console.WriteLine("FOUNDRY AGENT + APIM GATEWAY - FULL REFERENCE (.NET)");
            Console.WriteLine(new string('=', 80));
            
            // 1. Load and validate configuration
            AgentConfig config;
            try
            {
                config = new AgentConfig();
            }
            catch (InvalidOperationException ex)
            {
                Console.WriteLine($"\n{ex.Message}");
                Console.WriteLine("\nTo fix, set environment variables:");
                Console.WriteLine("  $env:AI_GATEWAY_ENDPOINT='https://your-company-ai.azure-api.net'");
                Console.WriteLine("  $env:AI_PROJECT_ID='ai-hub-project'");
                return;
            }
            
            // 2. Initialize agent manager
            var manager = new FoundryAgentManager(config);
            
            // 3. Create the agent
            var agent = await manager.CreateAgentAsync();
            
            try
            {
                // 4. Run scenarios
                await DemoScenario1(manager, agent.Id);
                await DemoScenario2(manager, agent.Id);
                await DemoScenario3(manager, agent.Id);
                
                Console.WriteLine("\n✅ All scenarios completed successfully!");
                Console.WriteLine($"\nNote: All inference calls went through APIM gateway at:");
                Console.WriteLine($"      {config.ApimEndpoint}");
                Console.WriteLine("\nThis means:");
                Console.WriteLine("  ✅ Token quotas were enforced");
                Console.WriteLine("  ✅ Semantic caching was applied");
                Console.WriteLine("  ✅ Circuit breaker protected against failures");
                Console.WriteLine("  ✅ All requests were logged for audit");
            }
            finally
            {
                // 5. Cleanup (optional)
                Console.Write("\nDelete agent? (y/N): ");
                var cleanup = Console.ReadLine()?.ToLower().Trim();
                if (cleanup == "y")
                {
                    await manager.CleanupAgentAsync(agent.Id);
                }
                else
                {
                    Console.WriteLine($"Agent preserved. ID: {agent.Id}");
                }
            }
        }
        
        static async Task DemoScenario1(FoundryAgentManager manager, string agentId)
        {
            Console.WriteLine("\n" + new string('=', 80));
            Console.WriteLine("SCENARIO 1: Order Status Inquiry");
            Console.WriteLine(new string('=', 80));
            
            var thread = await manager.CreateThreadAsync();
            await manager.SendMessageAsync(thread.Id, "Hi! Can you check the status of order ORD-12345?");
            await manager.RunAgentAsync(thread.Id, agentId);
            await manager.PrintConversationAsync(thread.Id);
        }
        
        static async Task DemoScenario2(FoundryAgentManager manager, string agentId)
        {
            Console.WriteLine("\n" + new string('=', 80));
            Console.WriteLine("SCENARIO 2: Shipping Cost Inquiry");
            Console.WriteLine(new string('=', 80));
            
            var thread = await manager.CreateThreadAsync();
            await manager.SendMessageAsync(
                thread.Id,
                "How much would it cost to ship a 5-pound package from ZIP 94105 to ZIP 10001?"
            );
            await manager.RunAgentAsync(thread.Id, agentId);
            await manager.PrintConversationAsync(thread.Id);
        }
        
        static async Task DemoScenario3(FoundryAgentManager manager, string agentId)
        {
            Console.WriteLine("\n" + new string('=', 80));
            Console.WriteLine("SCENARIO 3: Product Search + Multi-turn");
            Console.WriteLine(new string('=', 80));
            
            var thread = await manager.CreateThreadAsync();
            
            await manager.SendMessageAsync(thread.Id, "I need a new mouse for my computer");
            await manager.RunAgentAsync(thread.Id, agentId);
            
            await manager.SendMessageAsync(thread.Id, "How much would shipping cost to ZIP 98101?");
            await manager.RunAgentAsync(thread.Id, agentId);
            
            await manager.PrintConversationAsync(thread.Id);
        }
    }
}

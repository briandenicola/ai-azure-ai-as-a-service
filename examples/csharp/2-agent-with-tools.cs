using Azure.AI.Projects;
using Azure.AI.Inference;
using Azure.Identity;
using Microsoft.Agents.AI;
using System.Text.Json;

/// <summary>
/// Example 2: Agent with Tools (.NET)
/// 
/// Create an agent that can call functions.
/// Tools are defined using OpenAPI/JSON schema.
/// </summary>

class AgentWithToolsExample
{
    private const string ProjectId = "my-hub-project";
    // Read from environment - don't hardcode!
    private static readonly string ApimGatewayUrl = 
        Environment.GetEnvironmentVariable("AI_GATEWAY_ENDPOINT") 
        ?? "https://your-company-ai.azure-api.net";

    static async Task Main(string[] args)
    {
        // Validate endpoint is APIM, not direct Foundry
        if (!ApimGatewayUrl.Contains(".azure-api.net"))
        {
            throw new InvalidOperationException(
                $"Invalid endpoint: {ApimGatewayUrl}. " +
                "Must use APIM gateway (*.azure-api.net), not direct Foundry endpoint.");
        }
        
        var client = new AIProjectClient(new Uri(ApimGatewayUrl), new DefaultAzureCredential());
        
        await CreateAndRunAgentAsync(client);
    }

    static async Task CreateAndRunAgentAsync(AIProjectClient client)
    {
        var agentsClient = client.GetAgentsClient();

        // 1. Define tools for the agent
        var tools = new List<ToolDefinition>
        {
            new FunctionToolDefinition
            {
                Function = new FunctionDefinition
                {
                    Name = "get_weather",
                    Description = "Get the current weather for a location",
                    Parameters = new BinaryData(JsonSerializer.Serialize(new
                    {
                        type = "object",
                        properties = new
                        {
                            location = new { type = "string", description = "City name" },
                            unit = new { type = "string", @enum = new[] { "celsius", "fahrenheit" } }
                        },
                        required = new[] { "location" }
                    }))
                }
            },
            new FunctionToolDefinition
            {
                Function = new FunctionDefinition
                {
                    Name = "get_flight_price",
                    Description = "Check flight price from origin to destination",
                    Parameters = new BinaryData(JsonSerializer.Serialize(new
                    {
                        type = "object",
                        properties = new
                        {
                            origin = new { type = "string", description = "Airport code" },
                            destination = new { type = "string", description = "Airport code" },
                            date = new { type = "string", description = "Travel date (YYYY-MM-DD)" }
                        },
                        required = new[] { "origin", "destination", "date" }
                    }))
                }
            }
        };

        // 2. Create the agent
        var agent = await agentsClient.CreateAgentAsync(
            model: "gpt-4o",
            name: "travel-assistant",
            instructions: "Help users plan travel. Use available tools to check weather and flights.",
            tools: tools
        );

        Console.WriteLine($"✓ Agent created: {agent.Id}");
        Console.WriteLine($"  Name: {agent.Name}");
        Console.WriteLine($"  Model: {agent.Model}");

        // 3. Create a thread for conversation
        var thread = await agentsClient.CreateThreadAsync();
        Console.WriteLine($"\n✓ Thread created: {thread.Id}");

        // 4. Send a user message
        var userQuestion = "What's the weather in London? How much for a flight from NYC to London on March 15?";
        Console.WriteLine($"\nUser: {userQuestion}");

        var message = await agentsClient.CreateMessageAsync(
            threadId: thread.Id,
            role: MessageRole.User,
            content: userQuestion
        );

        // 5. Run the agent
        var run = await agentsClient.CreateRunAsync(
            threadId: thread.Id,
            assistantId: agent.Id
        );

        Console.WriteLine($"\nAgent is processing...");

        // 6. Handle tool calls
        int maxIterations = 10;
        int iteration = 0;

        while ((run.Status == RunStatus.QueQueued || run.Status == RunStatus.InProgress || run.Status == RunStatus.RequiresAction) && iteration < maxIterations)
        {
            iteration++;
            await Task.Delay(1000); // Wait before checking status

            run = await agentsClient.GetRunAsync(threadId: thread.Id, runId: run.Id);

            if (run.Status == RunStatus.RequiresAction)
            {
                Console.WriteLine($"\nAgent needs to call tools...");

                var toolOutputs = new List<ToolOutput>();

                foreach (var toolCall in run.RequiredAction.SubmitToolOutputs.ToolCalls)
                {
                    var toolName = toolCall.Function.Name;
                    Console.WriteLine($"  → Calling {toolName}");

                    // Simulate tool results
                    string result = toolName switch
                    {
                        "get_weather" => "Sunny, 15°C in London",
                        "get_flight_price" => "$450 for NYC → London on March 15",
                        _ => "Unknown tool"
                    };

                    Console.WriteLine($"    ← {result}");

                    toolOutputs.Add(new ToolOutput
                    {
                        ToolCallId = toolCall.Id,
                        Output = result
                    });
                }

                // Submit tool results
                run = await agentsClient.SubmitToolOutputsAsync(
                    threadId: thread.Id,
                    runId: run.Id,
                    toolOutputs: toolOutputs
                );
            }
        }

        // 7. Get final response
        if (run.Status == RunStatus.Completed)
        {
            var messages = await agentsClient.GetMessagesAsync(thread.Id);

            Console.WriteLine($"\nAgent Response:");
            foreach (var msg in messages.Value)
            {
                if (msg.Role == MessageRole.Assistant)
                {
                    Console.WriteLine($"  {msg.Content[0].Text}");
                }
            }
        }
        else
        {
            Console.WriteLine($"Run ended with status: {run.Status}");
        }

        Console.WriteLine("\n" + new string('=', 60));
        Console.WriteLine("What happened behind the scenes:");
        Console.WriteLine(new string('=', 60));
        Console.WriteLine("1. Your agent ran through APIM (Azure API Management)");
        Console.WriteLine("2. Every request was logged for audit");
        Console.WriteLine("3. Token count was tracked for chargeback");
        Console.WriteLine("4. Response was cached for future queries");
        Console.WriteLine("5. All passed through your company's policies");
    }
}

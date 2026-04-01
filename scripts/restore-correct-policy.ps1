$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

# Restore the correct policy (forward-request + choose pattern — no <retry> element)
$correctPolicy = @"
<policies>
	<inbound>
		<base />
		<set-variable name="selectedBackend" value="primary" />
		<set-backend-service base-url="{{foundry-primary-endpoint}}/openai" />
	</inbound>
	<backend>
		<!-- Step 1: Forward to primary Foundry endpoint. -->
		<forward-request timeout="60" />
		<!-- Step 2: If primary returned 429 or 5xx, switch to secondary and retry once.
         context.Response is always set after forward-request, so this choose
         evaluates correctly without any null-guard complexity. -->
		<choose>
			<when condition="@(context.Response.StatusCode == 429 || context.Response.StatusCode >= 500)">
				<set-backend-service base-url="{{foundry-secondary-endpoint}}/openai" />
				<set-variable name="selectedBackend" value="secondary-failover" />
				<forward-request timeout="60" />
			</when>
		</choose>
	</backend>
	<outbound>
		<base />
		<set-header name="X-Backend-Region-Used" exists-action="override">
			<value>@(context.Variables.GetValueOrDefault("selectedBackend", "primary"))</value>
		</set-header>
	</outbound>
	<on-error>
		<base />
		<!-- GetValueOrDefault prevents KeyNotFoundException when auth fails before
         inbound sets selectedBackend - without this, missing/invalid subscription
         keys escalate to 500 instead of returning the correct 401. -->
		<set-header name="X-Backend-Region-Used" exists-action="override">
			<value>@(context.Variables.GetValueOrDefault("selectedBackend", "unknown"))</value>
		</set-header>
	</on-error>
</policies>
"@

$body = @{
    properties = @{
        format = "rawxml"
        value = $correctPolicy
    }
} | ConvertTo-Json -Depth 5

Write-Host "Restoring forward-request + choose policy..."
$r = Invoke-RestMethod -Method Put -Uri "$base/apis/openai-inference/policies/policy?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"; "Content-Type"="application/json"} -Body $body
Write-Host "Policy restored."

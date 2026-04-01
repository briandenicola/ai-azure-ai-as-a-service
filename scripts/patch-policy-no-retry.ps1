$t = az account get-access-token --query accessToken -o tsv
$base = "https://management.azure.com/subscriptions/d201ebeb-c470-4a6f-82d5-c2f95bb0dc1e/resourceGroups/rg-contoso-ai-platform-dev/providers/Microsoft.ApiManagement/service/apim-contoso-vdls2xyq"

$noRetryPolicy = @"
<policies>
	<inbound>
		<base />
		<set-variable name="selectedBackend" value="primary" />
		<set-backend-service base-url="{{foundry-primary-endpoint}}/openai" />
	</inbound>
	<backend>
		<forward-request timeout="30" />
	</backend>
	<outbound>
		<base />
		<set-header name="X-Backend-Region-Used" exists-action="override">
			<value>@(context.Variables.GetValueOrDefault("selectedBackend", "primary"))</value>
		</set-header>
		<set-header name="X-Primary-Status" exists-action="override">
			<value>@(context.Response.StatusCode.ToString())</value>
		</set-header>
	</outbound>
	<on-error>
		<base />
		<set-header name="X-Backend-Region-Used" exists-action="override">
			<value>@(context.Variables.GetValueOrDefault("selectedBackend", "unknown"))</value>
		</set-header>
	</on-error>
</policies>
"@

$body = @{
    properties = @{
        format = "rawxml"
        value = $noRetryPolicy
    }
} | ConvertTo-Json -Depth 5

Write-Host "Patching API policy (no retry, direct to primary)..."
$r = Invoke-RestMethod -Method Put -Uri "$base/apis/openai-inference/policies/policy?api-version=2023-05-01-preview" -Headers @{Authorization="Bearer $t"; "Content-Type"="application/json"} -Body $body
Write-Host "Done. Policy updated."

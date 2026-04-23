"""
ServiceNow Bootstrap — Azure AI as a Service integration setup.

Provisions everything required via the ServiceNow REST API.
Safe to re-run: all operations are idempotent (skip if already exists).

What this creates:
  1. Custom tables
       u_ai_model_requests   — model access approval requests
       u_ai_quota_requests   — token quota increase requests
       u_ai_tool_requests    — AI agent tool integration requests
  2. "AI Governance" assignment group
  3. Inbound Scripted REST API  — receives subscription lifecycle events from Azure
  4. Outbound REST Message      — calls Azure Function App on ticket approval

Prerequisites:
  pip install requests

Usage (flags):
  python bootstrap.py \\
    --instance https://dev389009.service-now.com \\
    --username admin \\
    --password <password> \\
    --function-app-url https://<func>.azurewebsites.net/api/apim-subscription-handler \\
    --function-app-key <host-key>

Usage (environment variables):
  SN_INSTANCE          ServiceNow instance URL
  SN_USERNAME          Admin username
  SN_PASSWORD          Admin password
  AZURE_FUNCTION_URL   Azure Function App trigger URL
  AZURE_FUNCTION_KEY   Azure Function App host key
"""

import argparse
import os
import sys
import time
from typing import Any

import requests

# ---------------------------------------------------------------------------
# Custom table definitions
# Each table extends 'task' (base ServiceNow table) to inherit approval,
# state, assignment, and work notes fields automatically.
# ---------------------------------------------------------------------------

CUSTOM_TABLES: list[dict] = [
    {
        "name": "u_ai_model_requests",
        "label": "AI Model Request",
        "plural_label": "AI Model Requests",
        "columns": [
            {"column_label": "Requester",             "element": "u_requester",                "internal_type": "string",          "max_length": 255},
            {"column_label": "Model Name",            "element": "u_model_name",               "internal_type": "string",          "max_length": 100},
            {"column_label": "Use Case",              "element": "u_use_case",                 "internal_type": "string",          "max_length": 1000},
            {"column_label": "Line of Business",      "element": "u_line_of_business",         "internal_type": "string",          "max_length": 100},
            {"column_label": "Project Name",          "element": "u_project_name",             "internal_type": "string",          "max_length": 255},
            {"column_label": "Est. Monthly Tokens",   "element": "u_estimated_monthly_tokens", "internal_type": "integer",         "max_length": 40},
            # password2 = encrypted at rest, never shown in plain text
            {"column_label": "APIM Subscription Key", "element": "u_apim_subscription_key",    "internal_type": "password2",       "max_length": 255},
        ],
    },
    {
        "name": "u_ai_quota_requests",
        "label": "AI Quota Request",
        "plural_label": "AI Quota Requests",
        "columns": [
            {"column_label": "APIM Subscription ID",        "element": "u_subscription_id",                "internal_type": "string",          "max_length": 255},
            {"column_label": "Line of Business",            "element": "u_line_of_business",               "internal_type": "string",          "max_length": 100},
            {"column_label": "Current Quota (tokens/hr)",   "element": "u_current_quota_tokens",           "internal_type": "integer",         "max_length": 40},
            {"column_label": "Requested Quota (tokens/hr)", "element": "u_requested_quota_tokens",         "internal_type": "integer",         "max_length": 40},
            {"column_label": "Increase Amount",             "element": "u_increase_amount",                "internal_type": "integer",         "max_length": 40},
            {"column_label": "Est. Monthly Cost Increase",  "element": "u_estimated_monthly_cost_increase","internal_type": "decimal",         "max_length": 40},
            {"column_label": "Justification",               "element": "u_justification",                  "internal_type": "string",          "max_length": 1000},
            {"column_label": "Submitted Date",              "element": "u_submitted_date",                 "internal_type": "glide_date_time", "max_length": 40},
        ],
    },
    {
        "name": "u_ai_tool_requests",
        "label": "AI Tool Integration Request",
        "plural_label": "AI Tool Integration Requests",
        "columns": [
            {"column_label": "Requester",            "element": "u_requester",               "internal_type": "string",  "max_length": 255},
            {"column_label": "Tool Name",            "element": "u_tool_name",               "internal_type": "string",  "max_length": 255},
            {"column_label": "Tool Type",            "element": "u_tool_type",               "internal_type": "string",  "max_length": 100},
            {"column_label": "Tool Endpoint",        "element": "u_tool_endpoint",           "internal_type": "url",     "max_length": 1024},
            {"column_label": "Data Classification",  "element": "u_data_classification",    "internal_type": "string",  "max_length": 100},
            {"column_label": "Use Case",             "element": "u_use_case",               "internal_type": "string",  "max_length": 1000},
            {"column_label": "Required Permissions", "element": "u_required_permissions",   "internal_type": "string",  "max_length": 1000},
            {"column_label": "Project Name",         "element": "u_project_name",           "internal_type": "string",  "max_length": 255},
            {"column_label": "Line of Business",     "element": "u_line_of_business",       "internal_type": "string",  "max_length": 100},
            {"column_label": "Security Review Reqd", "element": "u_security_review_required","internal_type": "boolean", "max_length": 40},
        ],
    },
]

# ---------------------------------------------------------------------------
# Inbound Scripted REST API
# Azure Function App POSTs subscription lifecycle events here.
# Path: POST /api/x_<scope>/azure_ai_service_events/subscription
# ---------------------------------------------------------------------------

INBOUND_API_ROOT = "azure_ai_service_events"
INBOUND_API_NAME = "AzureAIServiceEvents"

INBOUND_SCRIPT = r"""
(function process(/*RESTAPIRequest*/ request, /*RESTAPIResponse*/ response) {
    var body = request.body.data;

    if (!body || !body.event_type) {
        response.setStatus(400);
        response.setBody({ error: "Missing event_type in request body" });
        return;
    }

    var tableName = "";
    var payload   = {};

    if (body.event_type === "subscription.created" || body.event_type === "subscription.updated") {
        tableName = "u_ai_model_requests";
        payload = {
            u_requester:              body.developer_email  || "",
            u_line_of_business:       body.lob              || "",
            u_project_name:           body.subscription_name || "",
            u_apim_subscription_key:  body.subscription_key || "",
            short_description:        "APIM subscription event: " + body.event_type,
            state:                    "1"
        };
    } else if (body.event_type === "quota.increase_requested") {
        tableName = "u_ai_quota_requests";
        payload = {
            u_subscription_id:       body.subscription_id  || "",
            u_line_of_business:      body.lob              || "",
            u_current_quota_tokens:  body.current_quota    || 0,
            u_requested_quota_tokens: body.requested_quota || 0,
            u_justification:         body.justification    || "",
            short_description:       "Quota increase: " + (body.subscription_id || ""),
            state:                   "1"
        };
    } else {
        response.setStatus(400);
        response.setBody({ error: "Unknown event_type: " + body.event_type });
        return;
    }

    var gr = new GlideRecord(tableName);
    gr.initialize();
    for (var field in payload) {
        gr.setValue(field, payload[field]);
    }
    var sysId = gr.insert();

    response.setStatus(201);
    response.setBody({ sys_id: sysId, table: tableName });
})(request, response);
"""

# ---------------------------------------------------------------------------
# Outbound REST Message
# ServiceNow calls this after a ticket is approved, triggering Azure Function
# App to provision the APIM subscription / update quota.
# ---------------------------------------------------------------------------

OUTBOUND_MSG_NAME = "AzureFunctionApp_APIMHandler"


# ---------------------------------------------------------------------------
# Bootstrap client
# ---------------------------------------------------------------------------

class ServiceNowBootstrap:

    def __init__(self, instance_url: str, username: str, password: str) -> None:
        self.base = instance_url.rstrip("/")
        self.auth = (username, password)
        self.headers = {"Content-Type": "application/json", "Accept": "application/json"}
        self._errors: list[str] = []

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _post(self, table: str, payload: dict) -> dict[str, Any] | None:
        r = requests.post(
            f"{self.base}/api/now/table/{table}",
            auth=self.auth, headers=self.headers, json=payload, timeout=30,
        )
        if r.status_code in (200, 201):
            return r.json().get("result", {})
        if r.status_code == 409:
            # Record already exists — idempotent
            return {}
        self._errors.append(f"POST {table} → HTTP {r.status_code}: {r.text[:300]}")
        return None

    def _get_sys_id(self, table: str, field: str, value: str) -> str | None:
        r = requests.get(
            f"{self.base}/api/now/table/{table}",
            auth=self.auth, headers=self.headers, timeout=30,
            params={
                "sysparm_query": f"{field}={value}",
                "sysparm_fields": "sys_id",
                "sysparm_limit": 1,
            },
        )
        if r.status_code == 200:
            results = r.json().get("result", [])
            return results[0]["sys_id"] if results else None
        return None

    # ------------------------------------------------------------------
    # Step 1 — Custom tables
    # ------------------------------------------------------------------

    def create_tables(self) -> None:
        print("\n[1/5] Creating custom tables...")

        for table in CUSTOM_TABLES:
            if self._get_sys_id("sys_db_object", "name", table["name"]):
                print(f"  ✅ Already exists: {table['name']}")
                continue

            result = self._post("sys_db_object", {
                "name":          table["name"],
                "label":         table["label"],
                "plural":        table["plural_label"],
                "is_extendable": "false",
                "access":        "public",
            })
            if result is None:
                print(f"  ❌ Failed to create: {table['name']}")
                continue

            print(f"  ✅ Created table: {table['name']}")
            # Wait for DDL to commit before inserting column records
            time.sleep(2)

            for col in table["columns"]:
                self._post("sys_dictionary", {
                    "name":          table["name"],
                    "column_label":  col["column_label"],
                    "element":       col["element"],
                    "internal_type": {"value": col["internal_type"]},
                    "max_length":    col.get("max_length", 255),
                    "active":        "true",
                    "mandatory":     "false",
                })
            print(f"       → {len(table['columns'])} columns added")

    # ------------------------------------------------------------------
    # Step 2 — Assignment group
    # ------------------------------------------------------------------

    def create_assignment_group(self) -> None:
        print("\n[2/5] Creating AI Governance assignment group...")

        if self._get_sys_id("sys_user_group", "name", "AI Governance"):
            print("  ✅ Already exists: AI Governance")
            return

        result = self._post("sys_user_group", {
            "name":        "AI Governance",
            "description": (
                "Approvals for Azure AI model access, token quota increases, "
                "and tool integrations."
            ),
            "active": "true",
        })
        if result is not None:
            print("  ✅ Created group: AI Governance")
        else:
            print("  ❌ Failed to create group")

    # ------------------------------------------------------------------
    # Step 3 — Inbound Scripted REST API
    # ------------------------------------------------------------------

    def create_inbound_webhook(self) -> None:
        print("\n[3/5] Creating inbound Scripted REST API (Azure → ServiceNow)...")

        if self._get_sys_id("sys_ws_definition", "rest_service_root", INBOUND_API_ROOT):
            print(f"  ✅ Already exists: {INBOUND_API_ROOT}")
            return

        api = self._post("sys_ws_definition", {
            "rest_service_root":  INBOUND_API_ROOT,
            "name":               INBOUND_API_NAME,
            "is_active":          "true",
            "short_description":  (
                "Receives APIM subscription lifecycle events from the Azure "
                "Function App (automation/functions/apim-subscription-handler)."
            ),
        })
        if api is None:
            print("  ❌ Failed to create Scripted REST API")
            return
        print(f"  ✅ Created API: {INBOUND_API_NAME}")

        api_sys_id = self._get_sys_id(
            "sys_ws_definition", "rest_service_root", INBOUND_API_ROOT
        )
        if not api_sys_id:
            print("  ⚠️  Could not retrieve sys_id for new API — skipping resource creation")
            return

        resource = self._post("sys_ws_operation", {
            "web_service_definition": api_sys_id,
            "name":                   "subscription",
            "http_method":            "POST",
            "relative_path":          "/subscription",
            "operation_script":       INBOUND_SCRIPT,
            "requires_acl_authorization": "false",
            "requires_authentication":    "true",
        })
        if resource is not None:
            print(
                f"  ✅ Resource: POST /api/x_<scope>/{INBOUND_API_ROOT}/subscription"
            )
        else:
            print("  ❌ Failed to create webhook resource")

    # ------------------------------------------------------------------
    # Step 4 — Outbound REST Message
    # ------------------------------------------------------------------

    def create_outbound_rest_message(
        self, function_url: str, function_key: str
    ) -> None:
        print("\n[4/5] Creating outbound REST Message (ServiceNow → Azure)...")

        if self._get_sys_id("sys_rest_message", "name", OUTBOUND_MSG_NAME):
            print(f"  ✅ Already exists: {OUTBOUND_MSG_NAME}")
            return

        msg = self._post("sys_rest_message", {
            "name":                OUTBOUND_MSG_NAME,
            "rest_endpoint":       function_url,
            "short_description":   (
                "Notifies the Azure Function App when an AI governance ticket "
                "is approved, triggering APIM subscription provisioning."
            ),
            "authentication_type": "no_authentication",  # Key sent as header below
        })
        if msg is None:
            print("  ❌ Failed to create REST Message")
            return
        print(f"  ✅ Created: {OUTBOUND_MSG_NAME}")

        msg_sys_id = self._get_sys_id("sys_rest_message", "name", OUTBOUND_MSG_NAME)
        if not msg_sys_id:
            print("  ⚠️  Could not retrieve sys_id — skipping HTTP function creation")
            return

        fn = self._post("sys_rest_message_fn", {
            "rest_message":  msg_sys_id,
            "name":          "notifyApproval",
            "http_method":   "POST",
            "rest_endpoint": function_url,
            "content": (
                '{"sys_id":"${sys_id}","event_type":"${event_type}",'
                '"table":"${table}","approved_by":"${approved_by}"}'
            ),
        })
        if fn is None:
            print("  ❌ Failed to create HTTP function")
            return

        fn_sys_id = fn.get("sys_id")
        if fn_sys_id:
            self._post("sys_rest_message_fn_headers", {
                "message_function": fn_sys_id,
                "name":             "x-functions-key",
                "value":            function_key,
            })
            print("  ✅ HTTP function 'notifyApproval' created with x-functions-key header")

    # ------------------------------------------------------------------
    # Step 5 — Verification
    # ------------------------------------------------------------------

    def verify(self) -> bool:
        print("\n[5/5] Verifying all resources...")
        checks = {
            "Table  u_ai_model_requests": ("sys_db_object",     "name",              "u_ai_model_requests"),
            "Table  u_ai_quota_requests": ("sys_db_object",     "name",              "u_ai_quota_requests"),
            "Table  u_ai_tool_requests":  ("sys_db_object",     "name",              "u_ai_tool_requests"),
            "Group  AI Governance":       ("sys_user_group",    "name",              "AI Governance"),
            "Inbound webhook API":        ("sys_ws_definition", "rest_service_root", INBOUND_API_ROOT),
            "Outbound REST Message":      ("sys_rest_message",  "name",              OUTBOUND_MSG_NAME),
        }
        all_ok = True
        for label, (table, field, value) in checks.items():
            if self._get_sys_id(table, field, value):
                print(f"  ✅ {label}")
            else:
                print(f"  ❌ MISSING: {label}")
                all_ok = False
        return all_ok

    # ------------------------------------------------------------------
    # Run all steps
    # ------------------------------------------------------------------

    def run(self, function_url: str, function_key: str) -> None:
        print(f"\nServiceNow Bootstrap — {self.base}")
        print("=" * 65)

        self.create_tables()
        self.create_assignment_group()
        self.create_inbound_webhook()
        self.create_outbound_rest_message(function_url, function_key)
        ok = self.verify()

        print("\n" + "=" * 65)
        if self._errors:
            print(f"⚠️  {len(self._errors)} error(s) during setup:")
            for err in self._errors:
                print(f"   • {err}")

        if ok and not self._errors:
            print("✅ Bootstrap complete — ServiceNow integration is ready.")
            print()
            print("Next: set this in your Azure Function App environment variables")
            print("(infrastructure/bicep/event-grid-automation.bicep → appSettings):")
            print()
            print(f"  SN_INSTANCE    = {self.base}")
            print(f"  SN_WEBHOOK_URL = {self.base}/api/x_<scope>/{INBOUND_API_ROOT}/subscription")
            print()
            print("Replace x_<scope> with your instance's app scope prefix.")
            print(
                "Run verify.py to confirm the scope or check: "
                f"{self.base}/nav_to.do?uri=sys_scope_list.do"
            )
        else:
            print("❌ Bootstrap finished with errors — see above.")
            sys.exit(1)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Bootstrap ServiceNow for Azure AI as a Service integration"
    )
    parser.add_argument("--instance",         default=os.getenv("SN_INSTANCE"),       help="ServiceNow instance URL")
    parser.add_argument("--username",         default=os.getenv("SN_USERNAME"),       help="Admin username")
    parser.add_argument("--password",         default=os.getenv("SN_PASSWORD"),       help="Admin password")
    parser.add_argument("--function-app-url", default=os.getenv("AZURE_FUNCTION_URL"),help="Azure Function App trigger URL")
    parser.add_argument("--function-app-key", default=os.getenv("AZURE_FUNCTION_KEY"),help="Azure Function App host key")
    args = parser.parse_args()

    missing = [
        k for k, v in {
            "--instance":         args.instance,
            "--username":         args.username,
            "--password":         args.password,
            "--function-app-url": args.function_app_url,
            "--function-app-key": args.function_app_key,
        }.items()
        if not v
    ]
    if missing:
        parser.error(f"Missing required arguments (or env vars): {', '.join(missing)}")

    ServiceNowBootstrap(args.instance, args.username, args.password).run(
        args.function_app_url, args.function_app_key
    )


if __name__ == "__main__":
    main()

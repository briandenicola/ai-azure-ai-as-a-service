"""
ServiceNow Integration Verification — Azure AI as a Service.

Checks that all resources created by bootstrap.py exist and are reachable.
Also discovers the application scope prefix needed for the inbound webhook URL.

Usage:
  python verify.py \\
    --instance https://dev389009.service-now.com \\
    --username admin \\
    --password <password>

  Or set: SN_INSTANCE, SN_USERNAME, SN_PASSWORD
"""

import argparse
import os
import sys
from typing import Any

import requests


INBOUND_API_ROOT = "azure_ai_service_events"
OUTBOUND_MSG_NAME = "AzureFunctionApp_APIMHandler"

REQUIRED_RESOURCES = [
    ("Table  u_ai_model_requests", "sys_db_object",     "name",              "u_ai_model_requests"),
    ("Table  u_ai_quota_requests", "sys_db_object",     "name",              "u_ai_quota_requests"),
    ("Table  u_ai_tool_requests",  "sys_db_object",     "name",              "u_ai_tool_requests"),
    ("Group  AI Governance",       "sys_user_group",    "name",              "AI Governance"),
    ("Inbound webhook API",        "sys_ws_definition", "rest_service_root", INBOUND_API_ROOT),
    ("Outbound REST Message",      "sys_rest_message",  "name",              OUTBOUND_MSG_NAME),
]

REQUIRED_COLUMNS = {
    "u_ai_model_requests": [
        "u_requester", "u_model_name", "u_use_case", "u_line_of_business",
        "u_project_name", "u_estimated_monthly_tokens", "u_apim_subscription_key",
    ],
    "u_ai_quota_requests": [
        "u_subscription_id", "u_line_of_business", "u_current_quota_tokens",
        "u_requested_quota_tokens", "u_increase_amount",
        "u_estimated_monthly_cost_increase", "u_justification", "u_submitted_date",
    ],
    "u_ai_tool_requests": [
        "u_requester", "u_tool_name", "u_tool_type", "u_tool_endpoint",
        "u_data_classification", "u_use_case", "u_required_permissions",
        "u_project_name", "u_line_of_business", "u_security_review_required",
    ],
}


class Verifier:

    def __init__(self, instance_url: str, username: str, password: str) -> None:
        self.base = instance_url.rstrip("/")
        self.auth = (username, password)
        self.headers = {"Content-Type": "application/json", "Accept": "application/json"}
        self._failures: list[str] = []

    def _get(self, table: str, params: dict) -> list[dict[str, Any]]:
        r = requests.get(
            f"{self.base}/api/now/table/{table}",
            auth=self.auth, headers=self.headers, params=params, timeout=30,
        )
        if r.status_code == 200:
            return r.json().get("result", [])
        return []

    def _get_sys_id(self, table: str, field: str, value: str) -> str | None:
        results = self._get(table, {
            "sysparm_query": f"{field}={value}",
            "sysparm_fields": "sys_id",
            "sysparm_limit": 1,
        })
        return results[0]["sys_id"] if results else None

    # ------------------------------------------------------------------

    def check_resources(self) -> None:
        print("\n--- Required resources ---")
        for label, table, field, value in REQUIRED_RESOURCES:
            if self._get_sys_id(table, field, value):
                print(f"  ✅ {label}")
            else:
                print(f"  ❌ MISSING: {label}")
                self._failures.append(label)

    def check_columns(self) -> None:
        print("\n--- Table columns ---")
        for table_name, expected_cols in REQUIRED_COLUMNS.items():
            results = self._get("sys_dictionary", {
                "sysparm_query": f"name={table_name}",
                "sysparm_fields": "element",
                "sysparm_limit": 50,
            })
            present = {r["element"] for r in results if r.get("element")}
            missing = [c for c in expected_cols if c not in present]
            if missing:
                for col in missing:
                    print(f"  ❌ {table_name}.{col} — MISSING")
                    self._failures.append(f"{table_name}.{col}")
            else:
                print(f"  ✅ {table_name} — all {len(expected_cols)} columns present")

    def check_webhook_resource(self) -> None:
        print("\n--- Inbound webhook resource (POST /subscription) ---")
        api_sys_id = self._get_sys_id(
            "sys_ws_definition", "rest_service_root", INBOUND_API_ROOT
        )
        if not api_sys_id:
            print("  ❌ Scripted REST API not found — run bootstrap.py first")
            self._failures.append("webhook resource")
            return

        results = self._get("sys_ws_operation", {
            "sysparm_query": f"web_service_definition={api_sys_id}^http_method=POST",
            "sysparm_fields": "name,relative_path,http_method",
            "sysparm_limit": 10,
        })
        if results:
            for op in results:
                print(f"  ✅ {op['http_method']} {op['relative_path']}  ({op['name']})")
        else:
            print("  ❌ No POST operation found on webhook API")
            self._failures.append("webhook POST operation")

    def check_outbound_fn(self) -> None:
        print("\n--- Outbound REST Message functions ---")
        msg_sys_id = self._get_sys_id("sys_rest_message", "name", OUTBOUND_MSG_NAME)
        if not msg_sys_id:
            print("  ❌ Outbound REST Message not found")
            self._failures.append("outbound REST message")
            return

        fns = self._get("sys_rest_message_fn", {
            "sysparm_query": f"rest_message={msg_sys_id}",
            "sysparm_fields": "name,http_method",
            "sysparm_limit": 10,
        })
        if fns:
            for fn in fns:
                print(f"  ✅ Function: {fn['name']}  [{fn['http_method']}]")
        else:
            print("  ❌ No HTTP functions found on outbound REST Message")
            self._failures.append("outbound HTTP function")

    def discover_scope(self) -> str | None:
        print("\n--- Application scope prefix ---")
        results = self._get("sys_scope", {
            "sysparm_query": "name!=Global^active=true",
            "sysparm_fields": "name,scope",
            "sysparm_limit": 20,
        })
        if not results:
            # PDI default — Global scope uses 'x_' prefix style automatically
            print("  ℹ️  No custom scopes found; instance uses Global scope.")
            print("       Inbound webhook URL will use the 'now' namespace:")
            print(f"       {self.base}/api/now/{INBOUND_API_ROOT}/subscription")
            return "now"

        print("  Found application scopes:")
        for s in results:
            print(f"    {s['scope']:30s}  ({s['name']})")

        # The Scripted REST API was created in whatever scope was active.
        # Check which scope owns our API definition.
        api_result = self._get("sys_ws_definition", {
            "sysparm_query": f"rest_service_root={INBOUND_API_ROOT}",
            "sysparm_fields": "sys_scope",
            "sysparm_limit": 1,
        })
        if api_result and api_result[0].get("sys_scope"):
            scope_link = api_result[0]["sys_scope"]
            scope_value = scope_link.get("value") or scope_link if isinstance(scope_link, str) else None
            if scope_value:
                scope_record = self._get("sys_scope", {
                    "sysparm_query": f"sys_id={scope_value}",
                    "sysparm_fields": "scope",
                    "sysparm_limit": 1,
                })
                if scope_record:
                    prefix = scope_record[0]["scope"]
                    print(f"\n  Webhook scope prefix: {prefix}")
                    print(f"  ✅ Inbound webhook URL:")
                    print(f"     {self.base}/api/{prefix}/{INBOUND_API_ROOT}/subscription")
                    return prefix

        print(f"\n  ⚠️  Could not determine scope automatically.")
        print(f"     Check: {self.base}/nav_to.do?uri=sys_ws_definition_list.do")
        return None

    # ------------------------------------------------------------------

    def run(self) -> None:
        print(f"\nServiceNow Verification — {self.base}")
        print("=" * 65)

        self.check_resources()
        self.check_columns()
        self.check_webhook_resource()
        self.check_outbound_fn()
        self.discover_scope()

        print("\n" + "=" * 65)
        if self._failures:
            print(f"❌ {len(self._failures)} check(s) failed:")
            for f in self._failures:
                print(f"   • {f}")
            print("\nRun bootstrap.py to create missing resources.")
            sys.exit(1)
        else:
            print("✅ All checks passed — integration is correctly configured.")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Verify ServiceNow setup for Azure AI as a Service"
    )
    parser.add_argument("--instance", default=os.getenv("SN_INSTANCE"), help="ServiceNow instance URL")
    parser.add_argument("--username", default=os.getenv("SN_USERNAME"), help="Admin username")
    parser.add_argument("--password", default=os.getenv("SN_PASSWORD"), help="Admin password")
    args = parser.parse_args()

    missing = [
        k for k, v in {
            "--instance": args.instance,
            "--username": args.username,
            "--password": args.password,
        }.items()
        if not v
    ]
    if missing:
        parser.error(f"Missing: {', '.join(missing)}")

    Verifier(args.instance, args.username, args.password).run()


if __name__ == "__main__":
    main()

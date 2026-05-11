"""Entra ID interactive login for the investment-platform console app.

Uses MSAL device code flow — works in any terminal/console environment
without requiring a browser redirect.  Tokens are cached on disk so users
only need to authenticate once (until the access token expires, ~1 hour).

Usage:
    from auth.entra_auth import login, get_display_name

    result = login(tenant_id, client_id)
    print(f"Hello, {get_display_name(result)}")
    access_token = result["access_token"]
"""

from pathlib import Path
import msal

# Token cache file — stored next to .env, excluded from git via .gitignore
_CACHE_FILE = Path(__file__).parent.parent / ".token_cache.json"

# User.Read scope: returns the signed-in user's display name, email, and UPN
# in the id_token_claims.  The access token audience is graph.microsoft.com.
_SCOPES = ["User.Read"]


def _load_cache() -> msal.SerializableTokenCache:
    cache = msal.SerializableTokenCache()
    if _CACHE_FILE.exists():
        cache.deserialize(_CACHE_FILE.read_text(encoding="utf-8"))
    return cache


def _save_cache(cache: msal.SerializableTokenCache) -> None:
    if cache.has_state_changed:
        _CACHE_FILE.write_text(cache.serialize(), encoding="utf-8")


def login(tenant_id: str, client_id: str) -> dict:
    """Acquire a token interactively via device code flow.

    Tries the token cache first (silent refresh).  Falls back to device code
    if no valid cached token exists or the refresh token has expired.

    Args:
        tenant_id:  Entra tenant GUID (ENTRA_TENANT_ID from .env).
        client_id:  App Registration client ID (ENTRA_CLIENT_ID from .env).

    Returns:
        MSAL result dict containing at minimum:
          - "access_token"    — Bearer token to attach to APIM requests
          - "id_token_claims" — dict of JWT claims (name, email, upn, oid …)

    Raises:
        RuntimeError: if authentication fails.
    """
    cache = _load_cache()
    app = msal.PublicClientApplication(
        client_id=client_id,
        authority=f"https://login.microsoftonline.com/{tenant_id}",
        token_cache=cache,
    )

    # Try silent (cached) first
    accounts = app.get_accounts()
    if accounts:
        result = app.acquire_token_silent(_SCOPES, account=accounts[0])
        if result and "access_token" in result:
            _save_cache(cache)
            return result

    # Device code flow: prints a short code + URL the user visits once
    flow = app.initiate_device_flow(scopes=_SCOPES)
    if "user_code" not in flow:
        raise RuntimeError(
            f"Failed to start device flow: {flow.get('error_description', flow)}"
        )

    # MSAL formats the message for us:
    # "To sign in, use a web browser to open https://microsoft.com/devicelogin
    #  and enter code XXXXXXXX to authenticate."
    print(f"\n{flow['message']}\n")

    result = app.acquire_token_by_device_flow(flow)
    if "access_token" not in result:
        raise RuntimeError(
            f"Authentication failed: {result.get('error_description', result.get('error', result))}"
        )

    _save_cache(cache)
    return result


def get_display_name(result: dict) -> str:
    """Extract a human-readable name from a successful MSAL token result."""
    claims = result.get("id_token_claims") or {}
    return (
        claims.get("name")
        or claims.get("preferred_username")
        or claims.get("upn")
        or "Unknown User"
    )

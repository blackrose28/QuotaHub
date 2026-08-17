#!/usr/bin/env python3
"""QuotaHub Collector — aggregates AI subscription quota data into status.json.

Runs as a one-shot script (invoked by systemd timer or cron) and writes a
unified JSON file that the KDE Plasma widget reads.

Data sources
------------
- Claude Code: OAuth usage endpoint (primary), local JSONL logs (fallback)
- Antigravity: CloudCode internal API via D-Bus keyring credentials
- Codex: ChatGPT backend API via ~/.codex/auth.json credentials
- Command Code: commandcode.ai backend API via ~/.commandcode/auth.json API key
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CLAUDE_CREDENTIALS_PATH = Path.home() / ".claude" / ".credentials.json"
CLAUDE_LOGS_DIR = Path.home() / ".claude" / "projects"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_CODE_VERSION = "2.1.214"  # used in User-Agent header

AGY_CREDENTIALS_PATH = Path.home() / ".gemini" / "oauth_creds.json"
ANTIGRAVITY_ENDPOINTS = [
    "https://daily-cloudcode-pa.googleapis.com",
    "https://daily-cloudcode-pa.sandbox.googleapis.com",
    "https://cloudcode-pa.googleapis.com",
]
# Map API group display names to service IDs and human-friendly names
_AGY_GROUP_MAP: dict[str, tuple[str, str]] = {
    "gemini": ("agy_gemini", "Agy: Gemini"),
    "3p":     ("agy_3p",     "Agy: Claude/GPT"),
}

CODEX_AUTH_PATH = Path(os.environ.get(
    "CODEX_HOME",
    Path.home() / ".codex",
)) / "auth.json"
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"

COMMANDCODE_AUTH_PATH = Path.home() / ".commandcode" / "auth.json"
COMMANDCODE_API_BASE = "https://api.commandcode.ai"

# Monthly credit allotment and display label per plan ID, keyed by prefix
# (plan IDs are occasionally versioned, e.g. "individual-pro-v1").
_COMMANDCODE_PLAN_CREDITS: dict[str, float] = {
    "individual-go": 10,
    "individual-goat": 70,
    "individual-pro-v1": 80,
    "individual-pro": 30,
    "individual-provider": 15,
    "individual-max": 150,
    "individual-ultra": 300,
    "teams-pro": 40,
}
_COMMANDCODE_PLAN_LABELS: dict[str, str] = {
    "individual-go": "Go",
    "individual-goat": "GOAT",
    "individual-pro-v1": "Pro",
    "individual-pro": "Pro",
    "individual-provider": "Provider",
    "individual-max": "Max",
    "individual-ultra": "Ultra",
    "teams-pro": "Teams Pro",
}
# Longest prefix first, so "individual-pro-v1" matches before "individual-pro"
_COMMANDCODE_PLAN_KEYS = sorted(_COMMANDCODE_PLAN_LABELS, key=len, reverse=True)

OUTPUT_DIR = Path(os.environ.get(
    "QUOTAHUB_DATA_DIR",
    Path.home() / ".local" / "share" / "quotahub",
))
OUTPUT_FILE = OUTPUT_DIR / "status.json"

LOG_LEVEL = os.environ.get("QUOTAHUB_LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("quotahub")

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class UsageWindow:
    name: str
    used_pct: float | None = None
    resets_at: str | None = None

@dataclass
class ServiceStatus:
    id: str
    name: str
    plan: str = ""
    status: str = "unknown"       # ok | warning | critical | exhausted | unknown | error
    error: str | None = None
    windows: list[UsageWindow] = field(default_factory=list)

@dataclass
class CollectorOutput:
    updated_at: str = ""
    services: list[ServiceStatus] = field(default_factory=list)

# ---------------------------------------------------------------------------
# Claude Code — OAuth usage endpoint
# ---------------------------------------------------------------------------

def _load_claude_credentials() -> dict[str, Any] | None:
    """Read the Claude Code OAuth credentials file."""
    if not CLAUDE_CREDENTIALS_PATH.is_file():
        log.warning("Claude credentials not found at %s", CLAUDE_CREDENTIALS_PATH)
        return None

    try:
        data = json.loads(CLAUDE_CREDENTIALS_PATH.read_text(encoding="utf-8"))
        oauth = data.get("claudeAiOauth")
        if not oauth or not oauth.get("accessToken"):
            log.warning("No OAuth access token in credentials file")
            return None

        # Check if the access token is expired
        expires_at = oauth.get("expiresAt", 0)
        now_ms = int(time.time() * 1000)
        if now_ms >= expires_at:
            log.info("Access token expired, attempting refresh")
            refreshed = _refresh_claude_token(data, oauth)
            if refreshed is not None:
                return refreshed
            log.warning("Token refresh failed, proceeding with expired token")

        return oauth
    except (json.JSONDecodeError, OSError) as exc:
        log.error("Failed to read Claude credentials: %s", exc)
        return None


def _refresh_claude_token(
    full_data: dict[str, Any],
    oauth: dict[str, Any],
) -> dict[str, Any] | None:
    """Refresh the Claude OAuth access token by invoking the Claude CLI.

    Instead of calling the OAuth token endpoint directly (which is
    aggressively rate-limited), we spawn ``claude -p '.'`` which triggers
    Claude Code's internal token refresh mechanism.  After the CLI exits,
    we re-read the credentials file to get the updated token.

    Inspired by CodeZeno/Claude-Code-Usage-Monitor.
    """
    import shutil
    import subprocess

    claude_bin = shutil.which("claude")
    if not claude_bin:
        # Try common locations
        local_bin = Path.home() / ".local" / "bin" / "claude"
        if local_bin.is_file():
            claude_bin = str(local_bin)
        else:
            log.warning("Claude CLI not found in PATH or ~/.local/bin/")
            return None

    log.info("Refreshing token via Claude CLI: %s -p '.'", claude_bin)

    try:
        proc = subprocess.run(
            [claude_bin, "-p", "."],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            env={
                **os.environ,
                # Prevent recursion if we're running inside Claude Code
                "CLAUDECODE": "",
                "CLAUDE_CODE_ENTRYPOINT": "",
            },
        )
        log.info("Claude CLI exited with code %d", proc.returncode)
    except subprocess.TimeoutExpired:
        log.warning("Claude CLI token refresh timed out after 30s")
    except OSError as exc:
        log.warning("Failed to spawn Claude CLI: %s", exc)
        return None

    # Re-read the credentials file — Claude CLI should have refreshed it
    try:
        data = json.loads(CLAUDE_CREDENTIALS_PATH.read_text(encoding="utf-8"))
        refreshed_oauth = data.get("claudeAiOauth")
        if not refreshed_oauth or not refreshed_oauth.get("accessToken"):
            log.warning("Credentials file still has no token after CLI refresh")
            return None

        new_expires = refreshed_oauth.get("expiresAt", 0)
        now_ms = int(time.time() * 1000)
        if now_ms >= new_expires:
            log.warning("Token still expired after CLI refresh")
            return None

        log.info("Token refreshed successfully via CLI")
        return refreshed_oauth
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("Failed to re-read credentials after CLI refresh: %s", exc)
        return None


def _claude_plan_label(creds: dict[str, Any]) -> str:
    """Derive a human-friendly plan label from credential metadata."""
    sub_type = creds.get("subscriptionType", "unknown")
    tier = creds.get("rateLimitTier", "")

    label_map = {
        "pro": "Pro",
        "max_5x": "Max 5x",
        "max_20x": "Max 20x",
        "team": "Team",
        "enterprise": "Enterprise",
    }
    return label_map.get(sub_type, sub_type.replace("_", " ").title())


def _query_claude_oauth_usage(access_token: str) -> dict[str, Any] | None:
    """Hit the undocumented Claude OAuth usage endpoint."""
    headers = {
        "Authorization": f"Bearer {access_token}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": f"claude-code/{CLAUDE_CODE_VERSION}",
        "Accept": "application/json",
    }

    req = urllib.request.Request(CLAUDE_USAGE_URL, headers=headers, method="GET")

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body)
    except urllib.error.HTTPError as exc:
        log.warning("Claude usage endpoint returned HTTP %d: %s", exc.code, exc.reason)
        return None
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log.warning("Failed to query Claude usage endpoint: %s", exc)
        return None


def _status_from_utilization(pct: float | None) -> str:
    """Map utilization percentage to a status label."""
    if pct is None:
        return "unknown"
    if pct >= 95:
        return "exhausted"
    if pct >= 80:
        return "critical"
    if pct >= 60:
        return "warning"
    return "ok"


def collect_claude_code() -> ServiceStatus:
    """Collect Claude Code quota data."""
    creds = _load_claude_credentials()
    if creds is None:
        return ServiceStatus(
            id="claude_code",
            name="Claude Code",
            status="error",
            error="No credentials found",
        )

    plan = _claude_plan_label(creds)
    access_token = creds["accessToken"]

    usage = _query_claude_oauth_usage(access_token)
    if usage is None:
        return ServiceStatus(
            id="claude_code",
            name="Claude Code",
            plan=plan,
            status="error",
            error="Usage endpoint unavailable",
        )

    windows: list[UsageWindow] = []
    worst_status = "ok"

    # 5-hour rolling window
    five_hour = usage.get("five_hour")
    if five_hour and five_hour.get("utilization") is not None:
        pct = five_hour["utilization"]
        windows.append(UsageWindow(
            name="5h rolling",
            used_pct=round(pct, 1),
            resets_at=five_hour.get("resets_at"),
        ))
        s = _status_from_utilization(pct)
        if _status_severity(s) > _status_severity(worst_status):
            worst_status = s

    # 7-day weekly window
    seven_day = usage.get("seven_day")
    if seven_day and seven_day.get("utilization") is not None:
        pct = seven_day["utilization"]
        windows.append(UsageWindow(
            name="weekly",
            used_pct=round(pct, 1),
            resets_at=seven_day.get("resets_at"),
        ))
        s = _status_from_utilization(pct)
        if _status_severity(s) > _status_severity(worst_status):
            worst_status = s

    return ServiceStatus(
        id="claude_code",
        name="Claude Code",
        plan=plan,
        status=worst_status,
        windows=windows,
    )


_SEVERITY_ORDER = {
    "ok": 0,
    "unknown": 1,
    "warning": 2,
    "critical": 3,
    "exhausted": 4,
    "error": 5,
}


def _status_severity(status: str) -> int:
    return _SEVERITY_ORDER.get(status, 1)

# ---------------------------------------------------------------------------
# Antigravity — CloudCode internal API
# ---------------------------------------------------------------------------

def _read_agy_keyring_token() -> dict[str, Any] | None:
    """Read Antigravity OAuth token from the Linux D-Bus Secret Service.

    The ``agy`` CLI stores its credentials in the system keyring with
    attributes ``service=gemini, username=antigravity``.  The secret is a
    JSON blob: ``{"token": {"access_token": ..., "expiry": ...}, ...}``.
    """
    try:
        import dbus  # noqa: PLC0415 — optional dep, only on Linux desktops
    except ImportError:
        log.debug("python-dbus not available, skipping keyring")
        return None

    try:
        bus = dbus.SessionBus()
        svc = bus.get_object(
            "org.freedesktop.secrets", "/org/freedesktop/secrets",
        )
        iface = dbus.Interface(svc, "org.freedesktop.Secret.Service")
        _algo, session = iface.OpenSession("plain", dbus.String(""))

        col = bus.get_object(
            "org.freedesktop.secrets",
            "/org/freedesktop/secrets/aliases/default",
        )
        items = col.Get(
            "org.freedesktop.Secret.Collection", "Items",
            dbus_interface="org.freedesktop.DBus.Properties",
        )

        for item_path in items:
            item_obj = bus.get_object("org.freedesktop.secrets", item_path)
            props = dbus.Interface(
                item_obj, "org.freedesktop.DBus.Properties",
            )
            attrs = dict(props.Get(
                "org.freedesktop.Secret.Item", "Attributes",
            ))
            if attrs.get("service") == "gemini" \
                    and attrs.get("username") == "antigravity":
                secret = dbus.Interface(
                    item_obj, "org.freedesktop.Secret.Item",
                ).GetSecret(session)
                blob = json.loads(bytes(secret[2]).decode("utf-8"))
                token_data = blob.get("token", {})
                if token_data.get("access_token"):
                    log.debug("Read Antigravity token from keyring")
                    return token_data
    except Exception as exc:  # noqa: BLE001
        log.debug("Failed to read Antigravity keyring: %s", exc)

    return None


def _read_agy_file_token() -> dict[str, Any] | None:
    """Fallback: read Antigravity token from ~/.gemini/oauth_creds.json."""
    if not AGY_CREDENTIALS_PATH.is_file():
        return None
    try:
        data = json.loads(AGY_CREDENTIALS_PATH.read_text(encoding="utf-8"))
        if not data.get("access_token"):
            return None
        # Normalise to the same shape as the keyring blob
        expiry = None
        if data.get("expiry_date"):
            from datetime import datetime, timezone  # noqa: PLC0415
            ts = data["expiry_date"] / 1000
            expiry = datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()
        return {
            "access_token": data["access_token"],
            "token_type": data.get("token_type", "Bearer"),
            "refresh_token": data.get("refresh_token", ""),
            "expiry": expiry,
        }
    except (json.JSONDecodeError, OSError) as exc:
        log.debug("Failed to read Antigravity file credentials: %s", exc)
        return None


def _is_agy_token_expired(token_data: dict[str, Any]) -> bool:
    """Check whether the Antigravity token has expired."""
    expiry_str = token_data.get("expiry")
    if not expiry_str:
        return False  # assume valid if no expiry
    try:
        from datetime import datetime, timezone  # noqa: PLC0415
        expiry = datetime.fromisoformat(expiry_str)
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=timezone.utc)
        return datetime.now(timezone.utc) >= expiry
    except (ValueError, TypeError):
        return False


def _refresh_agy_token() -> None:
    """Spawn ``agy -p '.'`` to trigger the CLI's internal token refresh."""
    import shutil
    import subprocess

    agy_bin = shutil.which("agy")
    if not agy_bin:
        local_bin = Path.home() / ".local" / "bin" / "agy"
        if local_bin.is_file():
            agy_bin = str(local_bin)
        else:
            log.warning("agy CLI not found in PATH or ~/.local/bin/")
            return

    log.info("Refreshing Antigravity token via: %s -p '.'", agy_bin)
    try:
        subprocess.run(
            [agy_bin, "-p", "."],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        log.warning("Antigravity CLI token refresh timed out")
    except OSError as exc:
        log.warning("Failed to spawn agy CLI: %s", exc)


def _load_agy_credentials() -> str | None:
    """Return a valid Antigravity access token, or None."""
    # 1. Try keyring (primary on Linux desktop)
    token_data = _read_agy_keyring_token()

    # 2. Fallback to file
    if token_data is None:
        token_data = _read_agy_file_token()

    if token_data is None:
        log.warning("No Antigravity credentials found")
        return None

    # 3. Refresh if expired
    if _is_agy_token_expired(token_data):
        log.info("Antigravity token expired, attempting refresh")
        _refresh_agy_token()
        # Re-read from keyring after refresh
        token_data = _read_agy_keyring_token() or _read_agy_file_token()
        if token_data is None:
            log.warning("No credentials after Antigravity token refresh")
            return None

    return token_data.get("access_token")


def _agy_request(
    url: str, token: str, body: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """Send a POST request to the Antigravity CloudCode API."""
    payload = json.dumps(body or {}).encode()
    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "antigravity")

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        log.warning("Antigravity API %s returned HTTP %d", url, exc.code)
        return None
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log.warning("Antigravity API request failed: %s", exc)
        return None


# Map known paidTier / currentTier IDs to short plan labels
_AGY_PLAN_MAP: dict[str, str] = {
    "free-tier":       "Free",
    "g1-pro-tier":     "Pro",
    "g1-ultra-tier":   "Ultra",
    "standard-tier":   "Standard",
}


def _agy_plan_label(resp: dict[str, Any]) -> str:
    """Derive a human-friendly plan label from the loadCodeAssist response."""
    # Prefer paidTier (present when user has a paid Google One AI plan)
    paid = resp.get("paidTier") or {}
    tier_id = paid.get("id", "")
    if tier_id and tier_id in _AGY_PLAN_MAP:
        return _AGY_PLAN_MAP[tier_id]
    # Fallback: use the name field from paidTier
    if paid.get("name"):
        # e.g. "Google AI Ultra" → "Ultra"
        name = paid["name"]
        for suffix in ("Ultra", "Pro", "Free"):
            if suffix.lower() in name.lower():
                return suffix
        return name
    # Last resort: currentTier
    current = resp.get("currentTier") or {}
    tier_id = current.get("id", "")
    return _AGY_PLAN_MAP.get(tier_id, tier_id or "Unknown")


def _fetch_agy_project(
    base_url: str, token: str,
) -> tuple[str, str] | None:
    """Call loadCodeAssist to obtain the Cloud project ID and plan label.

    Returns ``(project_id, plan_label)`` on success, or ``None``.
    """
    resp = _agy_request(
        f"{base_url}/v1internal:loadCodeAssist",
        token,
        {"metadata": {"ideType": "ANTIGRAVITY"}},
    )
    if resp is None:
        return None
    project = resp.get("cloudaicompanionProject", "")
    if not project:
        return None
    plan = _agy_plan_label(resp)
    log.debug("Antigravity plan detected: %s", plan)
    return project, plan


def _fetch_agy_quota_summary(
    base_url: str, token: str, project: str, plan: str = "Unknown",
) -> list[ServiceStatus]:
    """Call retrieveUserQuotaSummary and return one ServiceStatus per group."""
    resp = _agy_request(
        f"{base_url}/v1internal:retrieveUserQuotaSummary",
        token,
        {"project": project},
    )
    if resp is None:
        return []

    results: list[ServiceStatus] = []

    for group in resp.get("groups", []):
        # Determine service ID from bucket IDs (e.g. "gemini-weekly" → "gemini")
        buckets = group.get("buckets", [])
        group_key = _classify_agy_group(group, buckets)
        svc_id, svc_name = _AGY_GROUP_MAP.get(
            group_key,
            (f"agy_{group_key}", f"Agy: {group.get('displayName', group_key)}"),
        )

        windows: list[UsageWindow] = []
        worst_status = "ok"

        for bucket in buckets:
            remaining = bucket.get("remainingFraction")
            if remaining is None:
                continue
            used_pct = round((1.0 - remaining) * 100, 1)
            window_name = bucket.get("window", "")
            display = "5h rolling" if window_name == "5h" else window_name

            windows.append(UsageWindow(
                name=display,
                used_pct=used_pct,
                resets_at=bucket.get("resetTime"),
            ))

            s = _status_from_utilization(used_pct)
            if _status_severity(s) > _status_severity(worst_status):
                worst_status = s

        if windows:
            # Sort: 5h rolling first, weekly second (match Claude Code order)
            _window_order = {"5h rolling": 0, "weekly": 1}
            windows.sort(key=lambda w: _window_order.get(w.name, 2))
            results.append(ServiceStatus(
                id=svc_id,
                name=svc_name,
                plan=plan,
                status=worst_status,
                windows=windows,
            ))

    return results


def _classify_agy_group(
    group: dict[str, Any], buckets: list[dict[str, Any]],
) -> str:
    """Classify a quota group as 'gemini' or '3p' based on bucket IDs/names."""
    for bucket in buckets:
        bid = (bucket.get("bucketId") or "").lower()
        if bid.startswith("gemini"):
            return "gemini"
        if bid.startswith("3p"):
            return "3p"

    # Fallback: check displayName
    display = (group.get("displayName") or "").lower()
    if "gemini" in display:
        return "gemini"
    if "claude" in display or "gpt" in display or "3p" in display:
        return "3p"

    return display.replace(" ", "_")[:20] or "unknown"


def collect_antigravity() -> list[ServiceStatus]:
    """Collect Antigravity quota data for all model groups.

    Returns a list of ServiceStatus — one per quota group (typically
    Gemini and Claude/GPT).  Returns an empty list on failure.
    """
    token = _load_agy_credentials()
    if token is None:
        return []

    for base_url in ANTIGRAVITY_ENDPOINTS:
        result = _fetch_agy_project(base_url, token)
        if result is None:
            continue
        project, plan = result

        results = _fetch_agy_quota_summary(base_url, token, project, plan)
        if results:
            return results

    log.warning("Antigravity: all endpoints failed")
    return []

# ---------------------------------------------------------------------------
# Codex — ChatGPT backend API
# ---------------------------------------------------------------------------

def _load_codex_credentials() -> str | None:
    """Read the Codex CLI OAuth access token from ~/.codex/auth.json."""
    if not CODEX_AUTH_PATH.is_file():
        log.debug("Codex auth not found at %s", CODEX_AUTH_PATH)
        return None

    try:
        data = json.loads(CODEX_AUTH_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("Failed to read Codex auth file: %s", exc)
        return None

    # Only support ChatGPT-authenticated sessions
    auth_mode = data.get("auth_mode", "")
    if auth_mode != "chatgpt":
        log.debug("Codex auth_mode is '%s', not 'chatgpt' — skipping", auth_mode)
        return None

    tokens = data.get("tokens") or {}
    access_token = tokens.get("access_token", "")
    if not access_token:
        log.warning("No access_token in Codex auth file")
        return None

    # Check if the token might be stale (last_refresh > 1 hour ago)
    last_refresh = data.get("last_refresh", "")
    if last_refresh:
        try:
            from datetime import datetime, timezone  # noqa: PLC0415
            refreshed_at = datetime.fromisoformat(last_refresh)
            if refreshed_at.tzinfo is None:
                refreshed_at = refreshed_at.replace(tzinfo=timezone.utc)
            age_seconds = (datetime.now(timezone.utc) - refreshed_at).total_seconds()
            if age_seconds > 3600:
                log.info("Codex token is %.0f s old, attempting refresh", age_seconds)
                _refresh_codex_token()
                # Re-read after refresh
                try:
                    data = json.loads(CODEX_AUTH_PATH.read_text(encoding="utf-8"))
                    tokens = data.get("tokens") or {}
                    access_token = tokens.get("access_token", access_token)
                except (json.JSONDecodeError, OSError):
                    pass  # use the original token
        except (ValueError, TypeError):
            pass  # can't parse timestamp, proceed with existing token

    return access_token


def _refresh_codex_token() -> None:
    """Spawn ``codex --version`` to trigger the CLI's internal token refresh.

    The Codex CLI (Rust binary) refreshes its OAuth tokens on startup.
    Using ``--version`` is a lightweight way to trigger this without
    starting an interactive session.
    """
    import shutil
    import subprocess

    codex_bin = shutil.which("codex")
    if not codex_bin:
        local_bin = Path.home() / ".local" / "bin" / "codex"
        if local_bin.is_file():
            codex_bin = str(local_bin)
        else:
            log.warning("codex CLI not found in PATH or ~/.local/bin/")
            return

    log.info("Refreshing Codex token via: %s --version", codex_bin)
    try:
        subprocess.run(
            [codex_bin, "--version"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except subprocess.TimeoutExpired:
        log.warning("Codex CLI token refresh timed out")
    except OSError as exc:
        log.warning("Failed to spawn codex CLI: %s", exc)


def _query_codex_usage(access_token: str) -> dict[str, Any] | None:
    """Query the ChatGPT backend usage endpoint for Codex quota data."""
    headers = {
        "Authorization": f"Bearer {access_token}",
        "User-Agent": "codex-cli",
        "Accept": "application/json",
    }

    req = urllib.request.Request(CODEX_USAGE_URL, headers=headers, method="GET")

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body)
    except urllib.error.HTTPError as exc:
        log.warning("Codex usage endpoint returned HTTP %d: %s", exc.code, exc.reason)
        return None
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log.warning("Failed to query Codex usage endpoint: %s", exc)
        return None


def _codex_plan_label(usage_data: dict[str, Any]) -> str:
    """Derive a human-friendly plan label from the usage response."""
    plan_type = usage_data.get("plan_type", "")
    label_map = {
        "plus": "Plus",
        "pro": "Pro",
        "business": "Business",
        "enterprise": "Enterprise",
        "team": "Team",
    }
    return label_map.get(plan_type.lower(), plan_type or "Unknown")


def collect_codex() -> ServiceStatus | None:
    """Collect Codex CLI quota data.

    Returns a ServiceStatus on success, or None if Codex is not
    configured / credentials are missing.
    """
    access_token = _load_codex_credentials()
    if access_token is None:
        return None

    usage = _query_codex_usage(access_token)
    if usage is None:
        return ServiceStatus(
            id="codex",
            name="Codex",
            status="error",
            error="Usage endpoint unavailable",
        )

    plan = _codex_plan_label(usage)
    rate_limit = usage.get("rate_limit") or {}

    windows: list[UsageWindow] = []
    worst_status = "ok"

    # Primary window (typically 5-hour rolling)
    primary = rate_limit.get("primary_window")
    if primary and primary.get("used_percent") is not None:
        pct = float(primary["used_percent"])
        resets_at = None
        reset_secs = primary.get("reset_after_seconds")
        if reset_secs is not None:
            from datetime import datetime, timezone, timedelta  # noqa: PLC0415
            resets_at = (
                datetime.now(timezone.utc) + timedelta(seconds=int(reset_secs))
            ).isoformat()
        windows.append(UsageWindow(
            name="5h rolling",
            used_pct=round(pct, 1),
            resets_at=resets_at,
        ))
        s = _status_from_utilization(pct)
        if _status_severity(s) > _status_severity(worst_status):
            worst_status = s

    # Secondary window (typically weekly/daily)
    secondary = rate_limit.get("secondary_window")
    if secondary and secondary.get("used_percent") is not None:
        pct = float(secondary["used_percent"])
        resets_at = None
        reset_secs = secondary.get("reset_after_seconds")
        if reset_secs is not None:
            from datetime import datetime, timezone, timedelta  # noqa: PLC0415
            resets_at = (
                datetime.now(timezone.utc) + timedelta(seconds=int(reset_secs))
            ).isoformat()
        windows.append(UsageWindow(
            name="weekly",
            used_pct=round(pct, 1),
            resets_at=resets_at,
        ))
        s = _status_from_utilization(pct)
        if _status_severity(s) > _status_severity(worst_status):
            worst_status = s

    # If the endpoint says limit_reached but we have no window data
    if rate_limit.get("limit_reached") and not windows:
        worst_status = "exhausted"

    return ServiceStatus(
        id="codex",
        name="Codex",
        plan=plan,
        status=worst_status,
        windows=windows,
    )

# ---------------------------------------------------------------------------
# Command Code — commandcode.ai backend API
# ---------------------------------------------------------------------------

def _load_commandcode_api_key() -> str | None:
    """Read the Command Code CLI (``cmd``) API key from ~/.commandcode/auth.json."""
    if not COMMANDCODE_AUTH_PATH.is_file():
        log.debug("Command Code auth not found at %s", COMMANDCODE_AUTH_PATH)
        return None

    try:
        data = json.loads(COMMANDCODE_AUTH_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("Failed to read Command Code auth file: %s", exc)
        return None

    api_key = data.get("apiKey")
    if not api_key:
        log.warning("No apiKey in Command Code auth file")
        return None
    return api_key


def _commandcode_request(
    path: str, api_key: str, params: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """GET a commandcode.ai backend endpoint using the CLI's bearer API key."""
    url = f"{COMMANDCODE_API_BASE}{path}"
    if params:
        query = urllib.parse.urlencode(
            {k: v for k, v in params.items() if v is not None},
        )
        if query:
            url = f"{url}?{query}"

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "User-Agent": "command-code-cli",
        "Accept": "application/json",
    }
    req = urllib.request.Request(url, headers=headers, method="GET")

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        log.warning("Command Code API %s returned HTTP %d", path, exc.code)
        return None
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        log.warning("Command Code API request to %s failed: %s", path, exc)
        return None


def _commandcode_plan_key(plan_id: str) -> str | None:
    """Match a (possibly versioned) plan ID against the known plan prefixes."""
    normalized = plan_id.lower().replace("_", "-")
    for key in _COMMANDCODE_PLAN_KEYS:
        if normalized.startswith(key):
            return key
    return None


def _commandcode_plan_label(plan_id: str) -> str:
    """Derive a human-friendly plan label from the subscription planId."""
    if not plan_id:
        return "Unknown"
    key = _commandcode_plan_key(plan_id)
    if key:
        return _COMMANDCODE_PLAN_LABELS[key]
    return plan_id.replace("-", " ").title()


def collect_commandcode() -> ServiceStatus | None:
    """Collect Command Code CLI (``cmd``) quota data.

    Returns a ServiceStatus on success, or None if Command Code is not
    configured / credentials are missing.
    """
    api_key = _load_commandcode_api_key()
    if api_key is None:
        return None

    whoami = _commandcode_request("/alpha/whoami", api_key)
    org_id = (whoami.get("org") or {}).get("id") if whoami else None

    credits = _commandcode_request(
        "/alpha/billing/credits", api_key, {"orgId": org_id},
    )
    if credits is None:
        return ServiceStatus(
            id="commandcode",
            name="Command Code",
            status="error",
            error="Usage endpoint unavailable",
        )

    subscription = _commandcode_request(
        "/alpha/billing/subscriptions", api_key, {"orgId": org_id},
    )
    plan_id = (subscription.get("data") or {}).get("planId", "") if subscription else ""
    plan = _commandcode_plan_label(plan_id)

    windows: list[UsageWindow] = []
    worst_status = "ok"

    window_limits = credits.get("windowLimits") or {}
    if window_limits.get("limited"):
        for key, label in (("fiveHour", "5h rolling"), ("weekly", "weekly")):
            win = window_limits.get(key) or {}
            cap = win.get("cap") or 0
            if cap <= 0:
                continue
            pct = round(min(100.0, win.get("used", 0) / cap * 100), 1)
            resets_at = None
            reset_ms = win.get("resetAt")
            if reset_ms:
                resets_at = datetime.fromtimestamp(
                    reset_ms / 1000, tz=timezone.utc,
                ).isoformat()
            windows.append(UsageWindow(name=label, used_pct=pct, resets_at=resets_at))
            s = _status_from_utilization(pct)
            if _status_severity(s) > _status_severity(worst_status):
                worst_status = s

    # Plans without a 5h/weekly rate cap deplete a monthly credit pool instead —
    # fall back to that as a single window.
    if not windows:
        remaining = (credits.get("credits") or {}).get("monthlyCredits")
        key = _commandcode_plan_key(plan_id)
        total = _COMMANDCODE_PLAN_CREDITS.get(key) if key else None
        if remaining is not None and total:
            pct = round(min(100.0, max(0.0, (total - remaining) / total * 100)), 1)
            windows.append(UsageWindow(name="monthly credits", used_pct=pct))
            worst_status = _status_from_utilization(pct)

    return ServiceStatus(
        id="commandcode",
        name="Command Code",
        plan=plan,
        status=worst_status,
        windows=windows,
    )

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _serialize(obj: Any) -> Any:
    """Custom serializer for dataclasses."""
    if hasattr(obj, "__dataclass_fields__"):
        d = asdict(obj)
        # Remove None values for cleaner output
        return {k: v for k, v in d.items() if v is not None}
    return obj


def run() -> None:
    log.info("QuotaHub collector starting")

    services: list[ServiceStatus] = []

    # Claude Code
    try:
        claude = collect_claude_code()
        services.append(claude)
        log.info("Claude Code: status=%s, windows=%d", claude.status, len(claude.windows))
    except Exception:
        log.exception("Unexpected error collecting Claude Code data")
        services.append(ServiceStatus(
            id="claude_code",
            name="Claude Code",
            status="error",
            error="Collector crashed",
        ))

    # Antigravity (may produce multiple services)
    try:
        agy_services = collect_antigravity()
        for svc in agy_services:
            services.append(svc)
            log.info("%s: status=%s, windows=%d", svc.name, svc.status, len(svc.windows))
    except Exception:
        log.exception("Unexpected error collecting Antigravity data")

    # Codex
    try:
        codex = collect_codex()
        if codex is not None:
            services.append(codex)
            log.info("Codex: status=%s, windows=%d", codex.status, len(codex.windows))
    except Exception:
        log.exception("Unexpected error collecting Codex data")

    # Command Code
    try:
        commandcode = collect_commandcode()
        if commandcode is not None:
            services.append(commandcode)
            log.info(
                "Command Code: status=%s, windows=%d",
                commandcode.status, len(commandcode.windows),
            )
    except Exception:
        log.exception("Unexpected error collecting Command Code data")

    output = CollectorOutput(
        updated_at=datetime.now(timezone.utc).isoformat(),
        services=services,
    )

    # Serialize
    payload = json.loads(json.dumps(asdict(output), default=_serialize))
    # Strip None values from nested structures
    for svc in payload.get("services", []):
        if svc.get("error") is None:
            svc.pop("error", None)
        for win in svc.get("windows", []):
            for k in list(win.keys()):
                if win[k] is None:
                    del win[k]

    # Write atomically
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    tmp_path = OUTPUT_FILE.with_suffix(".tmp")
    try:
        tmp_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        tmp_path.replace(OUTPUT_FILE)
        log.info("Wrote %s", OUTPUT_FILE)
    except OSError as exc:
        log.error("Failed to write output: %s", exc)
        sys.exit(1)


if __name__ == "__main__":
    run()

#!/usr/bin/env python3
"""Launch reverse-engineering agents across Claude, OpenAI, and a local QWEN model.

Each agent gets the same context (APK scan results, existing protocol docs, meta-prompt)
and works on its own git branch.  Results (transcripts + specs) are saved to a
configurable transcripts repo.
"""

import json
import logging
import re
import subprocess
import textwrap
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from config import DEFAULT_OPENAI_BASE_URL, ModelConfig, MAX_TOKENS

log = logging.getLogger("re_agents")


@dataclass
class AgentTask:
    """A reverse-engineering task to hand to each model."""
    package_id: str
    target_id: str
    apk_path: str
    scan_summary: str
    uuids_found: list[str] = field(default_factory=list)
    device_class: str = "unknown"
    transport: str = "BLE"
    is_flutter: bool = False


@dataclass
class AgentResult:
    agent_name: str          # "claude" | "openai" | "local-qwen"
    model: str
    target_id: str
    branch_name: str
    transcript_path: str
    spec_path: str = ""
    success: bool = False
    error: str = ""
    duration_seconds: float = 0.0


def _build_system_prompt(meta_prompt_path: Path) -> str:
    """Build the system prompt from the agent meta-prompt."""
    if meta_prompt_path.exists():
        return meta_prompt_path.read_text()
    return "You are a reverse engineering agent for IoT Bluetooth devices."


def _build_user_prompt(task: AgentTask, protocol_hints_path: Optional[Path] = None) -> str:
    """Build the user prompt with all context for the RE task."""
    uuid_list = "\n".join(f"  - {u}" for u in task.uuids_found) if task.uuids_found else "  (none extracted yet)"

    protocol_hints = ""
    if protocol_hints_path and protocol_hints_path.exists():
        raw = protocol_hints_path.read_text(errors="replace")[:15000]
        protocol_hints = f"\n## Protocol hints from static analysis\n```\n{raw}\n```\n"

    flutter_note = ""
    if task.is_flutter:
        flutter_note = textwrap.dedent("""\

        ## Flutter App Note
        This APK is a Flutter application. The BLE communication likely uses a Flutter
        plugin (flutter_blue_plus, flutter_reactive_ble, etc.) which bridges to native
        Android BLE APIs. Look for:
        - Dart string constants containing UUIDs in the decompiled output
        - Plugin channel method calls related to BLE operations
        - The underlying native BLE calls may be wrapped in plugin bridge code
        - Flutter assets directory may contain useful configuration files
        """)

    return textwrap.dedent(f"""\
    # Reverse Engineering Task: {task.target_id}

    ## Target Information
    - Package ID: {task.package_id}
    - Target ID: {task.target_id}
    - Device class: {task.device_class}
    - Transport: {task.transport}
    - APK path: {task.apk_path}

    ## BT Scan Summary
    {task.scan_summary}

    ## Custom UUIDs Found
    {uuid_list}
    {protocol_hints}{flutter_note}
    ## Your Task
    1. Analyze the decompiled APK output for BLE/Bluetooth protocol details.
    2. Identify all GATT services, characteristics, and their purposes.
    3. Document the message format (opcodes, payloads, CRC/checksums).
    4. Identify device advertising names and connection flow.
    5. Produce a device spec in YAML format following the OpenGreenIoT schema.
    6. Produce a human-readable protocol document.

    ## Output Format
    Return your analysis as two sections:

    ### SPEC_YAML
    ```yaml
    # OpenGreenIoT device spec
    ...
    ```

    ### PROTOCOL_DOC
    ```markdown
    # Protocol documentation
    ...
    ```

    Focus on derived facts only.  Do NOT include vendor source code or UI copy.
    Separate known facts from hypotheses.
    """)


# ── API call helpers ──────────────────────────────────────

def _call_api_curl(url: str, headers: dict[str, str], payload: dict) -> tuple[str, float]:
    """Generic curl-based API call.  Returns (response_body, duration_seconds)."""
    header_args: list[str] = []
    for k, v in headers.items():
        header_args += ["-H", f"{k}: {v}"]

    t0 = time.monotonic()
    result = subprocess.run(
        ["curl", "-s", "-X", "POST", url, *header_args,
         "-H", "content-type: application/json",
         "-d", json.dumps(payload)],
        capture_output=True, timeout=600,
    )
    duration = time.monotonic() - t0

    body = result.stdout.decode(errors="replace")
    return body, duration


def _call_anthropic(system: str, user: str, model: str, api_key: str) -> tuple[str, float]:
    """Call the Anthropic API.  Returns (response_text, duration_seconds)."""
    try:
        import anthropic
    except ImportError:
        # Fall back to curl
        payload = {
            "model": model,
            "max_tokens": MAX_TOKENS,
            "system": system,
            "messages": [{"role": "user", "content": user}],
        }
        body, duration = _call_api_curl(
            "https://api.anthropic.com/v1/messages",
            {"x-api-key": api_key, "anthropic-version": "2023-06-01"},
            payload,
        )
        try:
            resp = json.loads(body)
        except (json.JSONDecodeError, TypeError):
            log.warning("Anthropic curl response not valid JSON: %s", body[:200])
            return "", duration
        content = resp.get("content") or []
        text = content[0].get("text", "") if content else ""
        return text, duration

    client = anthropic.Anthropic(api_key=api_key)
    t0 = time.monotonic()
    message = client.messages.create(
        model=model,
        max_tokens=MAX_TOKENS,
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    duration = time.monotonic() - t0
    text = message.content[0].text if message.content else ""
    return text, duration


def _call_openai(system: str, user: str, model: str, api_key: str,
                 base_url: str = DEFAULT_OPENAI_BASE_URL) -> tuple[str, float]:
    """Call an OpenAI-compatible API.  Works for OpenAI, ollama, vllm, etc."""
    try:
        import openai
    except ImportError:
        # Fall back to curl
        payload = {
            "model": model,
            "max_tokens": MAX_TOKENS,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        }
        body, duration = _call_api_curl(
            f"{base_url}/chat/completions",
            {"Authorization": f"Bearer {api_key}"},
            payload,
        )
        try:
            resp = json.loads(body)
        except (json.JSONDecodeError, TypeError):
            log.warning("OpenAI curl response not valid JSON: %s", body[:200])
            return "", duration
        choices = resp.get("choices") or []
        text = choices[0].get("message", {}).get("content", "") if choices else ""
        return text, duration

    client = openai.OpenAI(api_key=api_key, base_url=base_url)
    t0 = time.monotonic()
    completion = client.chat.completions.create(
        model=model,
        max_tokens=MAX_TOKENS,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    )
    duration = time.monotonic() - t0
    text = completion.choices[0].message.content or ""
    return text, duration


# ── Output helpers ────────────────────────────────────────

def _save_transcript(
    transcripts_dir: Path,
    agent_name: str,
    target_id: str,
    system_prompt: str,
    user_prompt: str,
    response: str,
    duration: float,
) -> Path:
    """Save the full transcript to the transcripts directory."""
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    out_dir = transcripts_dir / target_id / agent_name
    out_dir.mkdir(parents=True, exist_ok=True)
    transcript_path = out_dir / f"{ts}_transcript.md"

    content = textwrap.dedent(f"""\
    # RE Transcript: {target_id} — {agent_name}
    Generated: {datetime.now(timezone.utc).isoformat()}
    Duration: {duration:.1f}s

    ## System Prompt
    ```
    {system_prompt[:2000]}...
    ```

    ## User Prompt
    ```
    {user_prompt[:3000]}...
    ```

    ## Agent Response
    {response}
    """)

    transcript_path.write_text(content)
    return transcript_path


def _extract_spec_yaml(response: str) -> str:
    """Extract the SPEC_YAML block from an agent response."""
    match = re.search(r"### *SPEC_YAML.*?```ya?ml\s*\n(.*?)```", response, re.DOTALL | re.IGNORECASE)
    if match:
        return match.group(1).strip()
    # Fallback: any yaml code block
    match = re.search(r"```ya?ml\s*\n(.*?)```", response, re.DOTALL)
    if match:
        return match.group(1).strip()
    return ""


def _extract_protocol_doc(response: str) -> str:
    """Extract the PROTOCOL_DOC block from an agent response."""
    match = re.search(r"### *PROTOCOL_DOC.*?```(?:markdown|md)?\s*\n(.*?)```", response, re.DOTALL | re.IGNORECASE)
    if match:
        return match.group(1).strip()
    return ""


# ── Agent execution ───────────────────────────────────────

def run_agent(
    agent_name: str,
    task: AgentTask,
    root_dir: Path,
    transcripts_dir: Path,
    model: str,
    api_key: str,
    base_url: str = "",
    protocol_hints_path: Optional[Path] = None,
) -> AgentResult:
    """Run a single RE agent and return its result."""
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    branch_name = f"re-agent/{agent_name}/{task.target_id}/{ts}"

    result = AgentResult(
        agent_name=agent_name,
        model=model,
        target_id=task.target_id,
        branch_name=branch_name,
        transcript_path="",
    )

    meta_prompt_path = root_dir / "prompts" / "AGENT_META_PROMPT.md"
    system_prompt = _build_system_prompt(meta_prompt_path)
    user_prompt = _build_user_prompt(task, protocol_hints_path)

    try:
        if agent_name == "claude":
            response, duration = _call_anthropic(system_prompt, user_prompt, model, api_key)
        else:
            url = base_url or DEFAULT_OPENAI_BASE_URL
            response, duration = _call_openai(system_prompt, user_prompt, model, api_key, url)

        result.duration_seconds = duration

        # Save transcript
        transcript_path = _save_transcript(
            transcripts_dir, agent_name, task.target_id,
            system_prompt, user_prompt, response, duration,
        )
        result.transcript_path = str(transcript_path)

        # Extract structured outputs
        spec_yaml = _extract_spec_yaml(response)
        protocol_doc = _extract_protocol_doc(response)

        if spec_yaml or protocol_doc:
            result.success = True
            if spec_yaml:
                spec_dir = root_dir / "device-specs" / "candidates"
                spec_dir.mkdir(parents=True, exist_ok=True)
                spec_path = spec_dir / f"{task.target_id}_{agent_name}.yaml"
                spec_path.write_text(spec_yaml)
                result.spec_path = str(spec_path)

            if protocol_doc:
                doc_dir = root_dir / "docs" / "devices" / "candidates"
                doc_dir.mkdir(parents=True, exist_ok=True)
                doc_path = doc_dir / f"{task.target_id}_{agent_name}.md"
                doc_path.write_text(protocol_doc)

        log.info("[%s/%s] %s in %.1fs (spec=%d chars, doc=%d chars)",
                 agent_name, task.target_id,
                 "SUCCESS" if result.success else "NO_OUTPUT",
                 duration, len(spec_yaml), len(protocol_doc))

    except Exception as exc:
        result.error = str(exc)
        log.error("[%s/%s] agent failed: %s", agent_name, task.target_id, exc)

    return result


def launch_all_agents(
    task: AgentTask,
    root_dir: Path,
    transcripts_dir: Path,
    models: ModelConfig,
    protocol_hints_path: Optional[Path] = None,
) -> list[AgentResult]:
    """Launch all three RE agents sequentially and collect results."""
    results: list[AgentResult] = []

    for agent_name, model, api_key, base_url in models.agent_configs():
        if not api_key and agent_name != "local-qwen":
            log.warning("Skipping %s: no API key configured", agent_name)
            continue
        r = run_agent(
            agent_name=agent_name,
            task=task,
            root_dir=root_dir,
            transcripts_dir=transcripts_dir,
            model=model,
            api_key=api_key,
            base_url=base_url,
            protocol_hints_path=protocol_hints_path,
        )
        results.append(r)

    return results


if __name__ == "__main__":
    import sys
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    if len(sys.argv) < 2:
        print("Usage: re_agents.py <task_json>")
        print("  task_json: JSON string or path to JSON file with AgentTask fields")
        sys.exit(1)

    task_input = sys.argv[1]
    if Path(task_input).is_file():
        task_data = json.loads(Path(task_input).read_text())
    else:
        task_data = json.loads(task_input)

    task = AgentTask(**task_data)
    root = Path(__file__).resolve().parents[2]

    from config import ResolvedPaths, load_config
    cfg = load_config()
    mc = ModelConfig.from_cfg(cfg)
    paths = ResolvedPaths.from_cfg(cfg)
    transcripts = paths.transcripts_dir

    results = launch_all_agents(task=task, root_dir=root, transcripts_dir=transcripts, models=mc)
    for r in results:
        print(json.dumps(asdict(r), indent=2))

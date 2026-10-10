#!/usr/bin/python3
"""Cursor hook for Pressure. Records agent and subagent progress. Always allows the action."""

import json
import os
import sys
import time

try:
    import fcntl
except ImportError:
    fcntl = None

STATUS_PATH = os.path.expanduser("~/Library/Application Support/Pressure/cursor-activity.json")
KEEP_FINISHED_SECONDS = 120
STALE_RUNNING_SECONDS = 180


def clip(value, limit=90):
    text = " ".join(str(value or "").split())
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def empty_state():
    return {"updatedAt": 0, "sessions": {}, "agents": {}}


def load_state():
    try:
        with open(STATUS_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return empty_state()
    if not isinstance(data, dict):
        return empty_state()
    data.setdefault("sessions", {})
    data.setdefault("agents", {})
    if not isinstance(data["sessions"], dict):
        data["sessions"] = {}
    if not isinstance(data["agents"], dict):
        data["agents"] = {}
    return data


def save_state(data):
    directory = os.path.dirname(STATUS_PATH)
    os.makedirs(directory, exist_ok=True)
    temporary = STATUS_PATH + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        if fcntl is not None:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        json.dump(data, handle, separators=(",", ":"))
        handle.write("\n")
    os.replace(temporary, STATUS_PATH)


def workspace_name(payload):
    roots = payload.get("workspace_roots") or []
    if isinstance(roots, list) and roots:
        return clip(os.path.basename(str(roots[0]).rstrip("/")) or "Cursor", 40)
    return "Cursor"


def session_id(payload):
    return str(payload.get("conversation_id") or payload.get("session_id") or "")


def begin_work(session, now):
    if not isinstance(session, dict):
        return
    session["phase"] = "working"
    session["updatedAt"] = now
    session.pop("finishedAt", None)


def mark_done(session, now, step=None):
    if not isinstance(session, dict):
        return
    session["phase"] = "done"
    session["finishedAt"] = now
    session["updatedAt"] = now
    if step:
        session["step"] = step


def touch_session(data, payload, now):
    sid = session_id(payload)
    if not sid or sid in data["agents"]:
        return None
    session = data["sessions"].get(sid)
    if not isinstance(session, dict):
        session = {
            "title": workspace_name(payload),
            "phase": "working",
            "step": "Working",
            "toolCount": 0,
            "contextPercent": None,
            "updatedAt": now,
        }
        data["sessions"][sid] = session
    session["updatedAt"] = now
    return session


def step_from_tool(payload):
    message = payload.get("agent_message")
    if isinstance(message, str) and message.strip():
        return clip(message)
    name = str(payload.get("tool_name") or "Working")
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    if name == "Shell":
        description = tool_input.get("description") or ""
        if str(description).strip():
            return clip(description)
        command = str(tool_input.get("command") or "").strip()
        first = command.splitlines()[0] if command else "Shell"
        return clip(first)
    if name in ("Read", "Write", "Delete", "Grep", "Glob"):
        path = (
            tool_input.get("path")
            or tool_input.get("file_path")
            or tool_input.get("glob_pattern")
            or tool_input.get("pattern")
            or ""
        )
        label = os.path.basename(str(path)) if path else name
        return clip("%s %s" % (name, label))
    if name == "Task":
        return clip(tool_input.get("description") or tool_input.get("prompt") or "Starting a subagent")
    return clip(name)


def attribute_step(data, payload, step, now, count_tool=False):
    sid = session_id(payload)
    session = touch_session(data, payload, now)
    if session is not None:
        begin_work(session, now)
        session["step"] = step
        if count_tool:
            session["toolCount"] = int(session.get("toolCount") or 0) + 1
    agent = data["agents"].get(sid) if sid else None
    if isinstance(agent, dict) and agent.get("status") == "running":
        agent["step"] = step
        agent["updatedAt"] = now
        if count_tool:
            agent["toolCount"] = int(agent.get("toolCount") or 0) + 1
        return
    if not sid:
        return
    children = [
        item
        for item in data["agents"].values()
        if isinstance(item, dict) and item.get("status") == "running" and item.get("parent") == sid
    ]
    if len(children) == 1:
        children[0]["step"] = step
        children[0]["updatedAt"] = now
        if count_tool:
            children[0]["toolCount"] = int(children[0].get("toolCount") or 0) + 1


def finish_agent(data, payload, now):
    task = str(payload.get("task") or "")
    kind = str(payload.get("subagent_type") or "")
    status = str(payload.get("status") or "completed")
    match = None
    for agent_id, agent in data["agents"].items():
        if not isinstance(agent, dict) or agent.get("status") != "running":
            continue
        if task and agent.get("task") == task:
            match = agent_id
            break
    if match is None:
        same_kind = [
            agent_id
            for agent_id, agent in data["agents"].items()
            if isinstance(agent, dict) and agent.get("status") == "running" and agent.get("kind") == kind
        ]
        if len(same_kind) == 1:
            match = same_kind[0]
    if match is None:
        running = [
            (agent.get("updatedAt") or 0, agent_id)
            for agent_id, agent in data["agents"].items()
            if isinstance(agent, dict) and agent.get("status") == "running"
        ]
        if running:
            running.sort()
            match = running[-1][1]
    if match is None:
        return
    agent = data["agents"][match]
    agent["status"] = status
    agent["finishedAt"] = now
    summary = clip(payload.get("summary") or payload.get("description") or agent.get("step") or status)
    agent["step"] = summary
    if payload.get("tool_call_count") is not None:
        agent["toolCount"] = int(payload.get("tool_call_count") or 0)
    agent["updatedAt"] = now


def record_usage(session, payload):
    """Keep one token snapshot for this turn. stop and afterAgentResponse share a generation."""
    if not isinstance(session, dict):
        return
    fields = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")
    if not any(isinstance(payload.get(name), (int, float)) for name in fields):
        return
    usage = {"model": str(payload.get("model") or payload.get("model_id") or ""), "fast": is_fast(payload)}
    generation = str(payload.get("generation_id") or "")
    if generation:
        usage["generation"] = generation
    for key, name in (
        ("input", "input_tokens"),
        ("output", "output_tokens"),
        ("cacheRead", "cache_read_tokens"),
        ("cacheWrite", "cache_write_tokens"),
    ):
        value = payload.get(name)
        if isinstance(value, (int, float)):
            usage[key] = int(value)
    session["usage"] = usage


def is_fast(payload):
    model = str(payload.get("model") or "").lower()
    if "fast" in model:
        return True
    params = payload.get("model_params")
    if not isinstance(params, list):
        return False
    for item in params:
        if not isinstance(item, dict) or str(item.get("id") or "") != "fast":
            continue
        return str(item.get("value") or "").lower() in ("true", "1", "yes")
    return False


def prune(data, now):
    stale_sessions = []
    for sid, session in data["sessions"].items():
        if not isinstance(session, dict):
            stale_sessions.append(sid)
            continue
        age = now - float(session.get("updatedAt") or 0)
        if session.get("phase") != "working" and age > KEEP_FINISHED_SECONDS:
            stale_sessions.append(sid)
        elif session.get("phase") == "working" and age > STALE_RUNNING_SECONDS:
            session["phase"] = "idle"
            session["step"] = "Stopped responding"
    for sid in stale_sessions:
        data["sessions"].pop(sid, None)
    stale_agents = []
    for agent_id, agent in data["agents"].items():
        if not isinstance(agent, dict):
            stale_agents.append(agent_id)
            continue
        age = now - float(agent.get("updatedAt") or 0)
        if agent.get("status") == "running" and age > STALE_RUNNING_SECONDS:
            agent["status"] = "aborted"
            agent["step"] = "Stopped responding"
            agent["updatedAt"] = now
        elif agent.get("status") != "running" and age > KEEP_FINISHED_SECONDS:
            stale_agents.append(agent_id)
    for agent_id in stale_agents:
        data["agents"].pop(agent_id, None)


def apply(payload):
    event = str(payload.get("hook_event_name") or "")
    now = time.time()
    data = load_state()
    prune(data, now)
    if event == "sessionStart":
        session = touch_session(data, payload, now)
        if session is not None:
            begin_work(session, now)
            session["title"] = workspace_name(payload)
            session["step"] = "Starting"
            session["toolCount"] = 0
    elif event == "beforeSubmitPrompt":
        session = touch_session(data, payload, now)
        if session is not None:
            prompt = clip(payload.get("prompt") or "", 80)
            begin_work(session, now)
            session["title"] = workspace_name(payload)
            session["step"] = prompt or "Working"
            session.pop("usage", None)
            if prompt:
                session["prompt"] = prompt
    elif event == "subagentStart":
        agent_id = str(payload.get("subagent_id") or "")
        parent = str(payload.get("parent_conversation_id") or session_id(payload) or "")
        if agent_id:
            task = str(payload.get("task") or "")
            name = clip(task.splitlines()[0] if task else payload.get("subagent_type") or "Subagent", 60)
            data["agents"][agent_id] = {
                "name": name,
                "kind": str(payload.get("subagent_type") or ""),
                "status": "running",
                "step": "Starting",
                "parent": parent,
                "toolCount": 0,
                "updatedAt": now,
                "task": task,
            }
        session = data["sessions"].get(parent)
        if isinstance(session, dict):
            begin_work(session, now)
            session["step"] = name if agent_id else "Starting a subagent"
    elif event == "subagentStop":
        finish_agent(data, payload, now)
    elif event in ("preToolUse", "postToolUse", "postToolUseFailure"):
        if event == "postToolUseFailure":
            step = clip(payload.get("error_message") or step_from_tool(payload))
        else:
            step = step_from_tool(payload)
        attribute_step(data, payload, step, now, count_tool=(event == "postToolUse"))
    elif event == "preCompact":
        session = touch_session(data, payload, now)
        if session is not None:
            percent = payload.get("context_usage_percent")
            if isinstance(percent, (int, float)):
                session["contextPercent"] = int(percent)
            begin_work(session, now)
            session["step"] = "Compacting context"
    elif event == "afterAgentThought":
        session = touch_session(data, payload, now)
        if session is not None:
            begin_work(session, now)
            session["step"] = "Thinking"
    elif event == "afterAgentResponse":
        session = touch_session(data, payload, now)
        text = clip(payload.get("text") or "", 80)
        mark_done(session, now, text or "Done")
        record_usage(session, payload)
    elif event == "stop":
        session = touch_session(data, payload, now)
        record_usage(session, payload)
        status = str(payload.get("status") or "completed")
        if status == "completed":
            mark_done(session, now, "Done")
        elif session is not None:
            session["phase"] = status
            session["finishedAt"] = now
            session["updatedAt"] = now
            session["step"] = status.capitalize()
        sid = session_id(payload)
        for agent in data["agents"].values():
            if isinstance(agent, dict) and agent.get("parent") == sid and agent.get("status") == "running":
                agent["status"] = "aborted" if status == "aborted" else "completed"
                agent["finishedAt"] = now
                agent["updatedAt"] = now
    elif event == "sessionEnd":
        sid = str(payload.get("session_id") or session_id(payload) or "")
        session = data["sessions"].get(sid)
        if isinstance(session, dict):
            reason = str(payload.get("reason") or "completed")
            session["phase"] = "done" if reason == "completed" else reason
            session["finishedAt"] = now
            session["step"] = "Closed" if reason in ("completed", "user_close", "window_close") else reason
            session["updatedAt"] = now
    data["updatedAt"] = now
    save_state(data)


def reply(event):
    if event == "beforeSubmitPrompt":
        return {"continue": True}
    if event in ("preToolUse", "subagentStart"):
        return {"permission": "allow"}
    return {}


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    try:
        apply(payload)
    except Exception:
        pass
    json.dump(reply(str(payload.get("hook_event_name") or "")), sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()

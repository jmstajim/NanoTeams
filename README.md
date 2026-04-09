# NanoTeams

[![Build&Test](https://github.com/jmstajim/NanoTeams/actions/workflows/ios.yml/badge.svg)](https://github.com/jmstajim/NanoTeams/actions/workflows/ios.yml)
[![Version](https://img.shields.io/github/v/release/jmstajim/NanoTeams?sort=semver&display_name=tag&label=version&color=5F87D9&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/jmstajim/NanoTeams/total?label=downloads&color=5F87D9&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)
[![macOS](https://img.shields.io/badge/macOS_15.0+-5F87D9?logo=apple&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)
[![Swift](https://img.shields.io/badge/Swift-5F87D9?logo=swift&logoColor=white&style=flat-square)](https://github.com/jmstajim/NanoTeams)
[![License](https://img.shields.io/github/license/jmstajim/NanoTeams?color=5F87D9&style=flat-square)](LICENSE)
[![Download](https://img.shields.io/badge/Download-NanoTeams.app.zip-35BE81?style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)

**Native macOS app for AI agent teams and chat powered by local LLMs.** No cloud. No API keys. No telemetry. Your data stays on your Mac.

<img width="640" height="604" alt="NanoTeams — AI agent teams for local LLMs on macOS" src="https://github.com/user-attachments/assets/aaf71be6-a72f-4f5d-bf77-47d015985f0e" />

## Why NanoTeams

NanoTeams was designed from the ground up for **local LLMs**. The goal is simple: make local language models work **as fast and efficiently as possible** in real tasks — multi-role collaboration, tool use, artifact pipelines, and real-time supervision, all running entirely on your machine.

Built with **LM Studio's stateful chat API** (`previous_response_id`), so the server doesn't reprocess the full conversation every turn. This means dramatically faster multi-step workflows compared to stateless approaches.

## Download & Installation

**[Download NanoTeams.app.zip](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)** · [All releases](https://github.com/jmstajim/NanoTeams/releases)

1. Download and extract `NanoTeams.app.zip`
2. Drag `NanoTeams.app` into Applications
3. If macOS blocks the app: System Settings → Privacy & Security → Open Anyway

> Requires **macOS 15.0+** and **[LM Studio 0.4.0+](https://lmstudio.ai)**

## Getting Started

1. Open **LM Studio** and load a model (see [Recommended Models](#recommended-models))
2. Launch **NanoTeams**
3. Select a work folder — this is where AI roles will read and write files
4. Pick a team (or start with **Personal Assistant** for a simple chat)
5. Create a task, describe what you need — the team takes it from there

<img width="640" height="633" alt="NanoTeams — create a new task and select a team" src="https://github.com/user-attachments/assets/d4de18bb-7cdd-4d21-8d72-7018136b8700" />

## How It Works

You are the **Supervisor**. You create a task, and a team of AI roles executes it step by step based on artifact dependencies.

For example, with the **FAANG Team**: you describe what you want → PM writes requirements → Tech Lead creates a plan → Engineer implements → Code Reviewer checks the code → SRE verifies production readiness → TPM writes release notes → you review and accept.

Each role can read/write files, use git, build with Xcode, consult other roles, and request team meetings — all within a sandboxed environment limited to your work folder.

<img width="640" height="491" alt="NanoTeams — team graph showing roles and artifact dependencies" src="https://github.com/user-attachments/assets/59e383b0-9393-4036-92d5-662c431a2d08" />

## Features

### Multi-Agent AI Teams
Create tasks and let a team of specialized AI roles collaborate. Each role has its own system prompt, tool access, and artifact responsibilities. Roles communicate through consultations, team meetings, and change requests.

<img width="640" height="453" alt="NanoTeams — activity feed with AI role messages and tool calls" src="https://github.com/user-attachments/assets/34f55b17-31d8-48d3-b3cb-c191a3f673fb" />

### 28 Built-in Tools
Sandboxed tool system: file operations, git, Xcode build & test, team collaboration (`ask_teammate`, `request_team_meeting`, `request_changes`), artifact creation, supervisor Q&A, persistent memory, and image analysis.

### Per-Role LLM & Vision Configuration
Assign different local models to different roles in the same team — a fast small model for the PM, a powerful coding model for the Engineer, a vision-capable model for image analysis. Each role can have its own base URL, model, max tokens, and temperature.

### Quick Capture
Two global hotkeys work from any app:
- **Ctrl+Opt+Cmd+0** — Floating overlay to create tasks, answer AI questions, or view status
- **Ctrl+Opt+Cmd+K** — Capture the current selection (text or files) and attach it to your task

<img width="441" height="455" alt="NanoTeams — Quick Capture overlay for creating tasks from any app" src="https://github.com/user-attachments/assets/48c6ac05-ff5f-49b8-9131-424a5b4f7acd" />

### Team Meetings & Change Requests
Roles consult each other for quick Q&A, hold multi-participant meetings with turn-based dialogue and voting, and request peer-to-peer revisions. Code Reviewer can request changes from the Engineer — the system creates a voting meeting, tallies votes, and re-executes with full context if approved.

### Artifact Dependency Pipeline
Roles produce and consume named artifacts (requirements, design specs, plans). Execution order is automatically determined from dependencies — no manual sequencing. A visual team graph shows the flow in real-time.

### Custom Teams
Create your own teams with custom roles, artifacts, prompts, dependencies, and hierarchy. Import/export as JSON.

### Privacy & Security
NanoTeams doesn't send your data anywhere. All processing happens locally via LM Studio. Debug logs are off by default. All file operations are sandboxed to the selected work folder — no arbitrary shell access.

## Built-in Teams

| Team | Description |
|------|-------------|
| **Personal Assistant** | Conversational AI helper for any task |
| **FAANG Team** | Full product pipeline: PM → UX → Engineering → Code Review → SRE → Release |
| **Engineering Team** | Lean pipeline: Tech Lead → Engineer → Code Review → Release |
| **Startup** | One engineer, full autonomy, fast iteration |
| **Quest Party** | Five specialists build a fantasy world, then the Quest Master runs an interactive adventure where you are the hero |
| **Discussion Club** | Five distinct personalities debate any topic in a lively multi-agent discussion |

## Recommended Models

NanoTeams has been trained on:
- **gpt-oss-20b** — strong general-purpose model for complex multi-step tasks
- **qwen3.5-9b** — fast and capable for quick iterations

Have a favorite local LLM? [Open an issue](https://github.com/jmstajim/NanoTeams/issues) — I'd love to make NanoTeams work better with it.

## Build from Source

```bash
git clone https://github.com/jmstajim/NanoTeams.git
cd NanoTeams
xcodebuild -project NanoTeams.xcodeproj -scheme NanoTeams -configuration Release build
```

No external dependencies required — pure Swift/SwiftUI.

## Support

For questions, issues, or feature requests — [open an issue](https://github.com/jmstajim/NanoTeams/issues) or reach out via [email](mailto:gusachenkoalexius@gmail.com) · [LinkedIn](https://www.linkedin.com/in/jmstajim/).

# NanoTeams

[![Build&Test](https://github.com/jmstajim/NanoTeams/actions/workflows/ios.yml/badge.svg)](https://github.com/jmstajim/NanoTeams/actions/workflows/ios.yml)
[![Version](https://img.shields.io/github/v/release/jmstajim/NanoTeams?sort=semver&display_name=tag&label=version&color=5F87D9&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/jmstajim/NanoTeams/total?label=downloads&color=5F87D9&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)
[![macOS](https://img.shields.io/badge/macOS_15.0+-5F87D9?logo=apple&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)
[![Swift](https://img.shields.io/badge/Swift-5F87D9?logo=swift&logoColor=white&style=flat-square)](https://github.com/jmstajim/NanoTeams)
[![License](https://img.shields.io/github/license/jmstajim/NanoTeams?color=5F87D9&style=flat-square)](LICENSE)
[![Download](https://img.shields.io/badge/Download-NanoTeams.app.zip-35BE81?style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)

**Agentic chat and multi-role AI teams for macOS.** Start a chat or hand a task to a team of specialized AI roles — they read your files, produce artifacts, consult each other, and report back when done. Generate teams on demand from a one-line description, attach documents, clip text from any app, dictate hands-free, queue messages to working roles without pausing them. Everything runs on-device — LLMs through LM Studio, dictation through Apple's built-in speech engine. No cloud, no API keys, zero telemetry.

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

## How Roles Work
Every role in a team falls into one of three types — this determines what the role does and how it finishes.

### Producing Roles
Most roles are producing — they create specific deliverables called artifacts. A PM produces "Product Requirements," an Engineer produces "Engineering Notes," a Code Reviewer produces "Code Review."

You don't need to do anything. The role works autonomously — reading files, using tools, consulting teammates — and finishes automatically once all its artifacts are submitted. You just watch the activity feed and review the results.

All roles in the FAANG, Engineering, and Startup teams are producing roles.

### Chat Roles
Some roles don't produce artifacts — instead, they talk to you. After reading upstream artifacts (or just your task description), the role enters an open-ended conversation loop, asking you questions and responding to your answers.

The role never finishes on its own. It keeps the conversation going until you pause or close the task. This is how the Personal Assistant works — pure back-and-forth dialogue. In the Quest Party, the Quest Master reads all the world-building artifacts from other roles, then runs an interactive adventure where you play the hero.

When a team has no required deliverables for the Supervisor, the UI switches to Chat mode — you'll see a "Chat" label instead of "Working" or "Review."

### Observer Roles
A few roles have no artifacts at all — they don't produce anything and don't depend on anything. They sit in the team graph but don't run on their own. Instead, they come alive when invited to team meetings, contributing their perspective to group discussions.

In the Discussion Club, four personality roles (The Open, The Conscientious, The Extrovert, The Neurotic) are observers — only The Agreeable runs as a producing role, kicking off meetings where all five debate the topic together.

## Features

### Multi-Agent AI Teams
Create tasks and let a team of specialized AI roles collaborate. Each role has its own system prompt, tool access, and artifact responsibilities. Roles communicate through consultations, team meetings, and change requests.

<img width="640" height="453" alt="NanoTeams — activity feed with AI role messages and tool calls" src="https://github.com/user-attachments/assets/34f55b17-31d8-48d3-b3cb-c191a3f673fb" />

### AI Team Generation
Describe a task in one line and an LLM designs a custom team for it — roles, artifacts, prompts, dependencies, and hierarchy. The *Generate Team* settings tab lets you customize the meta-model, system prompt, and defaults used whenever a team is generated.

### 28 Built-in Tools
Sandboxed tool system: file operations, git, Xcode build & test, team collaboration (`ask_teammate`, `request_team_meeting`, `request_changes`), artifact creation, supervisor Q&A, persistent memory, and image analysis.

### Documents In & Out
Roles read PDF, DOCX, RTF, XLSX, PPTX, ODT, and HTML files directly — no manual conversion to plain text. Generated artifacts can be exported to PDF, Word, or RTF. Document handling is pure-Swift.

### Universal Search
Search across PDFs, Word documents, spreadsheets, slides, OpenDocument files, HTML, source code, and plain text — all from a single tool call. Results are capped to keep agent context clean and prevent search-result poisoning.

### Per-Role LLM & Vision Configuration
Assign different local models to different roles in the same team — a fast small model for the PM, a powerful coding model for the Engineer, a vision-capable model for image analysis. Each role can have its own base URL, model, max tokens, and temperature.

### Quick Capture
Two global hotkeys work from any app:
- **Ctrl+Opt+Cmd+0** — Floating overlay to create chat/task, answer AI questions, or view status
- **Ctrl+Opt+Cmd+K** — Capture the current selection (text or files) and attach it to your chat/task

<img width="441" height="455" alt="NanoTeams — Quick Capture overlay for creating tasks from any app" src="https://github.com/user-attachments/assets/48c6ac05-ff5f-49b8-9131-424a5b4f7acd" />

### Private Voice Dictation
Hands-free input via Apple's `SpeechAnalyzer` and `DictationTranscriber` — fully on-device, multilingual, and offline. Available in Quick Capture, Supervisor answers, and revision feedback. Requires macOS 26+.

### Team Meetings & Change Requests
Roles consult each other for quick Q&A, hold multi-participant meetings with turn-based dialogue and voting, and request peer-to-peer revisions. Code Reviewer can request changes from the Engineer — the system creates a voting meeting, tallies votes, and re-executes with full context if approved.

### Supervisor Message Queue
Send guidance to working roles without pausing them. The unified Team Composer has a *To:* selector for targeting a specific role or the whole team, with consistent input across the Activity Feed, Watchtower, and Quick Capture. The *Correct Role* action lets you adjust a paused role's direction while preserving its progress so far.

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
- **[gpt-oss-20b](https://lmstudio.ai/models/openai/gpt-oss-20b)**
- **[qwen3.5-9b](https://lmstudio.ai/models/qwen/qwen3.5-9b)**
- **[gemma-4-26b-a4b](https://lmstudio.ai/models/google/gemma-4-26b-a4b)**
- **[qwen3.5-35b-a3b](https://lmstudio.ai/models/qwen/qwen3.5-35b-a3b)**

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

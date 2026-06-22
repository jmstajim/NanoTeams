# **NanoTeams**

### Open-source AI coding assistant and multi-agent teams for macOS — put your project on autopilot with local LLMs

[![Build&Test](https://github.com/jmstajim/NanoTeams/actions/workflows/ios.yml/badge.svg)](https://github.com/jmstajim/NanoTeams/actions/workflows/ios.yml)
[![Version](https://img.shields.io/github/v/release/jmstajim/NanoTeams?sort=semver&display_name=tag&label=version&color=5F87D9&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/jmstajim/NanoTeams/total?label=downloads&color=5F87D9&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)
[![macOS](https://img.shields.io/badge/macOS_15.0+-5F87D9?logo=apple&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)
[![Swift](https://img.shields.io/badge/Swift-5F87D9?logo=swift&logoColor=white&style=flat-square)](https://github.com/jmstajim/NanoTeams)
[![License](https://img.shields.io/github/license/jmstajim/NanoTeams?color=5F87D9&style=flat-square)](LICENSE)
[![Download](https://img.shields.io/badge/Download-NanoTeams.app.zip-35BE81?style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)

**AI coding assistant and multi-agent AI teams for macOS, powered by local LLMs through [LM Studio](https://lmstudio.ai).** Open-source, free, fully private. Start an agentic chat with the **Coding Assistant**, let the **Coding Agent** edit small changes directly and delegate the heavy lifting to another team ([Get started](#getting-started)), or hand a task to a team of specialized AI roles that read your files, produce artifacts, consult each other, and report back when done. Switch on the **Autovisor** and an automated Supervisor runs the whole folder for you — creating, answering, and reviewing tasks on its own. Generate custom teams from a one-line description, paste images and documents straight into the composer, search your project semantically with on-device embeddings, clip text from any app, dictate hands-free with fully on-device speech recognition, and queue messages to working roles without pausing them.

<img width="600" height="510" alt="NanoTeams — AI coding assistant and multi-agent AI teams for macOS" src="https://github.com/user-attachments/assets/c7549d11-abd9-4faf-94c3-6cefb6214394" />

## Why **NanoTeams**

The goal is simple: make local LLMs work **as fast and efficiently as possible** in real tasks — writing code, making decisions, organizing your thinking, drafting documents, and bringing ideas to life.

**NanoTeams** treats smaller models as the design constraint.

Stateful chat keeps things fast. The architecture forgives mistakes. Every piece of the program compensates for something local models don't do well.

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
4. Pick a team — **Coding Assistant** is the default and a good starting point (chat-mode with files, git, and Xcode tools); the new **Coding Agent** edits small changes itself and delegates bigger work to another team
5. Create a task, describe what you need — the team takes it from there

<img width="1280" height="1107" alt="NanoTeams — create a new task and select a team" src="https://github.com/user-attachments/assets/512ce4a7-34d6-40aa-a8d0-cd9bac47c569" />

## How It Works

You are the **Supervisor**. You create a task, and a team of AI roles executes it step by step based on artifact dependencies.

For example, with the **FAANG Team**: you describe what you want → PM writes requirements → Tech Lead creates a plan → Engineer implements → Code Reviewer checks the code → SRE verifies production readiness → TPM writes release notes → you review and accept.

Each role can read/write files, use git, build with Xcode, consult other roles, request team meetings, and delegate a self-contained sub-task to another team — all within a sandboxed environment limited to your work folder.

<img width="1280" height="1009" alt="NanoTeams — team graph showing roles and artifact dependencies" src="https://github.com/user-attachments/assets/9e75d4c2-4cda-43a9-812b-3abd20ed986d" />

## How Roles Work
Every role in a team falls into one of three types — this determines what the role does and how it finishes.

### Producing Roles
Most roles are producing — they create specific deliverables called artifacts. A PM produces "Product Requirements," an Engineer produces "Engineering Notes," a Code Reviewer produces "Code Review Summary."

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

<img width="1280" height="1049" alt="NanoTeams — activity feed with AI role messages and tool calls" src="https://github.com/user-attachments/assets/93b34c9e-9296-4c5c-9b3b-2e9d7adf576a" />

### Autovisor — Automated Supervisor
Flip one switch and an autonomous agent takes over your work folder. Give the **Autovisor** a goal and it watches every task, creates and schedules new ones, answers the questions roles would normally ask you, reviews finished work, and closes it — keeping a standing memory between passes. It wakes when a task needs input, fails, completes, is created, or looks stuck; when there's nothing to do it parks and waits. You can message it any time — your message continues its conversation. A sleep timer turns it off a set time after enabling, so an experiment can't run all night. Configure the goal, memory, triggers, schedule, and an optional dedicated model in **Settings → Autovisor**.

### AI Team Generation
Describe a task in one line and an LLM designs a custom team for it — roles, artifacts, prompts, dependencies, and hierarchy. The *Generate Team* settings tab lets you customize the meta-model, system prompt, and defaults used whenever a team is generated.

### Team Delegation
A peer-level role can hand a self-contained sub-task to another team and wait for its final artifacts to come back as the tool result. The ready-made example is the new **Coding Agent** team: it edits files directly for small, local changes and uses `delegate_to_team` to pass larger, multi-file work to another team — by default the **Engineering Team** or **Startup**, or a fresh team generated on the fly when nothing fits. While a delegation runs you can message the delegating role, which pauses the child team and lets the role choose `cancel_delegation`, `resume_delegation`, or `forward_to_team` to inject guidance and continue. Configure it per role in the *Delegation* tab of the role editor: check the allowed teams and/or toggle *Allow generating new teams on the fly* — selecting any target auto-injects the four-tool delegation pack and makes the role a peer of the Supervisor. Delegation chains are capped at depth 3, and each delegation times out after 30 minutes.

### Global Context
A single free-text box in **Settings → LLM** whose contents are appended to every LLM system prompt that runs a tool loop — step execution, teammate consultation, meetings, and planning. Use it for cross-cutting instructions you want every role in every team to follow. A character counter and a *Reset to Default* button are shown; edits apply to new sessions only, so a step already running keeps the value it started with.

### 43 Built-in Tools
Sandboxed tool system: file operations, git, Xcode build & test, team collaboration (`ask_teammate`, `request_team_meeting`, `request_changes`), team delegation (`delegate_to_team` with cancel/resume/forward follow-ups), team generation (`create_team`), task management for the Autovisor, artifact creation, supervisor Q&A, persistent memory, and image analysis.

### Documents In & Out
Roles read PDF, DOCX, RTF, XLSX, PPTX, ODT, and HTML files directly — no manual conversion to plain text. Generated artifacts can be exported to PDF, Word, or RTF.

### Universal Search
Keyword search across PDFs, Word documents, spreadsheets, slides, OpenDocument files, HTML, source code, and plain text — all from a single tool call.

### Exploratory Search (Semantic)
Optional vocab-vector embedding pipeline lets roles find code and prose by meaning, not just keywords — useful for navigating large codebases. Embeddings and the token index are computed and stored entirely on your machine; toggle and configure the embedding model in **Advanced Settings → Exploratory Search**.

### Per-Role LLM Configuration
Assign different local models to different roles in the same team — a fast small model for the PM, a powerful coding model for the Engineer. Each role can have its own base URL, model, max tokens, and temperature.

### Vision (Image Analysis)
Roles can analyze screenshots, diagrams, and photos using a separate vision-capable LLM via the `analyze_image` tool. Configure the vision server, model, and token budget independently of the main model — useful for keeping vision on a smaller, image-tuned model while text generation stays on a heavyweight coder.

### Quick Capture
Two global hotkeys work from any app:
- **Ctrl+Opt+Cmd+0** — Floating overlay to create chat/task, answer AI questions, or view status
- **Ctrl+Opt+Cmd+K** — Capture the current selection (text or files) and attach it to your chat/task

Cmd+V in the composer pastes anything from the clipboard — copied files (any kind, including PDFs / DOCX / source files), screenshots and images, or plain text. Files and images are staged as attachments; text drops into the message field.

<img width="936" height="988" alt="NanoTeams — Quick Capture overlay for creating tasks from any app" src="https://github.com/user-attachments/assets/519e1c86-8bac-40b6-89d0-a5c08827b0b4" />

### Private Voice Dictation
Hands-free input via Apple's `SpeechAnalyzer` and `DictationTranscriber` — fully on-device, multilingual, and offline. Available in Quick Capture, Supervisor answers, and revision feedback. Requires macOS 26+.

### Team Meetings & Change Requests
Roles consult each other for quick Q&A, hold multi-participant meetings with turn-based dialogue and voting, and request peer-to-peer revisions. Code Reviewer can request changes from the Engineer — the system creates a voting meeting, tallies votes, and re-executes with full context if approved.

### Supervisor Message Queue
Send guidance to working roles without pausing them. The unified Team Composer has a *To:* selector for targeting a specific role or the whole team, with consistent input across the Activity Feed, Watchtower, and Quick Capture. The *Correct Role* action lets you adjust a paused role's direction while preserving its progress so far. Messaging a paused or failed task resumes it — failed steps retry with their conversation intact.

### Scheduled & Recurring Tasks
Put any task on a timer from the **Automation** sheet: repeat on an **interval**, daily at a **time of day** (optionally limited to specific weekdays), **monthly** on a chosen day, or as a **one-shot** — with a live *Next run* preview. A companion **Run timeout** auto-pauses a run that overruns and notifies you, so a stuck model never blocks the schedule. A **Recurring** filter in the sidebar shows just your scheduled tasks.

### Artifact Dependency Pipeline
Roles produce and consume named artifacts (requirements, design specs, plans). Execution order is automatically determined from dependencies — no manual sequencing. A visual team graph shows the flow in real-time.

### Custom Teams
Create your own teams with custom roles, artifacts, prompts, dependencies, and hierarchy. Import/export as JSON. Role and system prompt templates are fully editable, with `{globalContext}` and `{toolCalling}` placeholder chips you can position anywhere in a template — leave them out and the global context and tool-calling block are appended automatically, so older templates keep working.

### Themes

### Privacy & Security
**NanoTeams** doesn't send your data anywhere. All processing happens locally via LM Studio. Debug logs are off by default. All file operations are sandboxed to the selected work folder — no arbitrary shell access.

## Built-in Teams

| Team | Description |
|------|-------------|
| **Coding Assistant** *(default)* | Dialog-first coding companion with files, git, and Xcode tools |
| **Coding Agent** | Hybrid coding agent: edits files directly for small changes, delegates complex implementation to a chosen team |
| **Personal Assistant** | Conversational AI helper for any task |
| **FAANG Team** | Full product pipeline: PM → UX → Engineering → Code Review → SRE → Release |
| **Engineering Team** | Lean pipeline: Tech Lead → Engineer → Code Review → Release |
| **Startup** | One engineer, full autonomy, fast iteration |
| **Quest Party** | Five specialists build a fantasy world, then the Quest Master runs an interactive adventure where you are the hero |
| **Discussion Club** | Five distinct personalities debate any topic in a lively multi-agent discussion |

## Recommended Models

**NanoTeams** has been trained on:
- **[gpt-oss-20b](https://lmstudio.ai/models/openai/gpt-oss-20b)**
- **[qwen3.5-9b](https://lmstudio.ai/models/qwen/qwen3.5-9b)**
- **[gemma-4-26b-a4b](https://lmstudio.ai/models/google/gemma-4-26b-a4b)**
- **[qwen3.5-35b-a3b](https://lmstudio.ai/models/qwen/qwen3.5-35b-a3b)**

Have a favorite local LLM? [Open an issue](https://github.com/jmstajim/NanoTeams/issues) — I'd love to make **NanoTeams** work better with it.

## Build from Source

```bash
git clone https://github.com/jmstajim/NanoTeams.git
cd NanoTeams
xcodebuild -project NanoTeams.xcodeproj -scheme NanoTeams -configuration Release build
```

No external dependencies required — pure Swift/SwiftUI.

## FAQ

**Is NanoTeams free?**
Yes. **NanoTeams** is open-source and free. There are no subscriptions, no API keys, and no usage limits. You only pay for the hardware your local LLM runs on.

**Does NanoTeams send my data anywhere?**
No. All inference runs locally through LM Studio on your Mac. Files, prompts, and tool calls never leave your machine. There is no telemetry and no account.

**Do I need an internet connection?**
No, after the initial download of LM Studio and a model. **NanoTeams** works fully offline — useful for travel, secure environments, or air-gapped machines.

**What models does NanoTeams support?**
Any model you can run in LM Studio. **NanoTeams** has been trained on `gpt-oss-20b`, `qwen3.5-9b`, `gemma-4-26b-a4b`, and `qwen3.5-35b-a3b` — see [Recommended Models](#recommended-models). Vision models (for image analysis) are configured separately per role.

**Why use NanoTeams instead of a hosted AI assistant?**
Hosted assistants run massive frontier models in the cloud and are excellent at what they do. **NanoTeams** is a different choice for a different need: when your code or data can't leave the machine, when you don't want a subscription or per-token bill, or when you want a multi-agent workflow with specialized roles, artifact pipelines, and on-device embeddings around whichever local model you prefer.

**Can I customize teams and roles?**
Yes. Create your own teams with custom roles, artifacts, prompts, tool access, dependencies, and per-role LLM overrides. Import/export as JSON. Or describe a task in one line and let the LLM design a team for it.

**Can one team hand work to another?**
Yes. A peer-level role can delegate a self-contained sub-task to another team with the `delegate_to_team` tool and get that team's final artifacts back as the result. The built-in **Coding Agent** does this out of the box — editing small changes itself and delegating bigger work to the Engineering Team, Startup, or a freshly generated team. While a delegation runs you can message the delegating role to pause the child team, then cancel, resume, or forward guidance. Enable it per role in the *Delegation* tab of the role editor.

**Can NanoTeams work unattended?**
Yes — enable the **Autovisor** for a work folder. It acts as an automated Supervisor: it watches your tasks, creates and schedules new ones, answers their questions, reviews the results, and closes finished work, guided by a goal and a standing memory you can edit. A built-in sleep timer turns it off automatically after a set time.

**What are the system requirements?**
macOS 15.0 or later. LM Studio 0.4.0 or later. Apple Silicon recommended for best local-LLM performance. Voice dictation requires macOS 26+.

## Support

For questions, issues, or feature requests — [open an issue](https://github.com/jmstajim/NanoTeams/issues) or reach out via [email](mailto:gusachenkoalexius@gmail.com) · [LinkedIn](https://www.linkedin.com/in/jmstajim/).

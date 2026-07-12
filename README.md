<div align="center">

# **NanoTeams**

### A free, open-source coding agent for macOS,<br>and an AI team for everything else

[![Build&Test](https://github.com/jmstajim/NanoTeams/actions/workflows/ios.yml/badge.svg)](https://github.com/jmstajim/NanoTeams/actions/workflows/ios.yml)
[![Version](https://img.shields.io/github/v/release/jmstajim/NanoTeams?label=version&color=5F87D9&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/jmstajim/NanoTeams/total?label=downloads&color=5F87D9&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)
[![macOS](https://img.shields.io/badge/macOS_15.0+-5F87D9?logo=apple&style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)
[![Download](https://img.shields.io/badge/Download-NanoTeams.app.zip-35BE81?style=flat-square)](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)

</div>

**NanoTeams is a coding agent that runs entirely on your Mac, powered by the local models you already run in [LM Studio](https://lmstudio.ai).** Chat with the **Coding Assistant** to read and edit your files, or let the **Coding Agent** make small changes itself and hand the heavy lifting to a full team of AI roles that plan, build, review, and ship. It's universal, too: because a team is just AI roles you configure, the same engine drafts documents, plans projects, or runs research. Flip on the **Autovisor** and it runs the whole folder on its own. No cloud, no API keys, no subscription. Your code and your ideas stay on your machine. NanoTeams is free and open-source, so you can verify that yourself.

**[Download for macOS](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)** · free & open-source · [Get started](#getting-started) · [All releases](https://github.com/jmstajim/NanoTeams/releases)

## Why NanoTeams

The goal is simple: make local LLMs work as fast and efficiently as possible in real tasks — writing code, making decisions, organizing your thinking, drafting documents, and bringing ideas to life.

**NanoTeams** treats smaller models as the design constraint.

Stateful chat keeps responses fast. The architecture forgives mistakes. Every piece of the program compensates for something local models don't do well.

<img width="1280" height="1112" alt="NanoTeams: AI coding assistant and multi-agent AI teams for macOS" src="https://github.com/user-attachments/assets/124d259d-3e5b-4fbd-b4b2-39dd8458a5ba" />

## Getting Started

> Requires **macOS 15.0+** and **[LM Studio 0.4.0+](https://lmstudio.ai)**

1. **[Download NanoTeams.app.zip](https://github.com/jmstajim/NanoTeams/releases/latest/download/NanoTeams.app.zip)** ([all releases](https://github.com/jmstajim/NanoTeams/releases)), extract it, drag `NanoTeams.app` into Applications, and open it. If macOS blocks it: System Settings → Privacy & Security → Open Anyway.
2. Open **LM Studio** and load a model (see [Recommended Models](#recommended-models)).
3. Launch **NanoTeams** and select a work folder (where AI roles read and write files).
4. Pick a team. **Coding Assistant** is the default (chat-mode with files, git, and Xcode tools); the new **Coding Agent** edits small changes itself and delegates bigger work to another team.
5. Create a task, describe what you need, and the team takes it from there.

<img width="1280" height="1143" alt="NanoTeams: create a new task and select a team" src="https://github.com/user-attachments/assets/2ec90b85-d8ce-43f6-bc0f-57635761dd94" />

## How It Works

You are the **Supervisor**. You create a task, and a team of AI roles executes it step by step based on artifact dependencies.

Take the **FAANG Team**: you describe what you want → PM writes requirements → UX researches and designs → Tech Lead plans → Engineer implements → Code Reviewer checks the code → SRE verifies production readiness → TPM writes release notes → you review and accept.

Each role can read/write files, use git, build with Xcode, consult other roles, request team meetings, and delegate a self-contained sub-task to another team, all inside a sandbox limited to your work folder.

<img width="1280" height="1047" alt="NanoTeams: team graph showing roles and artifact dependencies" src="https://github.com/user-attachments/assets/fd0da67e-212b-4713-b408-579916919ca1" />

## How Roles Work

Every role in a team is one of three types. The type sets what the role does and how it finishes.

### Producing Roles
Most roles are producing: they create specific deliverables called artifacts. A PM produces "Product Requirements," an Engineer produces "Engineering Notes," a Code Reviewer produces "Code Review Summary."

You don't need to do anything. The role reads files, uses tools, and consults teammates on its own, then finishes once it has submitted all its artifacts. You watch the activity feed and review the results.

All roles in the FAANG, Engineering, and Startup teams are producing roles.

### Chat Roles
Some roles don't produce artifacts. Instead, they talk to you. After reading upstream artifacts (or only your task description), the role enters an open-ended conversation loop, asking you questions and responding to your answers.

The role never finishes on its own. It keeps the conversation going until you pause or close the task. This is how the Personal Assistant works: pure back-and-forth dialogue. In the Quest Party, the Quest Master reads all the world-building artifacts from other roles, then runs an interactive adventure where you play the hero.

When a team has no required deliverables for the Supervisor, the UI switches to Chat mode, and you'll see a "Chat" label instead of "Working" or "Review."

### Observer Roles
A few roles have no artifacts at all: they don't produce anything and don't depend on anything. They sit in the team graph but don't run on their own. Instead, they come alive when invited to team meetings, contributing their perspective to group discussions.

In the Discussion Club, four personality roles (The Open, The Conscientious, The Extrovert, The Neurotic) are observers; only The Agreeable runs as a producing role, kicking off meetings where all five debate the topic together.

## Features

Everything below runs on your Mac, against your own local model.

### Multi-Agent AI Teams
Turn one task into a coordinated team effort. Each role has its own instructions, tools, and deliverables, and they collaborate through quick consultations, group meetings, and change requests.

### Autovisor: Automated Supervisor
Let an autonomous agent run the folder while you do something else. Give the **Autovisor** a goal and it watches your tasks, creates and schedules new ones, answers the questions roles would normally ask you, reviews finished work, and closes it, remembering what it learned along the way. It wakes when a task needs attention and idles when there's nothing to do. Message it any time to steer it, and a sleep timer stops it after a while so it can't run all night. Set its goal, memory, and schedule in Settings.

### AI Team Generation
No matching team? Describe a task in one line and an LLM designs a custom one for it: the roles, their prompts, and how they hand work to each other. Tweak the defaults in Settings, or just let it run.

### Team Delegation
A role can hand a bigger, self-contained job to another team and get the finished work back. The built-in **Coding Agent** does exactly this: it makes small edits itself and passes larger, multi-file work to the **Engineering Team**, **Startup**, or a team generated on the fly. While the other team works, you can step in through the delegating role to pause it, redirect it, or cancel. Turn it on per role and pick which teams that role may hand work to.

### Shell Commands (Bash)
Code-writing roles can run real terminal commands, including long-running ones you watch as they go. It's **manual by default**: every command waits for your one-tap **Allow** or **Deny**, and an **Ask AI** button explains in plain language what a command does and whether it's safe before you decide. Want less friction? Let trusted commands run on their own, or hand approval to an on-device judge. Either way, every command runs in a macOS sandbox that keeps changes inside your work folder and away from your credentials. On for code-writing roles; read-only roles stay command-free.

### Computer Use (Screen Control)
Some jobs need the screen, not just files. A role can take a screenshot and then click, type, and scroll in other Mac apps to get them done. It's **manual by default**: you approve every action with a preview of exactly what will happen. Prefer hands-off? Hand approval to an on-device judge at the strictness you choose, or turn the feature off entirely. Built-in guardrails keep it from ever touching NanoTeams itself or any app you haven't allowed, and macOS asks for screen and accessibility permission the first time.

### Global Context
One shared instruction box that every role in every team follows. Put your house rules, coding standards, or preferred tone here once, and they apply everywhere.

### Agent Instructions (CLAUDE.md & co.)
Already keep `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.cursorrules`, or Copilot and Windsurf rules in your repo? NanoTeams finds them automatically and gives every role the same house rules you already wrote.

### Agent Skills ("/" Picker)
Type "/" in any message box to pull in the skills and slash-commands you already have from Claude Code, Codex, Cursor, Gemini CLI, GitHub Copilot, Windsurf, and OpenCode. Pick one and it rides along with your message.

### ✦ Improve Prompt
Rough draft? Tap the sparkles button and your local model rewrites it into a cleaner prompt, right in the box, Apple Writing Tools style. Don't like the result? One tap brings your original back.

### 50 Built-in Tools
Fifty built-in tools cover the whole job: reading and writing files, running the terminal, git, building and testing with Xcode, team collaboration and delegation, generating teams, creating artifacts, analyzing images, and controlling the screen.

### Documents In & Out
Roles read PDF, DOCX, RTF, XLSX, PPTX, and ODT files directly, with no manual conversion to plain text, and open HTML and source files as raw text. Export generated artifacts to PDF, Word, or RTF.

### Universal Search
Keyword search across PDFs, Word documents, spreadsheets, slides, OpenDocument files, HTML, source code, and plain text, all from a single tool call.

### Exploratory Search (Semantic)
Search your project by meaning, not just keywords, which helps in big codebases. It runs entirely on your machine; switch it on in Settings.

### Per-Role LLM Configuration
Match each role to the right model: a fast, small one for planning, a heavyweight coder for the hard parts. Every role can run on its own local model.

### Vision (Image Analysis)
Roles can look at screenshots, diagrams, and photos, not just text. Point vision at a separate image-savvy model and keep your main model focused on writing.

### Quick Capture
Two global hotkeys work from any app:
- **Ctrl+Opt+Cmd+0**: Floating overlay to create chat/task, answer AI questions, or view status
- **Ctrl+Opt+Cmd+K**: Capture the current selection (text or files) and attach it to your chat/task

Paste anything into the message box with Cmd+V: files (including PDFs and docs), screenshots, or plain text.

### Private Voice Dictation
Talk instead of type. On-device, multilingual, offline dictation, available wherever you write. Requires macOS 26+.

### Team Meetings & Change Requests
Roles talk to each other: quick questions, group meetings with voting, and requests for changes. When a reviewer wants a fix, the team votes and the work is redone with full context.

### Supervisor Message Queue
Nudge a working role without stopping it: pick a role or the whole team and send a note it picks up on its next step. Paused or failed? A message resumes it, right where it left off.

### Scheduled & Recurring Tasks
Put any task on a schedule: every interval, daily at a set time (on the days you choose), monthly, or just once. A timeout auto-pauses a run that overruns, so a stuck model never blocks the queue.

### Artifact Dependency Pipeline
Roles pass named deliverables to each other, and NanoTeams works out the running order automatically. A live team graph shows the flow.

### Custom Teams
Build your own teams: roles, deliverables, prompts, and how they connect. Import and export as JSON, and edit every prompt template to taste.

### Themes

<img width="1280" height="1068" alt="NanoTeams: Themes" src="https://github.com/user-attachments/assets/7391d0d4-f482-4ae2-ac42-5952cda4010a" />

### Privacy & Security
**NanoTeams** never sends your code, files, or prompts off your Mac. Its only outbound call is a once-a-day check for a new version. Everything else runs on-device through LM Studio, with no telemetry and no account. File access is sandboxed to your work folder, the terminal and screen-control tools ask before they act, and a macOS sandbox keeps changes inside your folder and away from your credentials.

## Built-in Teams

Start with a ready-made team, then customize it or generate your own.

| Team | Description |
|------|-------------|
| **Coding Assistant** *(default)* | Dialog-first coding companion with files, git, and Xcode tools |
| **Coding Agent** | Hybrid coding agent: edits files itself for small changes, delegates complex implementation to a chosen team |
| **Personal Assistant** | Conversational AI helper for any task |
| **FAANG Team** | Full product pipeline: PM → UX → Engineering → Code Review → SRE → Release |
| **Engineering Team** | Lean pipeline: Tech Lead → Engineer → Code Review → Release |
| **Startup** | One engineer, full autonomy, fast iteration |
| **Quest Party** | Five specialists build a fantasy world, then the Quest Master runs an interactive adventure where you are the hero |
| **Discussion Club** | Five distinct personalities debate any topic in a lively multi-agent discussion |

## Recommended Models

I train **NanoTeams** on:
- **[gpt-oss-20b](https://lmstudio.ai/models/openai/gpt-oss-20b)**
- **[qwen3.5-9b](https://lmstudio.ai/models/qwen/qwen3.5-9b)**
- **[gemma-4-26b-a4b](https://lmstudio.ai/models/google/gemma-4-26b-a4b)**
- **[qwen3.5-35b-a3b](https://lmstudio.ai/models/qwen/qwen3.5-35b-a3b)**

Have a favorite local LLM? [Open an issue](https://github.com/jmstajim/NanoTeams/issues) and I'd love to make **NanoTeams** work better with it.

## Build from Source

```bash
git clone https://github.com/jmstajim/NanoTeams.git
cd NanoTeams
xcodebuild -project NanoTeams.xcodeproj -scheme NanoTeams -configuration Release build
```

No external dependencies required. Pure Swift/SwiftUI.

## FAQ

**Is NanoTeams free?**
Yes. **NanoTeams** is open-source and free. There are no subscriptions, no API keys, and no usage limits. You only pay for the hardware your local LLM runs on.

**Does NanoTeams send my data anywhere?**
No. All inference runs through LM Studio on your Mac; your files, prompts, and tool calls never leave your machine. The app's only outbound call of its own is a once-a-day version check. No telemetry, no account.

**Do I need an internet connection?**
No, after the initial download of LM Studio and a model. **NanoTeams** works offline, which helps for travel, secure environments, or air-gapped machines.

**What models does NanoTeams support?**
Any model you can run in LM Studio. I train **NanoTeams** on `gpt-oss-20b`, `qwen3.5-9b`, `gemma-4-26b-a4b`, and `qwen3.5-35b-a3b`; see [Recommended Models](#recommended-models). You configure vision models (for image analysis) per role.

**Why use NanoTeams instead of a hosted AI assistant?**
Hosted assistants run massive frontier models in the cloud and are excellent at what they do. **NanoTeams** is a different choice for a different need: when your code or data can't leave the machine, when you don't want a subscription or per-token bill, or when you want a multi-agent workflow with specialized roles, artifact pipelines, and on-device embeddings around whichever local model you prefer.

**What are the system requirements?**
macOS 15.0 or later. LM Studio 0.4.0 or later. Apple Silicon recommended for best local-LLM performance. Voice dictation requires macOS 26+.

## Support

For questions, issues, or feature requests, [open an issue](https://github.com/jmstajim/NanoTeams/issues) or reach out via [email](mailto:gusachenkoalexius@gmail.com) · [LinkedIn](https://www.linkedin.com/in/jmstajim/).

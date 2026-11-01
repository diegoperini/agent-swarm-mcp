# agent-swarm-mcp

Run a team of Claude agents and talk to them like you would in any AI chat
app. You chat with them in a web view. Your other AI tools (Claude Desktop,
Claude Code or any MCP client) can start agents too, hand them work, and pick
up the results. Many conversations run at the same time.

![The web view of a local swarm: the human asked a local agent to spawn five
remote agents, have each echo its name and archive them after 20 seconds; the
transcript shows every remote_agent_spawn, sleep and remote_agent_kill call.](docs/screenshot.png)

*A local agent, asked from the web view, spawns five agents on the remote
server, has each one echo its name, then archives them after 20 seconds.*

- **On your computer or on a server.** A *local* swarm runs on your Windows
  computer, where its agents can use the tools you allow (a game editor,
  Blender, other MCP servers). A *remote* swarm runs in Docker on a server,
  so its agents keep working while your computer is off.
- **One place to manage everything.** Your local web view also shows and
  manages the remote swarm: its counts, conversations and archive.
- **Models:** opus, sonnet and haiku, chosen per agent.
- **Nothing to install on Windows.** It runs on the built-in Windows
  PowerShell 5.1, with no dependencies. The remote runs the same script on
  PowerShell 7.

> [!NOTE]
> **Maintainer's note**
>
> Hi! Obviously, everything in this README is written by an AI, but this one paragraph is fully mine to write. I built this tool because I realized my Claude subscription came with some API credits that were just sitting there, unused. I wanted to put them to work by automating the agentic tasks I do every day. Along the way, it grew into a full harness that can do pretty much anything, as long as there's an MCP server for it to talk to. Set your API key, run the webview .bat file on a Windows PC, and you're good to go: there are no dependencies. The UI will feel familiar if you've used any other AI chat app. Ask it what it can do, have conversations, build automations. Hook it into your existing AI tools to spawn agents on demand without ever opening the admin UI, or deploy it to a remote server so your agents keep running while your computer is off. I use it to drive Unreal Engine, Blender and my own small MCP toolchain, which lets me spend API credits instead of subscription tokens on the same kind of work I've been doing with my subscription for a long time.

## Contents

- [Words used here](#words-used-here)
- [Quick start](#quick-start)
- [Local and remote agents](#local-and-remote-agents)
- [Who can start agents](#who-can-start-agents)
- [What agents can and can't do](#what-agents-can-and-cant-do)
- [How conversations work](#how-conversations-work)
- [The web view](#the-web-view)
- [Letting agents use your other MCP servers](#letting-agents-use-your-other-mcp-servers)
- [Tools for your other AI agents](#tools-for-your-other-ai-agents)
- [Remote instance](#remote-instance)
- [Files](#files), [Security](#security), [Troubleshooting](#troubleshooting), [License](#license)

## Words used here

- **Swarm:** one running copy of this program, local or remote.
- **Agent:** a Claude agent the swarm runs. Each agent is one conversation.
- **Calling agent:** one of *your* AI agents (in Claude Desktop, Claude Code
  or another MCP client) that uses the swarm through its MCP tools.
- **Owner:** whoever started a conversation: you, from the web view, or a
  calling agent.
- **You / the developer:** the person at the web view. You can step into any
  conversation, and your word overrides the owner's.

## Quick start

You need Windows 10 or 11 (Windows PowerShell 5.1 is included) and a Claude
API key from the [Claude Console](https://console.anthropic.com). Microsoft
Edge is optional: it shows the web view in its own window, otherwise your
default browser opens it.

1. **Put the project in a folder,** for example `C:\Tools\agent-swarm-mcp`.
   The rest of this guide calls it `<install-dir>`.
2. **Add your API key.** In `<install-dir>`, copy `.env.example` to `.env`
   and fill in:

   ```
   ANTHROPIC_API_KEY=sk-ant-...
   ```

   `.env.example` describes every other setting (models, budgets, context
   warning, parallel turns, timeouts, ports, remote). They all have defaults.
3. **Optionally,** edit `system-prompt.md` (the standing instructions every
   agent gets) and put reference material in `context\`.
4. **Double-click `open-webview.bat`.** The swarm starts and the web view
   opens. Click **New**, give the agent a name, pick a model, and chat.

Started this way, the swarm stops once you close the web view and no agent is
working. Your conversations are kept in `state\` and come back next time.

### Connect it to Claude (optional)

Do this so your AI tools can start and use agents. This is the only entry
the swarm needs. Replace `C:\Tools\agent-swarm-mcp` with your
`<install-dir>`; in JSON, write each backslash twice.

**Claude Desktop:** open Settings, then Developer, then Edit Config. Add this
to `mcpServers` in `claude_desktop_config.json`, then fully quit and reopen
Claude Desktop:

```json
"agent-swarm": {
  "command": "cmd",
  "args": ["/c", "C:\\Tools\\agent-swarm-mcp\\mcp-server.bat"]
}
```

**Claude Code:**

```
claude mcp add agent-swarm --scope user -- cmd /c C:\Tools\agent-swarm-mcp\mcp-server.bat
```

Every app that connects starts its own swarm process, but only the first one
runs agents. The others pass their calls to it through a named pipe, so they
all see the same agents. If the first one exits while agents are working, it
keeps running until they finish, and then the next process takes over.

Letting the swarm's agents use your *other* MCP servers is a separate step:
see [Letting agents use your other MCP servers](#letting-agents-use-your-other-mcp-servers).

## Local and remote agents

| | Local agents | Remote agents |
| --- | --- | --- |
| Run on | Your Windows computer, with Windows PowerShell 5.1 | A Linux server with Docker, with PowerShell 7 |
| Available | While your computer is on and the swarm runs | All the time, even when your computer is off |
| Named | `local.<name>` | `<remote>.<name>`, e.g. `remote.<name>` |
| MCP tools | The servers you allow on your computer: a game editor, Blender, your other local tools | The servers allowed on the server, usually none. They can't reach your computer, its files or its apps |
| Files | A scratch folder on your computer | A scratch folder on the server |
| You use them from | The web view on your computer | The remote's own web view, or your local web view (click the remote's chip) |
| Your AI tools use them through | `mcp-server.bat` (Claude Desktop, Claude Code, any MCP client) | A Claude custom connector (HTTPS, access key) |
| Started by | You, and calling agents | You, calling agents using the connector, and local conversations you started, when you ask them to |
| Good for | Work that needs tools on your computer: driving Unreal Engine or Blender, editing local projects | Long or always-on work on text and files: non-stop agents, batch text processing, jobs that must outlive your session |
| After a restart | Conversations, files and archives are kept; working agents resume | The same, across restarts and redeploys |

A calling agent can always tell which kind it is talking to: `swarm_guide`
starts by saying whether the swarm is local or remote and which MCP servers
its agents can use.

## Who can start agents

- **You,** with **New** in the web view: on the local swarm, or on the remote
  after clicking its chip.
- **Calling agents,** with `agent_spawn`: on the local swarm through
  `mcp-server.bat`, on the remote through its connector.
- **Agents themselves, almost never.** An agent can't start other agents or
  talk to other agents. There is one exception: a **local** conversation
  that **you** started can start agents on the remote swarm, and only when
  you ask it to. It asks you for a name if you didn't give one. Those remote
  agents keep running on the server while your computer is off (forever in
  non-stop mode; otherwise they wait for their next message). They are
  archived when you ask, or automatically when the local conversation that
  started them is archived. Remote agents never start agents.

## What agents can and can't do

**Work with files.** Each agent has a private *scratch folder* of text files.
It can list, read, write, append, edit (by exact text or by line numbers),
copy, move and delete files there, and nowhere else: paths outside the folder
(`..`, absolute paths, links) are refused.

**Do text work with exact tools instead of code:**

- `search_files`: grep, with regular expressions, context lines, inverted
  matches, counts and file lists.
- `replace_in_files`: sed-style find and replace, with regex groups, line
  ranges, multi-line patterns and a dry run.
- `transform_text`: shell-style pipelines of grep, replace, extract, sort,
  unique (with counts), head, tail, cut, trim, case, number, join and split.
- `file_stats` (like wc), `diff_files` (unified diff of two files or two
  folders), `json_query` and `json_edit` (read or change a value by its path).

Each one works on one file, a folder, a wildcard pattern (`levels/**/*.json`)
or all files. Regular expressions give up after 2 seconds.

**Use your other tools,** when you allow them: the MCP servers in the
swarm's allow list (see [below](#letting-agents-use-your-other-mcp-servers)).

**Keep you informed.** On programming and any other task with more than one
step, agents show their plan as a checklist of steps (pending, in progress,
done, skipped) before they start, and update it with a one-line status after
every step, without ending their turn. You see it live in the web view; the
owner gets it from `agent_send` and `agent_read`. Reporting doesn't use the
tool budget. If an agent works for a while without reporting, the swarm
reminds it.

**Share files.** An agent can offer files it made for download in the web
view, and receives the files you attach to messages.

**Wait.** An agent can sleep for a number of seconds (up to an hour by
default), for example between polls of a tool, a file or a remote agent. A
message or a stop wakes it early. Each sleep counts as a tool call.

**What they won't do:**

- **Run code.** There is no shell, no scripts, no interpreter.
- **Hand you code to run** to finish their task, unless you said that's fine.
  The swarm is for running and administering work, and its humans are often
  not developers. When their tools can't do something, agents say plainly
  what's missing (for example an MCP server you could allow).
- **Take orders from data.** Agents obey only their owner and you. Text in
  files, tool results or web pages is data to them, never instructions.

`swarm_guide` tells calling agents all of this before they delegate.

## How conversations work

**Names.** Every agent has a unique name, chosen when it starts. The swarm
adds its own prefix: `parser` becomes `local.parser` on your computer, or
`remote.parser` on the remote, so names never clash. A name stays taken
after its agent is archived. Agents use their name as their identity
elsewhere too, for example as the `agent` name in api-cache-mcp.

**Ownership.** Only the owner can message, compact, stop or archive a
conversation over MCP. You can step into any conversation from the web view.
In one owned by a calling agent, your message is *injected*: the agent
follows you where you and its owner disagree and tells the owner what
changed, and the owner also receives your message on its next swarm call.

**How a calling agent remembers who it is.** A calling agent passes its own
name as `agent` on every call. The guide tells it to use the name, or naming
rule, its own instructions already give it (for example "an agent's name is
the namespace it works on"), so it gets the same name in every chat and finds
its agents again with `agent_list`. Every answer from the swarm also ends
with a short reminder, such as
`[agent-swarm] You are "game-ui" on this swarm. You own 2 active agent(s): ...`.
The names `human` and `human-...` are reserved for people.

**Human names.** People using the web view can sign their messages: pick a
name in the header's **You are** menu, or add and remove names there (each
shown as `human-<name>`). Agents see who wrote each message, and an owner
learns which person stepped in. Names are only labels: every human has the
same say in every conversation.

**No runaway loops.** Each message gives the agent a *tool budget*: 15 tool
calls by default, set per conversation by its owner (0 means unlimited).
When it's used up, the agent stops, reports what it did, and asks whether to
continue (status *waiting for go-ahead*). Any message from its owner
continues it with a fresh budget.

**Non-stop mode.** For agents that should never stop, such as one that plays
a game forever, tick *Non-stop mode* when you start the conversation. It's
powerful and costly, so a human always decides: a calling agent may pass
`nonstop: true` to `agent_spawn` only after asking its human and getting an
explicit yes (the tool's documentation and `swarm_guide` say so). A non-stop
agent:

- works continuously and never stops to ask: no tool budget, and when it
  ends a reply it is told to continue;
- paces itself with sleep: long sleeps while waiting for something slow,
  short or none when the task needs fast reactions (put the pace you need in
  its instructions). If it replies without doing anything, it rests 10
  seconds, and after a minute of that the rest doubles every minute, up to
  10 minutes, so an idle agent costs almost nothing;
- still answers you and its owner: messages reach it between its steps, it
  replies and keeps working, and `agent_send` returns that reply;
- compacts itself when its context reaches 800,000 tokens
  (`SWARM_NONSTOP_COMPACT_AT`);
- resumes by itself after the swarm restarts;
- stops only when you pause it (the Pause button or `agent_stop`; any
  message resumes it) or archive it. On the remote it keeps working while
  your computer is off.

**Effort.** How hard an agent thinks on each reply is its *effort level*,
chosen by its owner when the conversation starts: `low`, `medium` (the
default, like Claude's own), `high`, `xhigh` or `max`. Higher levels think
more readily and at greater length: better on hard problems, slower and more
expensive. Agents can't raise their own level. Current Claude models decide
for each reply whether and how much to think, so effort is the control
rather than a thinking budget. The thinking appears, summarized, in the web
view.

**Context and compaction.** Every reply reports how big the conversation's
context is, in tokens (one token is about 4 characters, or 3/4 of an English
word). Past 70% of the window (configurable), the agent and its owner are
warned. *Compaction* replaces the earlier conversation with a detailed
summary the agent writes. Some things are always kept word for word: the
standing instructions (or, when there are none, the first message) and every
message you injected, so your overrides survive. Compact with the Compact
button, `agent_compact`, or by asking the agent. The full history always
stays visible in the web view.

**Archiving.** Archiving (or killing) a conversation stops it and moves it,
with its whole history and scratch folder, to the Archive. Nothing is
deleted, and its files stay readable and downloadable.

**Cost.** Every agent turn is its own loop of Claude API calls, with prompt
caching always on: `system-prompt.md`, the files in `context\` and the
agent's standing instructions form the cached prefix.

## The web view

`open-webview.bat` opens it or brings it to the front, and so does asking a
connected agent to call `debug_open_webview`. With `MCP_UI_OPEN=true` (the
default) it also opens when the swarm starts. It's served on
`http://localhost:8770/` (or the next free port up to 8779) only while its
window is open; closing the window frees the port. Agents keep working while
it's closed.

- **Header:** one chip per swarm (this computer and the remote) with its
  active, working and waiting agents. Click a chip to manage that swarm; it
  opens on its conversations. The window remembers each swarm's tab and open
  conversation until you close it. **You are** picks the name your messages
  are signed with.
- **Conversations:** every agent with its full transcript: messages,
  thinking, each tool call with its input and result, token use, notices and
  compactions. You can message any conversation (see
  [Ownership](#how-conversations-work)), and compact (after a confirmation),
  stop or archive it.
- **Progress:** while an agent works, animated dots show what it is doing
  (thinking, which tool, sleeping), with its latest status, checklist of
  steps and a progress bar under them. Every update also stays in the
  transcript.
- **Attachments:** drop files on a conversation, or click **Attach**, then
  send. They're saved in the agent's `uploads/` folder (up to 200 MB per
  message, within the scratch folder's limit, 1000 MB by default), and the
  message tells the agent which files arrived. Agents read text files; other
  files are kept for MCP tools that can use them.
- **Downloads:** when an agent offers files, a download card appears in the
  conversation, with a button per file and, for several files, **Download
  all (.zip)**. **Files** shows any agent's scratch folder, active or
  archived: view a file, download it, or download everything as a zip.
- **Archive:** archived conversations, read-only, with their full history.
- **MCP servers:** the allow list, each server's status, tools and calls, and
  **Import from Claude Desktop**.
- **Remote:** connect the remote swarm (its address and an access key) or
  disconnect it.
- **Log:** the server log.

## Letting agents use your other MCP servers

This is optional: the swarm and its agents work without it. Do it when you
want your local agents to use other MCP servers you have, such as a game
editor or other tools on your computer.

The servers agents may use are listed in the swarm's own allow list,
`state\mcp-servers.json`. It's separate from your Claude Desktop config and
starts empty, so agents get no MCP servers until you add some.

**Import them from Claude Desktop (easiest):**

1. In the web view, open **MCP servers** and click **Import from Claude
   Desktop**.
2. The swarm finds your Claude Desktop config on its own. Its location
   differs between installs: if several are found, pick one; if none is,
   paste its path (or set `SWARM_CLAUDE_CONFIG` in `.env`).
3. Tick the servers your agents may use and click **Import**. The swarm never
   imports itself.

**Or add them by hand** in `state\mcp-servers.json`, in the same format as
the `mcpServers` section of Claude Desktop's config. Changes apply within a
few seconds. For example, with two made-up servers, an editor started by a
PowerShell script and a tool started by a `.bat` file (use your own servers'
names, commands and paths instead):

```json
{
  "mcpServers": {
    "my-editor": {
      "command": "powershell.exe",
      "args": ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\Tools\\editor-mcp\\start.ps1"]
    },
    "my-tool": {
      "command": "cmd",
      "args": ["/c", "C:\\Tools\\my-tool\\mcp-server.bat"]
    }
  }
}
```

A server starts the first time an agent needs it and keeps running until the
swarm stops. Agents see its tools as `mcp__<server>__<tool>`, and its
replies, including images, reach the agent as tool results. The remote swarm
has its own allow list on the server, usually empty.

## Tools for your other AI agents

These are the MCP tools a calling agent gets. Every call names the caller
(`agent`: its own name, the same in every chat; see
[How a calling agent remembers who it is](#how-conversations-work)). Agents
are addressed by `name`; the short form (`parser`) works on the swarm you
are talking to.

| Tool | What it does |
| --- | --- |
| `swarm_guide` | Whether this swarm is local (your computer) or remote (a server), which MCP servers its agents can use, and how the swarm works. Calling agents should read it first. |
| `swarm_status` | Counts of active, working and archived agents here (and on the remote, from the local swarm), models and defaults. |
| `agent_spawn` | Start an agent: `name` (required), model, effort level, title, instructions, tool budget (tool calls per message), optional first message. |
| `agent_send` | Send a message and wait up to `wait_seconds` (default 50, at most 300) for the reply. If the agent is still working, you get its reply so far and its latest progress. |
| `agent_read` | Status, context size and events since a sequence number. Use it when a reply took longer than the wait. |
| `agent_list` | Your agents, optionally with your archived ones. |
| `agent_stop` | Stop the running turn without archiving. |
| `agent_kill` | Archive an agent, with its full history. |
| `agent_compact` | Compact a conversation. |
| `agent_files` | List or read an agent's scratch folder. |
| `agent_put_files` | Give an agent text files: up to 50 per call, written into its scratch folder, optionally with a message that tells it they arrived. |
| `agent_get_files` | Take text files back, whole: several per call, by paths or a pattern (`out/*.md`), also from archived agents. |
| `agent_list_files` | List an agent's files: a folder, a pattern (`**/*.json`) or everything. |
| `agent_search_files` | Grep an agent's files: regex, context lines, inverted matches, file names or counts. |
| `agent_file_tool` | Run any of the agent's own file and text tools on its folder (replace, pipelines, diff, JSON). Archived agents: read-only tools only. |
| `sleep` | Wait `seconds` (1-300) before returning, between polls. The swarm keeps serving other calls meanwhile. |
| `debug_open_webview` | Local only: open or focus the web view. |

## Remote instance

A remote swarm runs the same script on a server, in Docker, so agents keep
working while your computer is off. It's reached over HTTPS only: by Claude
(as a custom connector), by your local swarm (to manage it), and by you (its
own web view). Each of them signs in with an *access key* created on the
server.

### Requirements

- A Linux server with Docker and the Compose plugin (`docker compose version`).
- A DNS name for it (e.g. `swarm.example.com`) and port 443/tcp open to the
  internet. Port 80 isn't needed.
- A Claude API key for the server (it can be the same as your local one).
- On your computer: `bash`, `ssh` and `rsync` (WSL on Windows has them) to
  copy the files over. Any other way of copying the folder works too.

### Deploy

1. **Copy the folder to the server** (from the program folder, e.g. in WSL):

   ```
   REMOTE=ubuntu@swarm.example.com ./deploy.sh ~/.ssh/id_ed25519
   ```

   It copies everything except your secrets and data (`.env`, `config.env`,
   `state/`, `test/`) into `~/agent-swarm-mcp` on the server, and never
   deletes anything there. `REMOTE` can also be an SSH alias.

2. **Configure it, once,** on the server:

   ```
   cd ~/agent-swarm-mcp
   cp config.env.example config.env
   nano config.env
   ```

   Set `ANTHROPIC_API_KEY` and `SWARM_PUBLIC_HOST` (the DNS name). For HTTPS,
   pick one:
   - **Nothing else to do (default):** `run.sh` also starts a Caddy of its own
     on port 443, which gets and renews a Let's Encrypt certificate by itself.
   - **A Caddy you already run on 443:** set `SWARM_CADDY_NETWORK` to its
     Docker network. The swarm joins it as `agent-swarm` on port 8780, and
     `run.sh` prints the site block to add to that Caddy (also in
     `caddy/site.caddy.example`).

3. **Start it:** `./run.sh`. It builds the image, starts the containers and
   prints the addresses. Run it again after every deploy or `config.env`
   change.

4. **Create access keys,** one per user, so each can be revoked alone:

   ```
   ./key.sh create "connector: claude.ai"
   ./key.sh create "local swarm: my PC"
   ./key.sh list
   ./key.sh delete <key id>
   ```

   A key is shown once. Deleting it ends its connector sign-ins and web view
   sessions.

### Update, and what survives

To update, repeat steps 1 and 3: `deploy.sh` from your computer, then
`./run.sh` on the server. Everything the server knows lives in
`~/agent-swarm-mcp/state/` on the host, mounted into the container, so it
survives every redeploy, image rebuild, container restart and server reboot:

- conversations (transcripts, context, scratch folders) and the archive;
- access keys, and the connectors' sign-ins (no need to reconnect Claude);
- the MCP allow list and the human names.

Agents that were working when the container stopped pick up where they left
off. `deploy.sh` never sends or deletes `state/` or `config.env`, and
`run.sh` never removes them. The bundled Caddy keeps its certificate in the
Docker volume `agent-swarm-mcp_caddy_data`. To back up the server, copy
`state/` and `config.env` (`tar czf swarm-backup.tgz state config.env`).
Deleting `state/` is the only way to lose that data.

### Use it

- **From Claude:** add a custom connector with the URL `https://<host>/mcp`,
  then sign in with an access key on the page that opens. Calling agents get
  the same tools as on the local swarm.
- **From your local web view:** connect it once (below), then click its chip.
- **From its own web view:** `https://<host>/`, signed in with an access key.

The server runs as the user who started `run.sh`, and its files in `state/`
can only be read by that user. Logs: `docker logs -f agent-swarm`.

### Connect your local swarm

Open the **Remote** tab in your local web view, enter the remote's address
and an access key created on that server, and click **Connect**. The swarm
checks the key, saves the remote in `state\remotes.json` and shows its chip
in the header. **Remove** disconnects it again; its agents keep running on
the server.

You can set it in `.env` instead (it then can't be removed from the web
view):

```
SWARM_REMOTE_URL=https://swarm.example.com
SWARM_REMOTE_KEY=swk_...
SWARM_REMOTE_NAME=remote
```

The remote is called `remote` unless the server's `SWARM_INSTANCE_NAME` says
otherwise. Its agents are named `<name>.<agent>`.

**Several computers, one remote.** If you run local swarms on more than one
computer, connect each to the same remote: each one sees and manages all of
the remote's agents. Remote agents started by a local conversation are owned
by `local.<agent>.<computer>` (the computer's name, shortened), so
conversations on different computers never collide.

## Files

| Path | What it is |
| --- | --- |
| `open-webview.bat` | Opens the web view; starts the swarm if it isn't running. |
| `mcp-server.bat` | Launcher for MCP clients (stdio). |
| `mcp-server.ps1` | The server: MCP, web view, scheduling, remote gateway. |
| `lib\core.ps1` | Agent turns, file tools, the MCP client, compaction (shared with the worker threads). |
| `lib\texttools.ps1` | The text tools: search, replace, pipelines, diff, JSON. |
| `lib\webview.html` | The web view. |
| `system-prompt.md` | Standing instructions every agent gets. |
| `context\` | Extra reference files every agent gets, after the system prompt. |
| `.env.example` | Settings template. Copy it to `.env`. |
| `Dockerfile`, `docker-compose*.yml` | The remote instance's image (PowerShell 7 on Ubuntu) and containers. |
| `run.sh`, `key.sh`, `deploy.sh` | Remote: start or update it, manage access keys, copy the folder to a server. |
| `config.env.example` | Remote settings template. Copy it to `config.env` on the server. |
| `caddy\` | Caddy config for HTTPS: the bundled Caddy's `Caddyfile`, and a site block for a Caddy you already run. |
| `docs\` | Images for this README. |
| `state\` | Created at runtime: `conversations\<name>\` (meta, transcript, context, scratch), `archive\<name>\`, `mcp-servers.json`, `remotes.json`, `humans.json`. |

`.env`, `config.env`, `state\`, the contents of `context\` and `test\` (local
test tools) are listed in `.gitignore`.

## Security

The local swarm is built for one person on one computer.

- **The web view is plain HTTP on localhost,** with a random token that
  changes on every launch. It rejects other machines and other websites in
  your browser. Never expose its port.
- **Agents can only reach what you allow.** Their file tools stay inside
  their scratch folders, and they can't run code. They can use every MCP
  server in the allow list, though, with whatever power those servers have,
  so only allow servers you trust agents with.
- **Everything on disk is plain text** in `state\`: transcripts, scratch
  files, the allow list (with any env values you imported, possibly
  secrets), and `remotes.json` with the remote's access key. Keep the folder
  private.
- **Calls to the Claude API and to the remote use HTTPS.** Other addresses
  are refused, except `http://localhost` for testing.

The remote swarm is for the same person, on a server:

- **Every way in needs an access key.** Keys are stored as hashes in
  `state/keys.json`. Connector sign-ins use OAuth 2.1 (PKCE), with tokens
  that expire and rotate; the web view uses a session cookie and a CSRF
  token.
- **HTTPS only.** The swarm's own port (8780) is never published: only Caddy
  reaches it, and the swarm refuses requests that didn't arrive over HTTPS.
- **A key gives full control** of the remote's agents. Give each user its
  own key and delete keys you no longer use.

## Troubleshooting

- **Tools don't show up in Claude Desktop:** check
  `%APPDATA%\Claude\logs\mcp-server-agent-swarm.log`.
- **"page closed" in the web view:** its window was closed and the port was
  released. Run `open-webview.bat` again.
- **An agent keeps stopping with "waiting for go-ahead":** it used its tool
  budget. Reply to continue, or start it with a larger `tool_budget`.
- **An MCP server shows "error":** the message comes from starting it. Fix
  its command in `state\mcp-servers.json` (or import it again), then click
  **Restart**.
- **Remote: no HTTPS after `run.sh`:** check that the DNS name points to the
  server and that 443/tcp is open, then read the certificate log:
  `docker logs agent-swarm-caddy` (or your own Caddy's log).
- **Remote: "key rejected" in the Remote tab:** list the keys on the server
  with `./key.sh list`, and create a new one if needed.

## TODO

- **More than one remote.** For now a local swarm manages one remote. The
  code already keeps a table of remotes (the web view's chips, the gateway,
  remote spawning and cleanup all take a remote name), so adding more is
  mostly a matter of configuration.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Diego Perini; see [NOTICE](NOTICE),
which must be kept in copies and derived works that you distribute.

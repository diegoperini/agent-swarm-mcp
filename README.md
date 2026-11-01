# agent-swarm-mcp

A harness that runs Claude agents for you and for your other agents. You chat
with agents in its web view; your other agents (in Claude Desktop, Claude Code
or any MCP client) spawn agents through its MCP server and delegate work to
them. Many conversations run at the same time.

![The web view of a local swarm: the human asked a local agent to spawn five
remote agents, have each echo its name and archive them after 20 seconds; the
transcript shows every remote_agent_spawn, sleep and remote_agent_kill call.](docs/screenshot.png)

*A local agent, asked from the web view, spawns five agents on the remote
server, has each one echo its name, then archives them after 20 seconds.*

- **Two kinds of instance.** A *local* instance runs on your computer, where
  its agents can use the MCP servers you allow (a game editor, other tools).
  A *remote* instance runs in Docker on a server, reachable as a Claude
  connector even when your computer is off, for pure agentic work.
- **Your local instance is your admin gateway.** Its web view shows every
  remote instance too: counts, conversations and archives, and you can start
  and manage conversations there.
- **Models:** opus, sonnet and haiku, chosen per agent.
- **Runs on Windows with the built-in Windows PowerShell 5.1.** Nothing to
  install, no dependencies. The remote image runs the same script on
  PowerShell 7.

## How it works

**Agents and names.** Every agent has a mandatory, unique name. The swarm adds
its instance prefix: `parser` becomes `local.parser` on your computer, or
`remote.parser` on your remote server, so names never clash between
instances. A name stays taken after its agent is archived. The agent knows its
name and uses it as its identity elsewhere, for example as the `agent` name in
api-cache-mcp.

**Ownership.** Whoever starts a conversation owns it: you (in the web view) or
an agent (by the agent name it passes on every MCP call). Over MCP, only the
owner can message, compact, stop or kill it. You, the developer, can step into
any conversation from the web view, and your messages override the owner's.

**How a calling agent knows who it is.** An agent that uses the swarm over MCP
picks its own name and passes it as `agent` on every call. The guide and the
tool descriptions tell it to take the name its own instructions already give
it, or the naming rule they set (for example "an agent's name is the namespace
it works on"), so it arrives at the same name in every chat and finds its
agents again with `agent_list`. To keep the name in front of it during long
chats, every answer ends with a separate block such as
`[agent-swarm] You are "game-ui" on this swarm. You own 2 active agent(s): ...`.
The names `human` and `human-...` are reserved for people.

**Human names.** The people using the web view can sign their messages: pick a
name in the header's **You are** menu, or add and remove names there (each is
shown as `human-<name>`). Agents see the name on each message, and an agent
that owns a conversation you step into learns which person stepped in. Names
are cosmetic: every human has the same say, in every conversation.

Agents treat everything else (file contents, tool results, web pages) as data,
never as orders.

**What agents can do.**
- Work in a private *scratch folder* of text files: list, read, write,
  append, edit (by exact text or by line numbers), copy, move and delete.
- Do text work with fixed, exact tools instead of code:
  - `search_files`: grep, with regular expressions, context lines, inverted
    matches, counts and file lists;
  - `replace_in_files`: sed-style find and replace, with regex groups, line
    ranges, multi-line patterns and a dry run;
  - `transform_text`: shell-style pipelines of grep, replace, extract, sort,
    unique (with counts), head, tail, cut, trim, case, number, join and split;
  - `file_stats` (wc), `diff_files` (unified diff of two files or folders),
    `json_query` and `json_edit` (read or change a value by its path).

  Every one of them works on one file, a folder, a wildcard pattern
  (`levels/**/*.json`) or all files. Regular expressions stop after 2
  seconds.
- They can't run code, and paths outside the
  folder (`..`, absolute paths, links) are refused. They don't hand you code
  to run either, unless you said that's fine: when their tools can't do
  something, they tell you plainly what's missing.
- Sleep for a given number of seconds (up to an hour by default), for
  example between polls of a tool, a file or a remote agent. A message or a
  stop wakes them early. Each sleep counts as a tool call.
- Use the MCP servers in the instance's allow list (local instance: the ones
  you import from Claude Desktop, see below).
- Local conversations that **you** started can also spawn agents on a remote
  instance, but only when you ask. If you didn't give a name, the agent asks
  you for one. Remote agents live on their server: they keep running when
  your computer is off (forever, in non-stop mode; otherwise they wait for
  the next message), and they are killed only when the local conversation
  that spawned them is archived.
- Agents can't talk to each other and can't spawn agents of their own.

**No runaway loops.** Each message gets a *tool budget* (default 15 tool
calls; the owner can choose another number, and 0 means unlimited). When it's used up, the agent stops, reports what it did, and asks
whether to continue (status *waiting for go-ahead*). Any message from its
owner continues it with a fresh budget.

**Non-stop mode.** For agents that should never stop working, such as one
that plays a game forever, tick *Non-stop mode* when you start the
conversation. It's powerful and costly, so it always needs a human's
decision: an outside agent may pass `nonstop: true` to `agent_spawn` only
after asking its human and getting an explicit yes (the tool's documentation
and `swarm_guide` tell agents so). Such an agent:
- works continuously and never pauses to ask for permission: no tool budget,
  and when it ends a reply it is told to continue;
- paces itself with its sleep tool: long sleeps while it waits for something
  slow, short or none when the task needs fast reactions (put the pace you
  need in its instructions). If it replies without doing anything, it rests
  10 seconds, and after a minute of that the rest doubles every minute, up to
  10 minutes, so an idle agent costs almost nothing;
- still talks to you and its owner: messages reach it between its steps, it
  answers them and keeps working, and `agent_send` returns that answer;
- compacts itself automatically when its context reaches 800,000 tokens
  (`SWARM_NONSTOP_COMPACT_AT`);
- resumes by itself after the swarm restarts;
- stops only when you pause it (Pause button or `agent_stop`; any message
  resumes it) or archive it. On a remote server it keeps working while your
  computer is off.

**What agents won't do.** Agents can't run code, and they don't hand you
code or commands to run to finish their task unless you said that's fine:
the swarm is for running and administering work, and its humans are often
not developers. When their tools can't do something, they tell you plainly
what's missing (for example an MCP server you could allow). `swarm_guide`
tells the agents that use the swarm the same.

**Effort.** How hard an agent thinks and works on each reply is its *effort
level*, chosen by its owner when the conversation starts: `low`, `medium` (the
default, and Claude's own default), `high`, `xhigh` or `max`. Higher levels
think more readily and at greater length: better on hard problems, slower and
costlier. Agents can't raise their own level. Current Claude models always
think adaptively, deciding per reply whether and how much to think, so effort
is the control rather than a thinking budget. The thinking appears, summarized,
in the web view.

**Context.** Every reply reports the context size, in tokens (one token is
about 4 characters, or 3/4 of an English word). Past 70% of the window
(configurable) the agent and its owner are warned. *Compaction* replaces the
earlier conversation with a detailed summary the agent writes. The brief is
never summarized: the standing instructions stay word for word, and when a
conversation has none, its first message is kept word for word above the
summary. Every message you injected into an agent's conversation is kept word
for word too, so your overrides survive compaction. You trigger it
with the Compact button, `agent_compact`, or by asking the agent. The full
history always stays visible in the web view.

**Kill = archive.** Killing a conversation stops it and moves it, with its
whole history and scratch folder, to the Archive. Nothing is deleted.

**Calls.** Every agent turn is its own Claude API call loop, with prompt
caching always on (`system-prompt.md`, the files in `context\`, and the
agent's standing instructions form the cached prefix).

## Requirements

- Windows 10 or 11, with Windows PowerShell 5.1 (included with Windows).
- A Claude API key from the [Claude Console](https://console.anthropic.com).
- Microsoft Edge (optional) for the web view window. Without it, the page
  opens in your default browser.

## Install (local)

1. Put the project in a folder, for example `C:\Tools\agent-swarm-mcp`. The
   rest of this guide calls it `<install-dir>`.
2. In `<install-dir>`, copy `.env.example` to `.env` and add your key:

   ```
   ANTHROPIC_API_KEY=sk-ant-...
   ```

   `.env.example` lists every optional setting (models, budgets, context
   warning, parallel turns, timeouts, ports, remotes).
3. Optionally, edit `system-prompt.md` (the standing instructions every agent
   gets) and put reference material in `context\`.
4. Double-click `open-webview.bat`. The swarm starts and its web view opens.
   Start a conversation with **New**: give it a name, pick a model, and chat.

When the swarm was started this way, it stops once you close the web view
and no agent is working. Your conversations are kept in `state\` and come back
the next time.

## Connect it to Claude

Replace `C:\Tools\agent-swarm-mcp` with your `<install-dir>`. In JSON, write
each backslash twice.

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

Every app that connects starts its own swarm process, but only one of them
runs agents: the first one. The others pass their calls to it through a named
pipe, so all of them see the same agents. If the first one exits while agents
are still working, it keeps running until they finish; when it's gone, the
next process takes over.

## The web view

`open-webview.bat` opens it (or brings it to the front), and so does asking
any connected agent to call `debug_open_webview`. With `MCP_UI_OPEN=true` (the
default), it also opens when the swarm starts. The page is served on
`http://localhost:8770/` (or the next free port up to 8779) only while its
window is open; closing the window frees the port. Agents keep working while
it's closed.

- **Header:** one chip per instance (this computer and each remote) with its
  active, working and waiting agents. Click a chip to manage that instance;
  it opens on its conversations. The window remembers the selected tab and
  conversation of each instance until it is closed.
  **You are** picks the name your messages are signed with.
- **Conversations:** every agent and its full transcript: messages, thinking,
  each tool call with its input and result, token use, notices, compactions.
  You can message any conversation. In one owned by an agent, your message
  is *injected*: the agent treats it as coming from you, the developer, and
  your decision overrides its owner's instructions; the agent then tells its
  owner what changed, and its owner receives your message itself on its next
  call to the swarm. You can also compact (after a confirmation), stop or
  archive any conversation.
  **Files** shows an agent's scratch folder (active or archived): view a
  file, download it, or download everything as a zip.
- **Attachments:** drop files on a conversation, or click **Attach**, then
  send. They are saved in the agent's `uploads/` folder (up to 200 MB per
  message, within the scratch folder's limit, 1000 MB by default), and the
  message tells the agent which files arrived.
  Agents read text files; other files are kept for MCP tools that can use
  them.
- **Downloads from agents:** an agent calls `offer_download` for files it
  made, and a download card appears in the conversation.
- **Archive:** killed conversations, read-only, with their full history.
- **MCP servers:** the allow list, each server's status, tools and calls, and
  **Import from Claude Desktop**.
- **Remote:** connect the remote swarm (its address and an access key) or
  disconnect it.
- **Log:** the server log.

## MCP servers for local agents

Local agents can use the MCP servers in the swarm's own allow list,
`state\mcp-servers.json`. It uses the same format as Claude Desktop's
`mcpServers` section.

The easy way: in the web view, open **MCP servers** and click **Import from
Claude Desktop**. The swarm finds your Claude Desktop config on its own (its
location differs between installs; if several are found, pick one, and if
none is, paste its path or set `SWARM_CLAUDE_CONFIG`). Tick the servers your
agents may use and click **Import**. The swarm never imports itself. Servers start the first time an
agent needs them and keep running until the swarm stops.

You can also edit the file by hand; changes apply within a few seconds:

```json
{
  "mcpServers": {
    "my-editor": {
      "command": "powershell.exe",
      "args": ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "C:\\Tools\\editor-mcp\\start.ps1"]
    },
    "api-cache": {
      "command": "cmd",
      "args": ["/c", "C:\\Tools\\api-cache-mcp\\mcp-server.bat"]
    }
  }
}
```

Agents see these tools as `mcp__<server>__<tool>`. The servers' replies,
including images, go to the agent as tool results.

## Tools

Every call names the caller (`agent`: the caller's own name, the same in
every chat; see *How a calling agent knows who it is*). Agents are addressed by `name`; the short form (`parser`) works for
your own instance.

| Tool | What it does |
| --- | --- |
| `swarm_guide` | Whether this swarm is local (your computer) or remote (a server), which MCP servers its agents can use, and how the swarm works. Agents should call it first. |
| `swarm_status` | Counts of active, working and archived agents here (and on each remote, from the local swarm), models and defaults. |
| `agent_spawn` | Start an agent: `name` (mandatory), model, effort level, title, instructions, tool budget (tool calls per message), optional first message. |
| `agent_send` | Send a message and wait up to `wait_seconds` (seconds; default 50, max 300) for the reply. |
| `agent_read` | Status, context size and events since a sequence number. Use it when a reply took longer than the wait. |
| `agent_list` | Your agents, optionally with your archived ones. |
| `agent_stop` | Stop the running turn without archiving. |
| `agent_kill` | Kill an agent: its conversation moves to the archive. |
| `agent_compact` | Compact a conversation. |
| `agent_files` | List or read an agent's scratch folder. |
| `sleep` | Wait `seconds` (1-300) before returning, between polls. The swarm keeps serving other calls meanwhile. |
| `debug_open_webview` | Local only: open or focus the web view. |

## Remote instance

A remote swarm runs the same script on a server, in Docker, so agents keep
working while your computer is off. It is reached over HTTPS only: by Claude
(as a custom connector), by your local swarm (as its admin gateway), and by
you (its own web view). Every one of them signs in with an *access key*
created on the server.

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
   change: everything in `state/` is kept, and working agents resume.

4. **Create access keys,** one per user so each can be revoked alone:

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
Docker volume `agent-swarm-mcp_caddy_data`. To back up a server, copy
`state/` and `config.env` (`tar czf swarm-backup.tgz state config.env`).
Deleting `state/` is the only way to lose that data.

### Use it

- **Claude:** add a custom connector with the URL `https://<host>/mcp`, then
  sign in with an access key on the page that opens. Agents use the same
  tools as on the local swarm.
- **Your local swarm:** see below.
- **Its own web view:** `https://<host>/`, signed in with an access key.

The server runs as the user who started `run.sh`, and its files in `state/`
can only be read by that user. Logs: `docker logs -f agent-swarm`.

### Connect your local swarm

**Connect a deployed remote from the web view.** Open the **Remote** tab, enter
the remote's address and an access key created on that server, and click
**Connect**. The swarm asks the remote who it is and, when the key works,
saves it in `state\remotes.json` and shows the remote's chip in the header.
**Remove** disconnects it again (its agents keep running on the server).

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
computer, connect each to the same remote: every one of them sees and manages
all of the remote's agents. Remote agents spawned by a local conversation are
owned by `local.<agent>.<computer>` (the computer's name, shortened), so
conversations on different computers never collide.

## TODO

- **More than one remote.** For now a local swarm manages one remote. The
  code already keeps a table of remotes (the web view's instance chips, the
  gateway, remote spawning and cleanup all take a remote name), so adding
  more is mostly a matter of configuration.

## Files

| Path | What it is |
| --- | --- |
| `mcp-server.bat` | Launcher for MCP clients (stdio). |
| `open-webview.bat` | Opens the web view; starts the swarm if it isn't running. |
| `mcp-server.ps1` | The server: MCP, web view, scheduling, remote gateway. |
| `lib\core.ps1` | Agent turns, scratch tools, the MCP client, compaction (shared with the worker threads). |
| `lib\webview.html` | The web view. |
| `system-prompt.md` | Standing instructions every agent gets. |
| `context\` | Extra reference files every agent gets, after the system prompt. |
| `.env.example` | Settings template. Copy it to `.env`. |
| `Dockerfile`, `docker-compose*.yml` | The remote instance's image (PowerShell 7 on Ubuntu) and containers. |
| `run.sh`, `key.sh`, `deploy.sh` | Remote: start or update it, manage access keys, copy the folder to a server. |
| `config.env.example` | Remote settings template. Copy it to `config.env` on the server. |
| `docs\` | Images for this README. |
| `caddy\` | Caddy config for HTTPS: the bundled Caddy's `Caddyfile`, and a site block for a Caddy you already run. |
| `state\` | Created at runtime: `conversations\<name>\` (meta, transcript, context, scratch), `archive\<name>\`, `mcp-servers.json`, `remotes.json`, `humans.json`. |

`.env`, `config.env`, `state\`, the contents of `context\` and `test\` (local
test tools) are listed in `.gitignore`.

## Security

The local swarm is built for one person on one computer.

- **The web view is plain HTTP on localhost**, with a random token that
  changes on every launch. It rejects other machines and other websites in
  your browser. Never expose the port.
- **Agents can only reach what you allow.** Their file tools are confined to
  their scratch folders, and they can't run code. They can use every MCP
  server in the allow list, though, with whatever power those servers have, so
  only allow servers you trust agents with.
- **Everything on disk is plain text** in `state\`: transcripts, scratch
  files, the allow list, which contains the env values you imported
  (possibly secrets), and `remotes.json` with the remote's access key. Keep
  the folder private.
- **Calls to the Claude API and to remotes use HTTPS.** Other addresses are
  refused, except `http://localhost` for testing.

The remote swarm is for the same person, on a server:

- **Every way in needs an access key.** Keys are stored as hashes in
  `state/keys.json`. Connector sign-ins use OAuth 2.1 (PKCE), with tokens
  that expire and rotate; the web view uses a session cookie and a CSRF token.
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
- **Remote: no HTTPS after `run.sh`:** check that the DNS name points to the
  server and that 443/tcp is open, then read the certificate log:
  `docker logs agent-swarm-caddy` (or your own Caddy's log).
- **Remote: "key rejected" in the Remote tab:** list the keys on the server
  with `./key.sh list`; create a new one if needed.
- **An MCP server shows "error":** the message comes from starting it. Fix its
  command in `state\mcp-servers.json` (or re-import), then click **Restart**.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Diego Perini; see [NOTICE](NOTICE),
which must be kept in copies and derived works that you distribute.

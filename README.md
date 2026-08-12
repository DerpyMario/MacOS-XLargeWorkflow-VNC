# fastmac-gui

> Get a MacOS desktop over VNC or RustDesk, for free, in around 5 minutes

This repo extends upon fastmac, enabling the built in MacOS VNC server, doing a hacky trick to set a VNC password and a new admin user account, and adds ngrok to your system to set up a tcp tunnel for VNC/Apple Screen Sharing. RustDesk is available as an alternative backend, and the setup pre-approves the macOS privacy permissions that otherwise leave you staring at a black screen.

## Quick start

* Clone this repo
* Add secrets to your cloned repo under **Settings → Secrets and variables → Actions**:

  | Secret | Needed for | What it is |
  |---|---|---|
  | `NGROK_AUTH_TOKEN` | VNC | your auth key from https://dashboard.ngrok.com/auth |
  | `VNC_USER_PASSWORD` | VNC | password for the "VNC User" (`vncuser`) account |
  | `VNC_PASSWORD` | VNC | the VNC-only password (**first 8 characters only** — a VNC protocol limit) |
  | `RUSTDESK_PASSWORD` | RustDesk | unattended access password |
  | `RUSTDESK_HOST` | RustDesk (optional) | self-hosted rendezvous/relay server |
  | `RUSTDESK_KEY` | RustDesk (optional) | public key for the self-hosted server |

* Run the workflow from **Actions → mac → Run workflow**. The workflow is
  `workflow_dispatch` only, so it never fires on a push and never burns minutes
  by accident.

The connection details are printed in the log **and** written to the run summary
page, so you don't have to dig through step output to find the tunnel address.

### Workflow inputs

| Input | Default | Notes |
|---|---|---|
| `runner` | `macos-26-intel` | also `macos-26`, `macos-15-intel`, `macos-15` |
| `backend` | `vnc` | `vnc`, `rustdesk`, or `both` |
| `vnc_auth` | `legacy` | `legacy` works with any viewer; `ard` is Apple-only (see below) |
| `ngrok_region` | `us` | `us`, `eu`, `ap`, `au`, `sa`, `jp`, `in` |
| `duration_minutes` | `300` | how long to hold the machine open |
| `desktop_user_console` | `false` | log `vncuser` into the console (see below) |
| `enable_tmate` | `false` | also opens a tmate shell, restricted to the actor |

## The desktop account

Both backends run the desktop as a dedicated **admin account, `vncuser`**, created
with your `VNC_USER_PASSWORD` — not as the `runner` account the CI job uses.
`runner` cannot be reused: it holds a SecureToken, so macOS refuses to reset its
password without the old one, and there is no credential left to give a client.
The account is created, added to `admin`, and its password is **verified with
`dscl -authonly`** before anything else runs, because a login that silently
fails to authenticate is another way to end up staring at a login window.

`VNC_USER_PASSWORD` is therefore required for both backends.

### Giving that account the screen

Creating the account is easy; giving it a **GUI session** is the awkward part.
A screen sharing tool can only capture a session that has a window server
behind it, and on a runner the console session belongs to `runner`. There are
two ways `vncuser` gets a desktop of its own:

* **Connect as `vncuser` over Apple Screen Sharing.** Authenticating with the
  system account makes macOS spin up a session for it on demand. This needs a
  client that speaks Apple's authentication, so it means `vnc_auth: ard`.
* **`desktop_user_console: true`.** Configures automatic login for `vncuser`
  and restarts `loginwindow`, handing it the console session. RustDesk then
  runs as `vncuser` against a real desktop, and the legacy (RealVNC-compatible)
  VNC path shows that desktop too.

  ⚠️ **This logs out whoever holds the console**, which is the account the job
  runs under. If the Actions agent lives in that GUI session, the job ends with
  it. It is off by default for that reason — try it knowing the run may stop.

When `vncuser` has no GUI session, RustDesk falls back to the console account
and says so rather than capturing a session that does not exist:

```
[warn] vncuser has no GUI session, so there would be no screen to capture
[warn] falling back to the console account 'runner'
[warn] set DESKTOP_USER_CONSOLE=yes to log vncuser in and hand it the console
```

## Which VNC client can connect

macOS advertises several authentication schemes, and the viewer picks one
before any password is exchanged. Apple's own types (30, 33, 35) are only
partly implemented by third-party viewers, and they abort the handshake rather
than falling back — **RealVNC Viewer reports `Protocol error: key length too
large`**, which looks like a broken tunnel but is really an auth mismatch.

Enabling **Remote Management** (ARD) is what puts those Apple-only types on the
wire. The default `vnc_auth: legacy` therefore uses plain **Screen Sharing**
with the legacy VNC password, which advertises security type 2 — the one every
viewer understands.

Each run prints the types the server actually ended up offering:

```
security types offered   : 2, 30
    2  VNC password (legacy, understood by every viewer)
   30  Apple Diffie-Hellman (RealVNC fails with 'key length too large')
legacy VNC auth is available -- cross-platform viewers can connect
```

| Client | `legacy` (default) | `ard` |
|---|---|---|
| Apple Screen Sharing (macOS) | works | works |
| RealVNC Viewer | works | **fails: key length too large** |
| TigerVNC / Remmina / TightVNC | works | fails |

In `legacy` mode, authenticate with the **`VNC_PASSWORD`** secret (the VNC-only
password), not the account password. Remember only its first 8 characters are
used — the protocol carries no more, and the setup warns if yours is longer.

Choose `ard` only if you specifically need Apple Remote Desktop features and
are connecting from macOS.

## RustDesk unattended access

Two RustDesk defaults make a CI host unusable, and together they produce
exactly the "Connected, waiting for image" hang with a one-time password that
keeps changing:

* `approve-mode` defaults to asking someone **at the host** to click Accept.
  Nobody is sitting at a runner, so the viewer waits for an image that is never
  authorised.
* `verification-method` defaults to a **temporary** password that RustDesk
  regenerates on restart, invalidating whatever was printed in the log.

The setup writes `approve-mode = 'password'` and
`verification-method = 'use-permanent-password'`, sets your `RUSTDESK_PASSWORD`
as the permanent password, and then **verifies both actually persisted** —
RustDesk rewrites its own config on startup, so the run re-applies them and
restarts the app if they did not stick.

### RustDesk connects but the screen stays blank

If the viewer sits on **"Connected, waiting for image"** while RustDesk's
**terminal and file manager work fine**, the connection is healthy and the
missing piece is Screen Recording — the terminal and file transfer do not need
that permission, screen capture does.

This is a platform limitation, not a configuration mistake. Granting Screen
Recording to a third-party app means writing to `TCC.db`, which **System
Integrity Protection protects even from root**. When SIP is enabled — as it is
on GitHub-hosted runners — no third-party app can be pre-authorised for screen
capture without someone clicking the prompt on the machine itself.

**Apple's own Screen Sharing is exempt from that restriction**, which is why
the VNC backend can produce a picture where RustDesk cannot. So:

* **For the desktop image, use the VNC backend** over the ngrok tunnel.
* RustDesk remains useful for **terminal access and file transfer**, which work
  regardless. Running `backend: both` gets you each of them.

Every run now states which situation it is in, rather than leaving you to infer
it from a hanging viewer:

```
==> Screen Recording grant is present in the consent database
```
```
[warn] Screen Recording could NOT be granted to RustDesk
[warn] System Integrity Protection is enabled: TCC.db is protected from root,
[warn] so no third-party app can be pre-authorised for screen capture here.
[warn] Apple's own Screen Sharing is exempt, so use the VNC backend for the picture.
```

The same verdict is written to the run summary. Note that the `screen-probe`
artifact can be empty even when Screen Sharing works: `screencapture` launched
from a CI shell inherits the shell's (absent) permission, so treat a failed
probe as inconclusive rather than proof the display is dead.

*NOTE* If you're using Apple Screen Sharing or RealVNC Viewer, use the system username and password ("VNC User"/your set password), NOT your VNC-only password!

## Why the screen used to come up black

Connecting successfully and then seeing nothing is the classic failure here, and
it has four separate causes. `scripts/setup-vnc.sh` and
`scripts/setup-rustdesk.sh` address all of them:

* **No Screen Recording permission.** Since Catalina, screen capture requires
  TCC consent. A headless runner has nobody to click the prompt, so the capture
  silently returns empty frames. The setup writes the grants straight into the
  consent database (`scripts/common.sh:tcc_grant`) before anything starts, then
  restarts `tccd` so they take effect. The `access` table schema has changed
  across releases, so the INSERT is built from the columns the machine actually
  has. This needs SIP to be disabled, which is the case on GitHub's macOS
  images — the script says so explicitly in the log if it isn't.
* **The display went to sleep, or the screen saver kicked in.** Both are served
  to the client as a black rectangle. Sleep, display sleep and the screen saver
  are disabled, any running `ScreenSaverEngine` is killed, and a `caffeinate`
  assertion is held for the life of the job.
* **The session landed on a virtual display instead of the console.**
  `VNCAlwaysStartOnConsole` pins incoming sessions to the real framebuffer the
  window server is already drawing into. Set `VNC_ALWAYS_CONSOLE=no` to opt out.
* **A brand new account boots into Setup Assistant**, which reads as a blank
  screen over VNC. Its prompts are pre-answered for `vncuser`.

### Diagnosing it if it still happens

Every run takes a screenshot on the runner itself and uploads it as the
`screen-probe` artifact. That splits the problem cleanly in two:

* **The artifact looks like a desktop** → capture works; the problem is your
  client, the tunnel, or the credentials.
* **The artifact is black or missing** → capture is broken on the machine. The
  log says which check failed. An all-black PNG compresses to almost nothing,
  so the script also warns when the capture is suspiciously small.

## Repo layout

| File | Purpose |
|---|---|
| `.github/workflows/mac.yml` | the `workflow_dispatch` workflow |
| `scripts/common.sh` | TCC grants, display/sleep handling, screen probe |
| `scripts/setup-vnc.sh` | desktop account + Apple Screen Sharing |
| `scripts/setup-rustdesk.sh` | RustDesk install, permissions and unattended password |
| `scripts/ngrok.sh` | tunnel setup and address reporting |
| `scripts/rfb-probe.py` | reports which VNC auth types the server offers |
| `configure.sh` | thin wrapper kept for the original one-shot invocation |

----
# Lessons learned in my hacking this to bits:

## We don't know the password to `runner`.
Okay, let's reset the passwor-

    # passwd runner
    Changing password for runner.
    Enter old password:

... right. macOS, at some point, implemented SecureToken-based users. You can't reset the password with `passwd`, it asks for your old password -- even trying to change it from root!

Workaround: Create a new user, `VNC User` aka `vncuser`. We don't *really* need to run as runner, plus, we get the 'out of box' new user setup when we VNC in. Because we're root... we can just straight up add new users. Early iterations of this script I was still learning how to add users and got to see weird behavior when macOS doesn't have a home folder for a user (dumped right to a non-working desktop, for instance).

## macOS Catalina won't let you purportedly configure VNC from the CLI, or at least, set the password anymore...

`Warning: macos 10.14 and later only allows control if Screen Sharing is enabled through System Preferences`

Easy fix: set the password by hand by hashing it into the preferences file. See http://hints.macworld.com/article.php?story=20071103011608872.

## VNC is slow.
Well, this thing isn't exactly GPU accelerated. It's running on an ESXi powered Mac sitting at MacStadium...

----
# fastmac

> Get a MacOS or Linux shell, for free, in around 2 minutes

I don't have a Mac, but I often want to test my software on a Mac, or build software for folks using Macs. Rather than shelling out thousands of dollars to buy a Mac, it turns out we can use GitHub Actions to give us access to one for free! `fastmac` makes this process as simple as possible. Note that this only gives us access to a terminal shell, not a full GUI. See below for how to get started. Here's a little video that shows all the steps (click it for a full-size version):

<a href="https://files.fast.ai/images/fastmac.png"><img src="https://files.fast.ai/images/fastmac-optimize.gif" width="727" /></a>

**NB**: Please check the [GitHub Actions Terms of Service](https://docs.github.com/en/github/site-policy/github-additional-product-terms#5-actions-and-packages). Note that your repo needs to be public, otherwise you have a strict monthly limit on how many minutes you can use. Note also that according to the TOS the repo that contains these files needs to be the same one where you're developing the project that you're using it for, and specifically that you are using it for the "*production, testing, deployment, or publication of [that] software project*".

## Clone template

First, [click here](https://github.com/fastai/fastmac/generate) to create a copy of this repo in your account. Type `fastmac` under "repository name" and then click "Create repository from template". After about 10 seconds, you'll see a screen that looks just like the one you're looking at now, except that it'll be in your repo copy.

**NB**: Follow the  rest of the instructions in repo copy you just made, not in the `fastai/fastmac` repo.

## Run the `mac` workflow

Next, <a href="../../actions?query=workflow%3Amac">click here</a> to go to the GitHub actions screen for the `mac` workflow, and then click the "Run workflow" dropdown on the right, and then click the green "Run workflow" button that appears.

<img width="365" src="https://user-images.githubusercontent.com/346999/92965396-91320680-f42a-11ea-9bc3-90682e740343.png" />

## Access the shell using ssh or browser

After a few seconds, you'll see a spinning orange circle. Click the "mac" hyperlink next to it.

On the next screen, you'll  see another spinning orange circle, this time with "build" next to it. Click "build".

This will show the progress of your Mac that's getting ready for you. After a while, the "Setup tmate session" section will open, and once it's done installing itself, it will repeatedly print lines like this:
```
WebURL: https://tmate.io/t/rXbusP3qkYsfALDSLMQZVwG3d

SSH: ssh rXbusP3qkYsfALDSLMQZVwG3d@sfo2.tmate.io
```

Copy and paste the ssh line (e.g `ssh rXbusP3qkYsfALDSLMQZVwG3d@sfo2.tmate.io` in this case) into your terminal (Windows users: I strongly recommend you use [WSL](https://docs.microsoft.com/en-us/windows/wsl/install-win10) if possible) and press <kbd>Enter</kbd>.

You'll see a welcome message. Press <kbd>q</kbd> to remove it, and you'll be in a Mac shell! The shell already has [brew](https://brew.sh/) installed, so you can easily add any software you need.

Instead of using ssh in your terminal, you can paste the "WebURL" value into your browser, to get a terminal in your browser. Whilst this is adequate if you're in a situation that you can't access a terminal (e.g. you have to do some emergency work on your phone or tablet), it's less reliable than the ssh approach and not everything works.

## Stop your session

Your session will run for up to six hours. When you're finished, you should close it, since otherwise you're taking up a whole computer that someone else could otherwise be using!

To close the session, click the red "Cancel workflow" on the right-hand side of the Actions screen (the one you copied the `ssh` line from).

## Auto-configuration of your sessions

In your `fastmac` repo, edit the `script-{linux,mac}.sh` files to add configuration commands that you want run automatically when you create a new session. These are bash scripts that are run whenever a new session is created.

Furthermore, any files that you add to your repo will be available in your sessions. So you can use this to any any data, scripts, information, etc that you want to have access to in your fastmac/linux sessions.

## Behind the scenes

`fastmac` is a very thin wrapper around [tmate](https://tmate.io/), so all the features of tmate are available. tmate itself is based on [tmux](https://github.com/tmux/tmux/wiki), so you have all that functionality too. In practice, that means other people can connect to the same ssh session, and you'll all be sharing the same screen! This can be very handy for debugging and support. The integration with Github Actions is provided by [action-tmate](https://github.com/mxschmitt/action-tmate).

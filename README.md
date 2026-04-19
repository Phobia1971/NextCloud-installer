# setup-nextcloud.sh

A single, interactive Bash script that turns a fresh Ubuntu VM into a running
**Nextcloud All-in-One** server. No Docker Compose files to edit, no RAID
commands to memorize — just run it and answer a few questions.

> **Who this is for:** anyone who wants to self-host Nextcloud at home, on a
> Proxmox / Hyper-V / VirtualBox VM, or on a bare-metal Ubuntu box, without
> being a Linux sysadmin. If you can SSH into a server and type your password,
> you can use this.

---

## Table of contents

- [What it does, in plain English](#what-it-does-in-plain-english)
- [Will it work on my setup?](#will-it-work-on-my-setup)
- [Before you start](#before-you-start)
  - [Always required](#always-required)
  - [Required if you want Nextcloud on the public internet](#required-if-you-want-nextcloud-on-the-public-internet)
- [Quick start](#quick-start)
- [Walkthrough of the questions it asks](#walkthrough-of-the-questions-it-asks)
- [How the storage layout works](#how-the-storage-layout-works)
  - [It figures out the RAID level automatically](#it-figures-out-the-raid-level-automatically)
  - [SSDs and HDDs get different jobs](#ssds-and-hdds-get-different-jobs)
  - [Examples for common setups](#examples-for-common-setups)
- [The two modes explained](#the-two-modes-explained)
  - [Internet mode (recommended)](#internet-mode-recommended)
  - [LAN mode](#lan-mode)
- [What happens after the script finishes](#what-happens-after-the-script-finishes)
- [I already ran it — can I run it again?](#i-already-ran-it--can-i-run-it-again)
- [Running without prompts (scripted install)](#running-without-prompts-scripted-install)
- [Troubleshooting](#troubleshooting)
- [What this script will NOT do for you](#what-this-script-will-not-do-for-you)
- [License](#license)
- [Author](#author)

---

## What it does, in plain English

Out of the box, the script walks through four steps on your server:

1. **Tidies up the base system.** Runs updates, installs a firewall
   (UFW + Fail2ban), enables automatic security updates, sets the hostname
   and timezone, and trims some noise from the login banner.
2. **Sets up disk storage.** Looks at the disks attached to the machine,
   decides the best RAID layout, and creates two mount points: one big one
   for your Nextcloud files (`/mnt/storage`), and a faster one for the Docker
   engine (`/var/lib/docker`). **This step wipes disks and asks you to
   confirm by typing the word `NUKE`.**
3. **Installs Docker.** The official one from Docker's own repository, with
   sensible defaults for log rotation and crash recovery.
4. **Installs Nextcloud All-in-One.** Pulls the "mastercontainer" image and
   starts it. You then click through AIO's own web wizard to finish setup.

Every step that might take a while shows a progress bar so you know the
script isn't stuck.

---

## Will it work on my setup?

**Yes** if you have:

- Ubuntu Server **22.04** or **24.04** (64-bit / amd64 or arm64)
- At least one disk attached *in addition* to the OS disk (optional but strongly
  recommended — the script runs fine with none, but Nextcloud will end up on
  your OS drive)
- Internet access on the VM so it can download packages and Docker images
- `sudo` / root access

**It might work** (untested by the author) on:

- Debian 12 — probably fine, the Docker apt source line is generic enough
- Other Ubuntu flavors (Server MATE, XFCE variants, etc.) — probably fine

**It won't work** on:

- Anything that isn't Debian-based (no RHEL / Fedora / Arch / Alpine)
- Ubuntu LTS versions older than 22.04

---

## Before you start

### Always required

- A **fresh Ubuntu 22.04 or 24.04 VM** (or bare metal machine). If the machine
  already has stuff on it, the script's idempotence check handles most of it —
  but for peace of mind, take a snapshot / backup first.
- **SSH** enabled so you can connect.
- **`sudo` privileges** for the user you log in as.
- **Internet access** — the script downloads apt packages, Docker's GPG key,
  and the Nextcloud images.
- Ideally, **one or more extra disks** attached to the VM (beyond the OS disk).
  The script will detect them and build a RAID.

### Required if you want Nextcloud on the public internet

To let people outside your house reach Nextcloud at `https://cloud.example.com`,
you need these things ready *before* you run the script:

- A **domain name you own** (e.g. `cloud.example.com`).
- A **reverse proxy** somewhere on your network that:
  - has a valid TLS certificate for your domain (Let's Encrypt,
    Cloudflare Origin Cert, or similar)
  - forwards traffic for your domain to this server on **port 11000**
- **DNS** set up so the domain points at your public IP.
- **Port forwarding** on your router sending 80 and 443 to the reverse proxy.

> If that sounds like a lot, skip the internet part — use **LAN mode** instead
> (see below). You can always expose Nextcloud to the public internet later by
> updating DNS and your reverse proxy; nothing on the Nextcloud server has
> to change.

---

## Quick start

Three steps on your Windows / Mac / Linux workstation and the server:

```bash
# 1. Copy the script to the VM (adjust user and hostname)
scp setup-nextcloud.sh you@your-vm:~/

# 2. Log in
ssh you@your-vm

# 3. Run it
sudo bash setup-nextcloud.sh
```

That's it. The script will ask you questions one at a time. Press **Enter** at
each prompt to accept the default it detected.

---

## Walkthrough of the questions it asks

When you run it, you'll see something like this:

```
Access mode:
  1) internet  - reachable at a public domain via an existing reverse proxy
  2) lan       - LAN-only, no external proxy, skip domain validation
Choose [1/2]:
```

Pick **1** if you already have a reverse proxy + domain set up, **2** otherwise.

Then a block of **detected** values — the script reads these from your running
system and asks you to confirm each one. Press Enter to keep the default.

```
Detected from this system (press Enter at each prompt to accept):
  hostname : myvm
  fqdn     : myvm.local
  timezone : Europe/Amsterdam
  LAN CIDR : 192.168.1.0/24  (via eth0)
```

Followed by prompts for:

| Question              | What to put                                                                    |
|-----------------------|--------------------------------------------------------------------------------|
| Short hostname        | What your server is called (usually just accept the default)                   |
| FQDN                  | Full name incl. local domain (e.g. `myvm.home.lan`)                            |
| Timezone              | `Europe/Amsterdam`, `America/New_York`, etc. (see `timedatectl list-timezones`)|
| LAN CIDR              | Subnet that's allowed to see the admin UI, e.g. `192.168.1.0/24`               |
| Docker user           | Your non-root username — gets added to the `docker` group                      |
| Domain (internet mode)| `cloud.example.com`                                                            |
| Proxy IP (internet)   | LAN IP of your nginx/Traefik/Caddy reverse proxy                               |

It shows a summary, asks for final confirmation, and then starts.

During the storage phase you'll see a list of disks and be asked to
type `NUKE` to proceed. **Anything on those disks will be erased.** Read the
list carefully.

---

## How the storage layout works

This is the most magic-feeling part of the script, so here's what it's doing.

### It figures out the RAID level automatically

The script counts how many extra disks of each type you have, then picks a
RAID level per tier:

| Disks per tier | What you get                                          |
|---------------:|-------------------------------------------------------|
|              1 | Single disk, no RAID, no fault tolerance              |
|              2 | RAID1 mirror — survives 1 disk failure                |
|              3 | RAID5 — survives 1 disk failure                       |
|             4+ | RAID6 — survives **2** disk failures                  |

### SSDs and HDDs get different jobs

- **HDDs** (spinning disks) hold the big-but-slow stuff: your photos, documents,
  and everything under "Files" in Nextcloud. Mounted at `/mnt/storage`.
- **SSDs** hold the small-but-fast stuff: the database, cache, preview
  thumbnails, and Docker's internal data. Mounted at `/var/lib/docker`.

If you only have one type of disk, they all go on one filesystem and Docker
is told to store its data in `/mnt/storage/docker`. Simpler but slower — you'll
see a warning.

### Examples for common setups

**3 HDDs + 2 SSDs (the "ideal" layout):**
```
/mnt/storage       -> RAID5 on the 3 HDDs (2/3 of total capacity usable)
/var/lib/docker    -> RAID1 mirror on the 2 SSDs
```

**Just 2 HDDs, no SSDs:**
```
/mnt/storage       -> RAID1 mirror on the 2 HDDs
Docker             -> shares /mnt/storage (via /mnt/storage/docker)
```

**Big box with 6 HDDs + 2 SSDs:**
```
/mnt/storage       -> RAID6 on the 6 HDDs (4/6 capacity, survives 2 disk losses)
/var/lib/docker    -> RAID1 mirror on the 2 SSDs
```

**Single disk (no extra storage):**
```
Script asks you to skip the storage phase.
Nextcloud + Docker both live on the OS disk.
```

---

## The two modes explained

### Internet mode (recommended)

You're running your own cloud that you, friends, family — or clients — can
reach from anywhere. You already have:

- a domain
- a reverse proxy terminating TLS
- DNS + port-forwarding set up

The script configures the firewall so:

- **Port 8080** (the AIO admin page) is reachable **only from your LAN**
- **Port 11000** (where Nextcloud listens for the reverse proxy) is reachable
  **only from your reverse proxy's IP**

Nothing else is exposed.

### LAN mode

No public domain, no public exposure. Nextcloud only works inside your home
network. The admin page still listens at `https://<your-vm-ip>:8080`, and
you'll need to set up local DNS or `/etc/hosts` entries on your client
devices if you want to reach it by name rather than IP.

LAN mode tells AIO to **skip** its domain-validation check, because without a
public domain that check would fail.

---

## What happens after the script finishes

1. Open your web browser and go to `https://<your-vm-ip>:8080`.
2. Your browser will warn about the self-signed certificate. Accept and continue.
3. AIO will show you a **one-time passphrase**. **Copy it somewhere safe** — a
   password manager is ideal. You'll need this passphrase every time you log
   into the AIO admin page in the future.
4. Paste the passphrase into the login box.
5. Enter your domain (internet mode) or local name (LAN mode).
6. Pick the optional containers you want:
   - **Nextcloud Office** (Collabora) — edit documents in the browser
   - **Nextcloud Talk** — video/voice chat
   - **Imaginary** — faster preview generation
   - **ClamAV** — antivirus scanning on uploads (adds ~1 GB RAM)
   - **Fulltextsearch** — search inside documents (adds ~2 GB RAM)
7. Click **Start containers**. Wait 3–10 minutes while everything pulls and
   initializes. The AIO page auto-refreshes.
8. When all containers show green, AIO gives you the **initial Nextcloud admin
   password**. Save that one too.
9. Log into `https://<your-domain-or-ip>/` with username `admin` and that
   password. You're in.

> **Tip:** once logged in, go to *Users* and create yourself a normal user
> with admin privileges, then set a memorable password. Keep the generated
> `admin` account as a break-glass backup.

---

## I already ran it — can I run it again?

Yes. The script checks what's already done and only runs the remaining steps:

- **Step 1 (base tidy)** is skipped if `qemu-guest-agent` is installed
- **Step 2 (storage)** is skipped if `/mnt/storage` is mounted
- **Step 3 (Docker)** is skipped if `docker info` works
- **Step 4 (AIO)** is skipped if the `nextcloud-aio-mastercontainer` already
  exists

So if step 3 crashes halfway through, fix the problem and just re-run the
script — it picks up where it left off.

The **storage step** is the only one that won't auto-re-run. If you want to
redo the RAID (e.g. to add a disk), you need to manually stop the existing
arrays first:

```bash
sudo umount /mnt/storage /var/lib/docker
sudo mdadm --stop /dev/md0 /dev/md1
sudo mdadm --zero-superblock /dev/sdb /dev/sdc /dev/sdd  # etc
```

Then re-run the script.

---

## Running without prompts (scripted install)

For automation (e.g. Ansible, Terraform templates, CI), set everything as
environment variables:

```bash
sudo MODE=internet \
  HOSTNAME_SHORT=nextcloud \
  HOSTNAME_FQDN=nextcloud.home.lan \
  TIMEZONE=Europe/Amsterdam \
  LAN_CIDR=192.168.1.0/24 \
  DOCKER_USER=alice \
  DOMAIN=cloud.example.com \
  PROXY_IP=192.168.1.10 \
  CONFIRM_NUKE=yes \
  AUTO_YES=1 \
  bash setup-nextcloud.sh
```

`CONFIRM_NUKE=yes` skips the interactive `NUKE` typing for the storage phase.
`AUTO_YES=1` skips the final "proceed?" prompt after the config summary.

---

## Troubleshooting

**The script aborted in the middle. What do I do?**
Read the last few lines of the output — it points at a log file in
`/var/log/setup-nextcloud-<timestamp>.log`. Fix whatever it complained about
and just re-run the script; it'll skip the parts that succeeded.

**I can't reach `https://<vm-ip>:8080` from my laptop.**
Probably a firewall issue. The script allowed the subnet it detected. If your
laptop is on a different subnet (e.g. Wi-Fi guest network), add it:
```bash
sudo ufw allow from <your-subnet>/24 to any port 8080 proto tcp
```

**AIO's wizard says "domain validation failed".**
The path from the public internet to your VM is broken. Quickly test from
outside your network:
```bash
curl -v https://cloud.example.com/
```
If you get a `502 Bad Gateway` with `Server: nginx` — that's **expected** at
this stage. It means the proxy chain works; the wizard will handle it.
If you get anything else (timeout, connection refused, wrong cert), fix DNS,
port-forwarding, or your reverse proxy config first.

**Docker says "permission denied" when I try to use it as my user.**
You were added to the `docker` group but your shell doesn't know yet. Log out
and back in. Or run `newgrp docker` in the current terminal.

**RAID is still resyncing hours later.**
This is normal for big drives — a 4 TB RAID5 takes 4–8 hours to resync the
first time. You can use the array during resync, just a bit slower. Watch
progress with:
```bash
watch -n 10 cat /proc/mdstat
```

**I forgot to save the AIO passphrase.**
Rare case, but recoverable. On the server:
```bash
sudo docker exec nextcloud-aio-mastercontainer cat /mnt/docker-aio-config/data/configuration.json \
  | jq -r .password
```

---

## What this script will NOT do for you

Some things are intentionally left for you to decide:

- **SSH hardening.** Disabling root login, forcing key-only auth, changing
  the port, etc. Use standard guides (DigitalOcean / Ubuntu's own docs are
  fine) before or after the script.
- **Setting up the reverse proxy.** The script assumes you have one. If you
  don't, search for "Nextcloud AIO nginx reverse proxy" — the AIO project
  has example configs in their GitHub repo.
- **DNS records.** You configure those at your registrar or DNS provider.
- **Off-site backup.** AIO has a built-in BorgBackup feature — turn it on
  in the admin page and point it at an external drive, NAS, or cloud target.
- **Monitoring / alerting.** Add Uptime Kuma, Grafana, or whatever you
  prefer separately.

---

## License

This project is released under the **MIT License**. See [LICENSE](LICENSE).

---

## Author

Developed by **Morphius.inc** — Copyright © 2026.

Pull requests, issues, and feedback welcome.

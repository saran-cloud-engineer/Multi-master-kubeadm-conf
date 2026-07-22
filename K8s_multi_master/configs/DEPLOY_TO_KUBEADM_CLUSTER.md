# How to Roll These Configs Onto a Real kubeadm Multi-Master Cluster

This is a generic, placeholder-driven procedure. These files
(`haproxy.cfg`, `keepalived.conf`, `chk_haproxy.sh`, `notify.sh`,
`rsyslog-haproxy.conf`, `logrotate-haproxy`) are authored/edited on your local
machine — they are **not** run here. You copy them onto the actual master
servers (bare-metal boxes, VMs, or cloud instances) that will form the kubeadm cluster.

Replace every placeholder before use:

| Placeholder | Meaning | Example |
|---|---|---|
| `<VIP>` | Floating/virtual IP the API will be reachable on | `10.10.10.100` |
| `<IFACE>` | Network interface on each master carrying the VIP | `eth0` |
| `<MASTER1_IP>`, `<MASTER2_IP>`, `<MASTER3_IP>` | Real (non-VIP) IP of each control-plane node | `10.10.10.101` / `.102` / `.103` |
| `<ROUTER_ID_Mn>` | Unique VRRP `router_id` per node | `LVS_K8S_API_M1` |
| `<PRIORITY_Mn>` | VRRP priority per node (higher = preferred owner) | `200` / `150` / `100` |
| `<VRRP_AUTH_PASS>` | Shared VRRP auth secret (max 8 chars, PASS type) | generate, don't reuse |
| `<STATS_PASSWORD_HASH>` | HAProxy stats page password hash | `mkpasswd -m sha-512 '...'` |

---

## Quick Reality Check: It's Not Just IPs

It's tempting to think "swap the IPs and run it" — that's most of it, but not all of it.
These also need real values, and are easy to miss:

| Item | Where | Why it's not just an IP |
|---|---|---|
| HAProxy stats password hash | `haproxy.cfg` `userlist` block | Ships as literal placeholder text, not a real hash — auth will never succeed until you run `mkpasswd -m sha-512` and paste real output |
| VRRP `auth_pass` | `keepalived.conf` | Sample secret — pick your own (max 8 chars, PASS-auth limitation), same value on all nodes |
| `interface` name | `keepalived.conf` | Only correct if the real NIC is actually named `eth0` — check with `ip addr` on the real box (cloud VMs are often `ens160`/`ens33`/etc.) |
| `virtual_router_id` | `keepalived.conf` | Must be unique per L2 segment — change only if `51` collides with another VRRP instance on that network |
| Number of `server masterN ...` lines | `haproxy.cfg` | Must match your actual master count — add/remove lines if it's not exactly 3 |
| Script file permissions | `chk_haproxy.sh`, `notify.sh` on the server | `enable_script_security` makes keepalived refuse to run scripts that are group/world-writable or not root-owned — see step 2 |
| `socat` package | every master | Required by `chk_haproxy.sh`'s backend health check — silently skipped (with a WARN log) if missing, not a hard failure, but you lose that check |
| `whois` package | every master | Provides `mkpasswd`, needed to generate the HAProxy stats password hash above — not installed by default (`sudo apt install -y whois`) |
| `etcdctl` | every master | Required by `etcd-backup.sh`, but **kubeadm does not install it on the host** — it only runs etcd's binary inside the static pod's container image. Must be downloaded separately, matching the cluster's actual etcd version: check the running version with `kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}'`, then download the matching `etcdctl` release from `https://github.com/etcd-io/etcd/releases` and copy it to `/usr/local/bin/` on each master |
| `calicoctl` | any node used to run the eBPF enable/disable steps | Needed for `02-technical-implementation-guide.md` Section 1 — not covered by any step in this doc, install separately before attempting the eBPF switch (not urgent if you're staying on iptables mode for now) |
| Firewall rules | every master | `6443/tcp`, VRRP protocol `112` (not TCP/UDP), `8404/tcp` from mgmt subnet only |
| Log rotation | every master | Without `rsyslog-haproxy.conf` + `logrotate-haproxy` in place, HAProxy's syslog output mixes into the generic syslog file and is never isolated — logs still get rotated as part of that file if the OS's default logrotate exists, but volume isn't controlled per-service. See step 2. |

---

## 0. Prerequisites on every real master node

- OS reachable via SSH, same distro family across all masters.
- All masters on the **same L2 segment** as `<VIP>` (required for VRRP).
- Firewall allows: `6443/tcp` (API), `112` (VRRP protocol, not TCP/UDP), `8404/tcp` from
  your management subnet only (HAProxy stats).
- `containerd`, `kubeadm`, `kubelet`, `kubectl` NOT yet initialized (do the LB layer
  first, kubeadm second — see §4 for order).

---

## 1. Copy the files from your local machine to each real master

From your local machine, where these files currently live:

```bash
# Repeat for each master (only the destination host changes)
scp haproxy.cfg           <ssh-user>@<MASTER1_IP>:/tmp/haproxy.cfg
scp keepalived.conf       <ssh-user>@<MASTER1_IP>:/tmp/keepalived.conf
scp chk_haproxy.sh        <ssh-user>@<MASTER1_IP>:/tmp/chk_haproxy.sh
scp notify.sh             <ssh-user>@<MASTER1_IP>:/tmp/notify.sh
scp rsyslog-haproxy.conf  <ssh-user>@<MASTER1_IP>:/tmp/rsyslog-haproxy.conf
scp logrotate-haproxy     <ssh-user>@<MASTER1_IP>:/tmp/logrotate-haproxy

scp haproxy.cfg keepalived.conf chk_haproxy.sh notify.sh rsyslog-haproxy.conf logrotate-haproxy <ssh-user>@<MASTER2_IP>:/tmp/
scp haproxy.cfg keepalived.conf chk_haproxy.sh notify.sh rsyslog-haproxy.conf logrotate-haproxy <ssh-user>@<MASTER3_IP>:/tmp/
```

(Or use `ansible-playbook` / `rsync` / your config-management tool of choice if you're
managing more than a couple of nodes — the point is: files land in `/tmp` on the target
first, then get moved into place with root permissions in the next step.)

---

## 2. On EACH real master: install packages and place files

Run this **directly on the master**, over SSH — not on your local machine:

```bash
ssh <ssh-user>@<MASTER_IP>

sudo apt update
sudo apt install -y haproxy keepalived socat        # Debian/Ubuntu
# sudo yum install -y haproxy keepalived socat       # RHEL/CentOS equivalent
# logrotate, systemdtimer already installed install etcd based on verion it installed

sudo mv /tmp/haproxy.cfg     /etc/haproxy/haproxy.cfg
sudo mv /tmp/keepalived.conf /etc/keepalived/keepalived.conf
sudo mv /tmp/chk_haproxy.sh  /etc/keepalived/chk_haproxy.sh
sudo mv /tmp/notify.sh       /etc/keepalived/notify.sh

# keepalived.conf sets `enable_script_security`, which makes keepalived
# refuse to run tracking/notify scripts that are group/world-writable or
# not root-owned. If you skip this, the health check is treated as
# always-failing and the VIP will misbehave (flap or never come up).
sudo chown root:root /etc/keepalived/chk_haproxy.sh /etc/keepalived/notify.sh
sudo chmod 700 /etc/keepalived/chk_haproxy.sh /etc/keepalived/notify.sh

# Log rotation: without this, HAProxy's syslog output mixes into the
# generic /var/log/syslog and is never isolated/rotated on its own.
# `option tcplog` logs one line per connection, and chk_haproxy.sh's
# healthcheck can log a failure line every 2s during an outage — this
# routes HAProxy's local2-facility output into its own file and rotates it.
sudo mv /tmp/rsyslog-haproxy.conf /etc/rsyslog.d/49-haproxy.conf
sudo mv /tmp/logrotate-haproxy    /etc/logrotate.d/haproxy-k8s-api
sudo systemctl restart rsyslog
```

---

## 3. Edit the per-node values directly on that master

These 3 values in `keepalived.conf` **must be unique per node** — edit them on the box,
not before copying (or template them with `sed`/Ansible if scripting this):

```bash
sudo vi /etc/keepalived/keepalived.conf
```

```
router_id <ROUTER_ID_Mn>        # e.g. LVS_K8S_API_M1 on master1, _M2 on master2, ...
priority  <PRIORITY_Mn>         # e.g. 200 on master1, 150 on master2, 100 on master3
unicast_src_ip <MASTER_n_IP>    # THIS node's own real IP
```

```
unicast_peer {
    <OTHER_MASTER_IPs>           # the real IPs of the OTHER masters, not this one
}
```

```
virtual_ipaddress {
    <VIP>/24 dev <IFACE> label <IFACE>:vip
}
```

```
authentication {
    auth_type PASS
    auth_pass <VRRP_AUTH_PASS>   # SAME value on all 3 nodes
}
```

Generate the HAProxy stats password hash (run once, anywhere with `mkpasswd`; paste the
same hash into `haproxy.cfg` on every master):

```bash
mkpasswd -m sha-512 'YourStrongPasswordHere'
sudo vi /etc/haproxy/haproxy.cfg
# user admin password <paste-hash-here>
```

Also update `haproxy.cfg`'s backend `server` lines with the real master IPs if they
differ from the placeholders already in the file.

---

## 4. Validate syntax, then start services — BEFORE running kubeadm

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo keepalived -t -f /etc/keepalived/keepalived.conf

sudo systemctl enable --now haproxy
sudo systemctl enable --now keepalived
sudo systemctl status haproxy keepalived
```

Watch the keepalived log while it comes up — this is where a script-security
rejection (see step 2) or an auth mismatch between nodes would show up:

```bash
journalctl -u keepalived -f
```

Verify from any host on the network (not just the master itself):

```bash
ip addr show <IFACE>                       # on whichever master currently owns priority — should show <VIP>
nc -zv <VIP> 6443                          # expect: connection refused is OK pre-kubeadm, "open" once apiserver exists
```

At this point nothing is listening on 6443 yet — that's expected, kubeadm hasn't run.
HAProxy will show all backends `DOWN` until step 5. This is normal.

---

## 5. Only now run kubeadm — pointing it at `<VIP>`, not any single master's IP

On **Master1 only**:

```bash
sudo kubeadm init \
  --control-plane-endpoint "<VIP>:6443" \
  --upload-certs \
  --pod-network-cidr=<POD_CIDR> \
  --apiserver-advertise-address=<MASTER1_IP>
```

On **Master2 / Master3**, using the join command + certificate key printed by the
`init` above:

```bash
sudo kubeadm join <VIP>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key>
```

Once Master1's apiserver is up, HAProxy's health check on that backend flips to `UP`
automatically — no HAProxy restart needed (it re-checks every `inter 3s`).

---

## 6. Final verification

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes
kubectl --kubeconfig=/etc/kubernetes/admin.conf config view --minify | grep server
# should print https://<VIP>:6443, not a real master IP

curl -k https://<VIP>:6443/version
```

Also re-check the LB layer itself now that real backends exist behind it:

```bash
sudo systemctl status haproxy keepalived   # on each master
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock | grep kube-masters
# all 3 servers should now show UP (they were DOWN pre-kubeadm — that was expected)
```

Confirm logging is isolated and will actually rotate (see step 2):

```bash
ls -la /var/log/haproxy-k8s-api.log        # should exist and be growing
sudo logrotate -d /etc/logrotate.d/haproxy-k8s-api   # dry-run: shows what WOULD happen, changes nothing

# Confirm the OS's own default syslog rotation exists too — this is what
# covers keepalived's own logs and the logger calls in chk_haproxy.sh /
# notify.sh, since those still go through the generic syslog facility:
ls /etc/logrotate.d/rsyslog /etc/logrotate.d/syslog 2>/dev/null
```

I can't run any of this against your real cluster from here — this only has your local
machine, not SSH access to the master nodes. If a command above errors on the real
servers, paste the exact error back and I'll debug it directly.

---

## Appendix: How logrotate Actually Works (and how to troubleshoot it)

`logrotate` is not a daemon. It does nothing by itself. Something else has to invoke
`/usr/sbin/logrotate /etc/logrotate.conf` on a schedule — normally either:

- a systemd timer: `systemctl list-timers | grep logrotate` (most modern distros), or
- a cron job: `cat /etc/cron.daily/logrotate` (older/non-systemd setups)

If neither exists on your masters, our `logrotate-haproxy` config sits there and never
runs. Check this first — it's the single most common reason "I set up logrotate and the
file still grows forever."

### How it decides whether to rotate today

logrotate keeps a state file — usually `/var/lib/logrotate/status` (some distros:
`/var/lib/logrotate.status`) — recording the last rotation date **per log file path**.
On each invocation it checks: has enough time passed since the recorded date to satisfy
`daily`/`weekly`/`monthly`? If not, it skips that file silently — this is why running
`logrotate` twice in the same day does nothing the second time, and it's expected.

```bash
grep haproxy-k8s-api /var/lib/logrotate/status
```

### What each directive in `logrotate-haproxy` actually does

| Directive | Effect |
|---|---|
| `daily` | Rotate at most once per day (gated by the status file above) |
| `rotate 14` | Keep 14 old rotated files before deleting the oldest |
| `maxage 14` | Also delete anything older than 14 days regardless of count — a safety net if rotation was ever missed for a stretch |
| `missingok` | Don't error out if the log file doesn't exist yet (e.g. before HAProxy has logged anything) |
| `notifempty` | Don't rotate an empty file — avoids creating a pile of 0-byte rotated files during quiet periods |
| `compress` | gzip old rotated files |
| `delaycompress` | Delay compressing the MOST RECENT rotated file by one more cycle — some tools (and humans grepping recent history) expect the latest rotated file to still be plain text |
| `dateext` | Name rotated files `haproxy-k8s-api.log-20260716` instead of `.log.1` — much easier to find "what happened on a given day" |
| `create 0640 syslog adm` | Immediately create a new empty file with these permissions after rotating, so the log doesn't just disappear until the next write |
| `postrotate` / `endscript` | Shell commands run once after rotation — see below, this is the part people forget and then wonder why disk space wasn't freed |

### The #1 gotcha: why `postrotate` has to signal rsyslog

When logrotate rotates a file, it renames the old one (`haproxy-k8s-api.log` →
`haproxy-k8s-api.log-20260716`) and creates a fresh empty file in its place (via
`create`). But **rsyslogd already has the old file open by file descriptor**, and on
Linux, a process holding an open file descriptor keeps writing to that same underlying
inode even after it's renamed — it has no idea the name changed. Two consequences if you
skip the `postrotate` signal:

1. rsyslog keeps appending to the *renamed* (soon-to-be-compressed) file, not the new
   empty one — your "new" log file stays at 0 bytes forever, and log lines silently keep
   landing in what you think is an old, finished rotation.
2. Disk space isn't actually freed even after the rename/compress, because the kernel
   won't release the inode's disk blocks while a process still holds it open — you can
   end up with "disk full" even though `ls` shows small rotated files, because `du`/`df`
   still count the unlinked-but-open data underneath.

`postrotate { /usr/lib/rsyslog/rsyslog-rotate }` (or the `systemctl kill -s HUP
rsyslog.service` fallback) tells rsyslog to close and reopen its log files by name,
which is what actually makes the new empty file the one being written to, and frees the
old file's disk space for real.

### Testing without waiting for the schedule

```bash
sudo logrotate -d /etc/logrotate.d/haproxy-k8s-api   # -d = debug/dry-run, changes NOTHING
sudo logrotate -f /etc/logrotate.d/haproxy-k8s-api   # -f = force a real rotation right now
sudo logrotate -v /etc/logrotate.d/haproxy-k8s-api   # -v = verbose, shows WHY a file was/wasn't rotated
```

After a forced rotation, confirm the postrotate step actually worked (this is the check
that catches the gotcha above):

```bash
ls -la /var/log/haproxy-k8s-api*                 # new empty file + a dated rotated file
echo "test" | sudo tee -a /var/log/haproxy-k8s-api.log
sudo lsof /var/log/haproxy-k8s-api.log            # rsyslogd should be the process holding it open
sudo lsof +L1 2>/dev/null | grep haproxy          # should be EMPTY — +L1 finds files with 0 links
                                                    # (deleted-but-open); if haproxy shows up here,
                                                    # rsyslog never reopened and space isn't being freed
```

### Common failure modes

| Symptom | Likely cause |
|---|---|
| File never rotates at all | No cron/systemd timer running logrotate on this host — check first |
| File rotates but new writes still go to the renamed/old file | `postrotate` didn't run or the rsyslog signal failed — check `journalctl -u rsyslog` |
| `logrotate -f` errors about permissions | The `create` user/group (`syslog adm`) doesn't exist on this distro — use `root root` on RHEL-family systems (see comment in the file) |
| Disk usage doesn't drop after rotation despite rotated files being small | The gotcha above — an old file handle is still open; restarting the writing service (`systemctl restart rsyslog`) forces the release even if the HUP signal didn't take effect |

See the main document (`../multi_master_ha_setup.md`) for the full failover/DR
procedures once the cluster is live, and [`ETCD_BACKUP.md`](ETCD_BACKUP.md) for the
etcd snapshot backup/rotation setup.

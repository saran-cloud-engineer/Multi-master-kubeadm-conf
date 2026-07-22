# HAProxy + kube-apiserver Port 6443 Conflict — Fix

## The problem

HAProxy's `frontend kubernetes-api` binds `*:6443` (all interfaces) on each master —
it needs to, to receive incoming API traffic. `kubeadm init`/`join` also wants
kube-apiserver to bind `0.0.0.0:6443` on that same machine. Two processes can't hold
overlapping addresses on the same port — whichever started first wins, and the other
fails with `[ERROR Port-6443]: Port 6443 is in use`.

**Correction to an earlier suggestion, worth knowing about:** the first fix attempt for
this used a kubeadm `ClusterConfiguration` with `apiServer.extraArgs.bind-address` set
to a specific IP. Don't do that — `ClusterConfiguration` is **shared across the whole
cluster**, not per-node. Hardcoding one master's IP there would make every *other*
master that joins later also try to bind that same (wrong, not-theirs) IP, breaking
them instead of fixing anything. The approach below avoids that entirely.

## The actual fix — restrict both sides to their own specific address

Two prerequisites (do these once, same on all 3 masters, if not already done):

```bash
# 1. Let HAProxy bind an address it doesn't always physically own (needed since the
#    VIP only lives on whichever node currently holds MASTER state)
echo "net.ipv4.ip_nonlocal_bind = 1" | sudo tee -a /etc/sysctl.d/99-hims-k8s.conf
sudo sysctl --system

# 2. Make HAProxy bind only the VIP, not every address
sudo sed -i 's/bind \*:6443/bind 10.200.50.143:6443/' /etc/haproxy/haproxy.cfg
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
```

Then, per-master, at the moment that specific master runs `init`/`join` — stop HAProxy
just long enough for kube-apiserver's first startup, then restrict it afterward:

### On MN-01 (first master — `kubeadm init`)

```bash
# Free up 6443 entirely for kube-apiserver's first startup
sudo systemctl stop haproxy

# Plain kubeadm init — no special config file needed with this approach
sudo kubeadm init \
  --control-plane-endpoint "10.200.50.143:6443" \
  --upload-certs \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=10.200.50.129
```

Once `init` completes successfully, kube-apiserver is running as a static pod, still
bound to the default wildcard (`0.0.0.0:6443`). Restrict it to this node's own IP:

```bash
sudo sed -i '/- kube-apiserver/a\    - --bind-address=10.200.50.129' /etc/kubernetes/manifests/kube-apiserver.yaml
```

Kubelet watches `/etc/kubernetes/manifests/` and automatically restarts the static pod
once it detects the change — no manual restart command needed. **This can genuinely
take a minute or two, not just a few seconds** — kubelet has to notice the file change,
tear down the old container, start the new one, and wait for it to pass its startup
probe before it's considered healthy. Don't panic if `ss -tlnp | grep 6443` shows
**nothing at all** for a stretch during this window (confirmed in practice: it can sit
empty for over a minute) — that's the old container already gone and the new one not
listening yet, not a failure. Confirm it actually picked up the new flag and came back:

```bash
watch crictl ps   # wait for a fresh kube-apiserver container (new START TIME)
```

Only once you see a fresh container, bring HAProxy back:

```bash
sudo systemctl start haproxy
```

**Verify both are listening on their own specific address, no overlap:**

```bash
sudo ss -tlnp | grep 6443
```
Expect exactly this shape (real example from a working MN-01):
```
LISTEN 0 20000  10.200.50.143:6443  0.0.0.0:*  users:(("haproxy",...))
LISTEN 0 65535  10.200.50.129:6443  0.0.0.0:*  users:(("kube-apiserver",...))
```
**If you only see one of these two lines — most likely just HAProxy — don't treat that
as success.** It means kube-apiserver isn't actually running, and HAProxy only managed
to bind cleanly because nothing was competing for the port, not because the fix is
actually working. Go back to `crictl ps -a` / `crictl logs` / `journalctl -u kubelet` to
find out why kube-apiserver didn't come back, rather than assuming HAProxy starting
without an error means everything is fine.
Expect **two** lines — one for `10.200.50.129:6443` (kube-apiserver) and one for
`10.200.50.143:6443` (haproxy) — not `0.0.0.0:6443` for either.

Continue with the rest of `03-master-node-setup.md` Section 2 as normal (`mkdir -p
$HOME/.kube`, `cp admin.conf`, kubelet reserved-resources config, Calico install).

### On MN-02 / MN-03 later (`kubeadm join --control-plane`)

Identical pattern, using that node's own real IP both times:

```bash
sudo systemctl stop haproxy

sudo kubeadm join 10.200.50.143:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key> \
  --apiserver-advertise-address=10.200.50.130   # MN-03 uses its own IP instead

sudo sed -i '/- kube-apiserver/a\    - --bind-address=10.200.50.130' /etc/kubernetes/manifests/kube-apiserver.yaml
watch crictl ps

sudo systemctl start haproxy
sudo ss -tlnp | grep 6443
```

## How a request actually flows once both binds are in place

**Key concept: HAProxy in `mode tcp` terminates two separate TCP connections — it's not
a router rewriting packets in flight, it's a proxy relaying bytes between two live
connections it holds open itself.** One connection is client-to-HAProxy, on the VIP;
the other is HAProxy-to-backend, on that backend's real IP. They're independent
connections, not one forwarded packet stream.

Concrete trace — a worker's kubelet talking to the API server, with MN-01 currently
holding the VIP:

```
Worker's kubelet reads kubeconfig: server: https://10.200.50.143:6443
        |
        v
TCP SYN to 10.200.50.143:6443
        |
        v
Network delivers it to MN-01 — the only box currently announcing
10.200.50.143 (via keepalived's gratuitous ARP)
        |
        v
On MN-01: kernel sees destination 10.200.50.143:6443 — delivers it to
whatever's LISTENING on that specific address. That's HAProxy now
(kube-apiserver doesn't bind that address anymore, per the fix above).
        |
        v
HAProxy accepts this connection   [Connection #1: worker <-> HAProxy]
        |
        v
HAProxy picks a healthy backend from its list (round-robin) — say
it picks mn02: 10.200.50.130:6443
        |
        v
HAProxy opens a BRAND NEW, separate connection to 10.200.50.130:6443
— travels over the network to MN-02   [Connection #2: HAProxy <-> apiserver]
        |
        v
On MN-02: kernel sees destination 10.200.50.130:6443 — delivers it to
kube-apiserver on MN-02 (bound only to its own real IP, per the fix above)
        |
        v
kube-apiserver on MN-02 processes the request, responds through
Connection #2 back to HAProxy
        |
        v
HAProxy relays that response back through Connection #1 to the worker
```

**Why splitting the binds this way is what actually makes this work:**
- **Before the fix**: both HAProxy and kube-apiserver wanted the wildcard address on
  this box, meaning both were trying to claim *every* local address — including each
  other's intended one — hence the direct conflict.
- **After the fix**: HAProxy claims *only* the VIP (`10.200.50.143:6443`) — deliberately
  blind to the node's own real IP now. kube-apiserver claims *only* its own real IP
  (`10.200.50.129:6443` on MN-01) — deliberately blind to the VIP. Two distinct sockets,
  two distinct addresses, same port, zero overlap.

**Side effect worth knowing, and it's actually the whole point:** the request above
arrived at MN-01 but was answered by MN-02's apiserver — HAProxy isn't restricted to
routing only to the local apiserver. That's simultaneously load-balancing (spreading
requests across all 3 apiservers) and failover (if MN-01's own local apiserver were
unhealthy, HAProxy running right there on MN-01 would still correctly route to a
healthy backend elsewhere) from the same mechanism.

## Why this approach instead of a config file

- No shared cluster-wide value to accidentally break future joins — each node's
  manifest edit is local to that node only.
- No dependency on whether `kubeadm init --config` combines cleanly with
  `--upload-certs` (an open question with the config-file approach) — the plain CLI
  flags you already know work are used unchanged.
- Fully verifiable at each step (`ss -tlnp`, `crictl ps`) rather than trusting that a
  YAML file's `extraArgs` applied the way intended.

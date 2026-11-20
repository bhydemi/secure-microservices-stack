#!/usr/bin/env bash
# Alternative to starter/Vagrantfile for Apple Silicon hosts.
#
# VirtualBox has no Apple Silicon build at all -- it only virtualizes
# x86_64 guests -- so Vagrantfile's `virtualbox` provider and its
# `opensuse/Leap-15.6.x86_64` box can't run on an arm64 Mac, full stop.
# Lima gives the same openSUSE Leap 15.6 guest, but as a native aarch64 VM
# under Apple's Virtualization framework (no emulation, no VirtualBox).
# Everything downstream of this -- cluster.yml, docker_run_hardened.sh,
# setup_falco_grafana.sh -- is unaffected, since RKE and Falco only care
# that the node is a real Linux VM reachable over SSH with Docker on it.
set -euo pipefail

NODE_NAME="${1:-rke-node1}"

# --- 1. Install Lima -------------------------------------------------------
brew install lima

# --- 2. Boot a native arm64 openSUSE Leap 15.6 VM --------------------------
limactl start --name="$NODE_NAME" template:opensuse-leap-15 \
  --cpus=2 --memory=4 --tty=false

# --- 3. Install and enable Docker inside the VM (mirrors the Vagrantfile's
#        shell provisioner, just with openSUSE's actual package name set) --
limactl shell "$NODE_NAME" -- sudo zypper --non-interactive install -y \
  apparmor-parser docker
limactl shell "$NODE_NAME" -- sudo systemctl enable --now docker

# Add the Lima forwarding user to the docker group so RKE can run docker
# commands over SSH without needing passwordless sudo.
LIMA_USER="$(limactl shell "$NODE_NAME" -- whoami)"
limactl shell "$NODE_NAME" -- sudo usermod -aG docker "$LIMA_USER"
limactl shell "$NODE_NAME" -- sudo zypper --non-interactive install -y conntrack-tools

# --- 4. Install cri-dockerd ---------------------------------------------
# RKE's hyperkube entrypoint talks to Docker through a CRI shim at
# /var/run/cri-dockerd.sock -- openSUSE's `docker` package doesn't ship
# one, so without this kubelet crash-loops on every start.
CRI_DOCKERD_VERSION="0.4.10"
TMP_TGZ="$(mktemp -d)/cri-dockerd.tgz"
curl -sL "https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/cri-dockerd-${CRI_DOCKERD_VERSION}.arm64.tgz" -o "$TMP_TGZ"
limactl copy "$TMP_TGZ" "$NODE_NAME:/tmp/cri-dockerd.tgz"
limactl shell "$NODE_NAME" -- tar -xzf /tmp/cri-dockerd.tgz -C /tmp
limactl shell "$NODE_NAME" -- sudo install -m 0755 /tmp/cri-dockerd/cri-dockerd /usr/local/bin/cri-dockerd

CRI_DOCKERD_UNIT="$(mktemp)"
cat > "$CRI_DOCKERD_UNIT" <<'EOF'
[Unit]
Description=CRI Interface for Docker Application Container Engine
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
ExecStartPre=-/usr/bin/rm -f /var/run/cri-dockerd.sock
ExecStart=/usr/local/bin/cri-dockerd --pod-infra-container-image=rancher/pause:3.2
Restart=always
RestartSec=5
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
limactl copy "$CRI_DOCKERD_UNIT" "$NODE_NAME:/tmp/cri-dockerd.service"
limactl shell "$NODE_NAME" -- sudo install -m 0644 /tmp/cri-dockerd.service /etc/systemd/system/cri-dockerd.service
limactl shell "$NODE_NAME" -- sudo systemctl daemon-reload
limactl shell "$NODE_NAME" -- sudo systemctl enable --now cri-dockerd

# --- 5. Satisfy cluster.yml's `protect-kernel-defaults: true` kubelet flag -
# kubelet refuses to start under this flag unless these sysctls are
# already set on the node -- see cluster.yml's kubelet.extra_args.
SYSCTL_CONF="$(mktemp)"
cat > "$SYSCTL_CONF" <<'EOF'
kernel.panic_on_oops = 1
kernel.panic = 10
vm.overcommit_memory = 1
EOF
limactl copy "$SYSCTL_CONF" "$NODE_NAME:/tmp/99-kubelet-protect-kernel-defaults.conf"
limactl shell "$NODE_NAME" -- sudo install -m 0644 /tmp/99-kubelet-protect-kernel-defaults.conf /etc/sysctl.d/99-kubelet-protect-kernel-defaults.conf
limactl shell "$NODE_NAME" -- sudo sysctl --system

# --- 5.5. Fix same-node Service DNAT (br_netfilter) ------------------------
# openSUSE Leap's default image doesn't load br_netfilter, so bridged
# pod-to-pod traffic through flannel's cni0 bridge skips iptables NAT in
# one direction: a request to a ClusterIP backed by a pod on the SAME node
# gets DNATed correctly on the way in, but the reply never gets re-NATed
# back to the Service IP, so the client's kernel sees an unsolicited
# packet and drops it. On a single-node cluster this breaks every
# same-node Service call, including kube-dns -- pods can resolve a pod IP
# directly but every DNS query through the kube-dns Service IP (10.43.0.10)
# times out, which is exactly what made Falco's falcoctl-artifact-install
# init container (and the driver-loader before it) fail with "dial tcp:
# i/o timeout" despite the node itself having working DNS and internet
# access.
BR_NETFILTER_MODULE="$(mktemp)"
echo "br_netfilter" > "$BR_NETFILTER_MODULE"
BR_NETFILTER_SYSCTL="$(mktemp)"
cat > "$BR_NETFILTER_SYSCTL" <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
limactl copy "$BR_NETFILTER_MODULE" "$NODE_NAME:/tmp/99-br-netfilter.conf"
limactl copy "$BR_NETFILTER_SYSCTL" "$NODE_NAME:/tmp/99-bridge-nf-call-iptables.conf"
limactl shell "$NODE_NAME" -- sudo install -m 0644 /tmp/99-br-netfilter.conf /etc/modules-load.d/99-br-netfilter.conf
limactl shell "$NODE_NAME" -- sudo install -m 0644 /tmp/99-bridge-nf-call-iptables.conf /etc/sysctl.d/99-bridge-nf-call-iptables.conf
limactl shell "$NODE_NAME" -- sudo modprobe br_netfilter
limactl shell "$NODE_NAME" -- sudo sysctl --system

# --- 6. Print the connection details cluster.yml needs ---------------------
# Lima shares one SSH keypair (~/.lima/_config/user) across all instances,
# and forwards SSH on 127.0.0.1 at a port fixed for this instance's
# lifetime -- shown by `limactl list`. Re-run this if the VM is recreated;
# the port can change.
echo
echo "cluster.yml node block for $NODE_NAME:"
echo "  address/port: 127.0.0.1 / Lima's forwarded SSH port (see below)"
echo "  internal_address: the node's real interface IP, e.g. \`ip -4 -o addr show\` inside the VM"
limactl list "$NODE_NAME"
echo "user: $LIMA_USER"
echo "ssh_key_path: $HOME/.lima/_config/user"

# --- 7. Bring the cluster up ------------------------------------------------
# openSUSE Leap 15.6's zypper repo ships a Docker release (28.5.x) newer
# than this RKE build's hardcoded supported-version list, which is fatal
# by default; cluster.yml's `ignore_docker_version: true` alone isn't
# enough in this RKE version, so pass the matching CLI flag too:
#   rke up --config cluster.yml --ignore-docker-version

# --- 8. Step 5 prerequisite: QEMU emulation for payload.sh's images --------
# Only needed for the incident-response exercise, not for the cluster
# itself. starter/scripts/payload.sh's demo cryptominer images are all
# linux/amd64-only -- without emulation registered, they fail outright
# with "exec format error" on this arm64 node. One-time, persists across
# container restarts (registers a binfmt_misc handler on the host kernel):
#   limactl shell "$NODE_NAME" -- sudo docker run --rm --privileged tonistiigi/binfmt --install all

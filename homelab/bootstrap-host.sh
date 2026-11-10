#!/usr/bin/env bash
# One-time host bootstrap for the homelab mini PC (Debian 13, after the
# preseeded install). Run it on the box itself, from a clone of this repo:
#
#   git clone -b homelab https://github.com/teodorio95-portofolio/secure-k8s-lab.git
#   sudo ./secure-k8s-lab/homelab/bootstrap-host.sh
#
# It joins the tailnet (with Tailscale SSH), installs k3s with Cilium-ready
# flags and leaves a kubeconfig for the Mac. Everything cluster-side (Cilium,
# ArgoCD, the apps) is then done from the Mac with `make homelab-up`.
# Safe to re-run.
set -euo pipefail

# Same Kubernetes minor as the k3d lab (cluster/k3d-config.yaml) so every pin
# in the repo stays valid. Override to upgrade: K3S_VERSION=v1.xx.y+k3s1.
K3S_VERSION="${K3S_VERSION:-v1.30.4+k3s1}"
TS_HOSTNAME="${TS_HOSTNAME:-homelab}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_USER="${SUDO_USER:-teodorio95}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

echo "==> Kernel limits for many watchers (ArgoCD, Cilium, Falco)"
cat >/etc/sysctl.d/90-homelab.conf <<'EOF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
EOF
sysctl --quiet --system

echo "==> Automatic security updates"
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "==> Docker (only to build the local AI images on this amd64 box)"
apt-get update -q
apt-get install -y --no-install-recommends docker.io

echo "==> Tailscale"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
# Prints a login URL the first time: open it on the Mac/iPhone to approve.
tailscale up --ssh --hostname "$TS_HOSTNAME"

echo "==> k3s $K3S_VERSION"
cfg=/etc/rancher/k3s/config.yaml
old_cfg_sum="$(sha256sum "$cfg" 2>/dev/null || true)"
install -D -m 0600 "$HERE/k3s-config.yaml" "$cfg"
if ! command -v k3s >/dev/null || [[ "$(k3s --version | head -1)" != *"$K3S_VERSION"* ]]; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
elif [[ "$(sha256sum "$cfg")" != "$old_cfg_sum" ]]; then
  echo "    config changed -> restarting k3s"
  systemctl restart k3s
fi

echo "==> kubeconfig for the Mac (~$TARGET_USER/.kube/homelab.yaml)"
install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.kube"
sed "s#https://127.0.0.1:6443#https://$TS_HOSTNAME:6443#" /etc/rancher/k3s/k3s.yaml \
  >"$TARGET_HOME/.kube/homelab.yaml"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.kube/homelab.yaml"
chmod 0600 "$TARGET_HOME/.kube/homelab.yaml"

echo "==> iGPU render node usable by non-root pods"
# Pods only see /dev/dri when the device plugin hands it to them (device
# cgroup), but the node itself is root:render 0660 and the render gid is
# picked at install time. 0666 on the render node (not the card/KMS node)
# lets non-root containers (Ollama runs as 65532) use it without baking the
# host's render gid into every chart. Render nodes cannot modeset.
cat >/etc/udev/rules.d/70-homelab-render-node.rules <<'EOF'
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=drm --action=change
ls -l /dev/dri/ 2>/dev/null || echo "    /dev/dri missing (check firmware-amd-graphics / reboot)"

echo "==> iGPU check (Vulkan)"
vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' || \
  echo "    vulkaninfo found no GPU yet (check firmware-amd-graphics / reboot)"

cat <<EOF

Host ready. The node is NotReady until Cilium is installed — expected.
Next, on the Mac (in secure-k8s-lab, branch homelab):
  make homelab-kubeconfig
  make homelab-up
EOF

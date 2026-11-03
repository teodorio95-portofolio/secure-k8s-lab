# Homelab: the lab on a real mini PC

The same GitOps tree as the k3d lab, running 24/7 on bare metal instead of
Docker on a laptop: Debian 13 + k3s on a **GMKtec NucBox M6 Ultra**
(Ryzen 5 7640HS, 32 GB DDR5, 1 TB NVMe, 2× 2.5 GbE), headless, managed from
the Mac over **Tailscale**.

| | k3d lab (`make up`) | homelab (`make homelab-up`) |
|---|---|---|
| Cluster | k3d in Docker, 1 server + 1 agent | k3s on Debian 13, single node |
| Bootstrap | [cluster/k3d-config.yaml](../cluster/k3d-config.yaml) | [k3s-config.yaml](k3s-config.yaml) + [bootstrap-host.sh](bootstrap-host.sh) |
| Root app | [root-app.yaml](../bootstrap/argocd/root-app.yaml) | [root-app-homelab.yaml](../bootstrap/argocd/root-app-homelab.yaml) |
| secure-ai-gateway | `gitops/` | `gitops/` + `gitops-homelab/` overrides (bigger model) |
| Access | localhost | `kubectl` / `ssh` over the tailnet only |

Same CNI (Cilium, flannel and the k3s netpol controller off), same Kyverno
guardrails, same default-deny namespaces. **ServiceLB and Traefik are
disabled**, so nothing (including the intentionally vulnerable Juice Shop) is
published on the home LAN, not even through a NodePort; everything is reached
with `kubectl port-forward` through Tailscale (`make juice-ui`, not :8081).

## 1. Installer USB (on the Mac)

1. Download the Debian 13 netinst ISO:
   <https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/>
   (`debian-13.x.y-amd64-netinst.iso`) and check it against `SHA256SUMS` there:

   ```bash
   shasum -a 256 ~/Downloads/debian-13.*-amd64-netinst.iso
   ```

2. Write it to the stick with [balenaEtcher](https://etcher.balena.io/)
   (Flash from file → the stick → Flash). This erases the stick.

## 2. BIOS (first boot, monitor + keyboard once)

`Del` at power-on opens the BIOS, `F7` the boot menu.

| Setting | Value | Why |
|---|---|---|
| Power mode | Quiet (35 W) | quieter fan, ~same performance in reviews |
| Restore on AC power loss | Power On | comes back after a power cut |
| Wake-on-LAN | Enabled | can be woken remotely |
| UMA frame buffer | 8 GB | VRAM for Qwen 3.5 9B on the iGPU (Vulkan, ~6 GB weights + KV cache); the host keeps 24 GB |
| Secure Boot | leave on | Debian's shim is signed |

## 3. Unattended Debian install

Boot the stick (`F7`, its **UEFI** entry) → **Advanced options → Automated install**. When asked
for the preseed location, enter:

```text
https://raw.githubusercontent.com/teodorio95-portofolio/secure-k8s-lab/homelab/homelab/preseed.cfg
```

[preseed.cfg](preseed.cfg) wipes the internal NVMe (factory Windows included),
installs SSH + standard tools only, no swap, the iGPU firmware and Vulkan
drivers. It only asks for the `teodorio` password. Remove the stick when it
reboots.

## 4. Host bootstrap (still at the console)

```bash
git clone -b homelab https://github.com/teodorio95-portofolio/secure-k8s-lab.git
sudo ./secure-k8s-lab/homelab/bootstrap-host.sh
```

It prints a Tailscale login URL: approve it from the Mac or iPhone. After that
the monitor and keyboard can go; everything else is remote.

## 5. Cluster bootstrap (from the Mac)

```bash
ssh teodorio@homelab            # Tailscale SSH, no keys to manage
make homelab-kubeconfig         # -> ~/.kube/homelab.yaml (server: https://homelab:6443)
make homelab-up                 # Cilium + ArgoCD + root-app-homelab
export KUBECONFIG=~/.kube/homelab.yaml
make argocd-pass argocd-ui      # every existing target works with that KUBECONFIG
```

Then in `secure-ai-gateway` (branch `homelab`): `make sealing-key-install`
and `make homelab-images`. See its README.

## Notes and next steps

- **Kubernetes version** is pinned to the lab's (`v1.30.4+k3s1`) so every chart
  and schema pin keeps matching; bump `K3S_VERSION` in `bootstrap-host.sh`
  together with `cluster/k3d-config.yaml`.
- **iGPU for models**: `apps/homelab/gpu-device-plugin.yaml` runs
  generic-device-plugin 0.2.0 (`homelab/gpu-device-plugin/`), which advertises
  the render node as `squat.ai/dri` (shareable by 4 pods). Ollama in
  `ai-models` requests it and runs Qwen 3.5 9B through Vulkan (Mesa RADV), with
  PSA `restricted` intact: no `hostPath`, no privileges. `bootstrap-host.sh`
  makes the render node 0666 so non-root pods can open it. Check after sync:

  ```bash
  kubectl get node homelab -o jsonpath='{.status.allocatable.squat\.ai/dri}'   # 4
  kubectl -n ai-models logs deploy/ollama | grep -iE 'vulkan|offload|inference compute'
  ```

  If the logs show `library=cpu`, the model runs on the CPU (still works,
  slower): check the BIOS UMA size and `vulkaninfo --summary` on the host.
- **UPS**: add `nut-client` and point it at the UPS over USB once it's bought.

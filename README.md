# secure-k8s-lab

> Foundation of a DevSecOps portfolio: a reproducible Kubernetes lab, managed with GitOps (ArgoCD), where an intentionally vulnerable target (OWASP Juice Shop) is **deployed and locked down** — so it can be attacked and defended in a fully isolated environment.

This is project **#1** of a 5-part DevSecOps portfolio. It builds the platform everything else stands on:

| # | Project | Role |
|---|---------|------|
| **1** | **secure-k8s-lab** *(this repo)* | Reproducible cluster + GitOps + isolated vulnerable target |
| 2 | devsecops-pipeline | Scanning in CI (SAST/DAST/deps/IaC) |
| 3 | supply-chain-security | Image signing, SBOM, admission control |
| 4 | offensive-writeups | Documented attacks against this lab |
| 5 | runtime-security | Falco + Cilium detecting those attacks |

## The story this repo tells

> "I don't just run a vulnerable app. I run it on a GitOps-managed cluster, isolated with a default-deny network posture, where every change is declarative and auditable. I can attack it — and I built the cage around it."

## Architecture

```mermaid
flowchart LR
    subgraph attacker["Kali (Parallels VM)"]
        K[nmap / Burp / sqlmap]
    end
    subgraph cluster["k3d cluster: secure-lab"]
        subgraph argocd["argocd ns"]
            A[ArgoCD<br/>app-of-apps]
        end
        subgraph juice["juice-shop ns — default-deny"]
            J[Juice Shop :3000]
        end
        A -. GitOps sync .-> J
    end
    K -->|"only :3000 allowed"| J
    J --x|"egress blocked except DNS"| internal[(rest of cluster)]
```

**Defensive posture baked in:**
- `default-deny` ingress **and** egress in the `juice-shop` namespace
- Only port `3000` ingress is allowed (the app), nothing else
- Egress allowed **only** to cluster DNS — the target cannot pivot to the rest of the cluster
- **Kyverno** admission control enforces guardrails cluster-wide (no `:latest`, non-root, resource limits) and auto-generates a default-deny policy in new namespaces
- Everything is declarative and synced by ArgoCD (app-of-apps pattern)

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [k3d](https://k3d.io/) (`brew install k3d`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/) — used to render/inspect the Juice Shop chart (`make` deploys via ArgoCD)

## Quick start

```bash
make up            # create cluster + install ArgoCD + sync the lab
make argocd-pass   # print the ArgoCD admin password
make argocd-ui     # port-forward the ArgoCD UI -> https://localhost:8080
make juice-ui      # port-forward Juice Shop   -> http://localhost:3000
make verify-netpol # prove egress is blocked / DNS allowed (the isolation)
make kyverno-reports # show what the Kyverno guardrails flagged (Audit mode)
make hubble-ui     # network flows / L7 (Cilium) -> http://localhost:12000
make falco-events  # tail runtime-detection alerts (project #5)
make down          # tear everything down
```

### Running it on a real box

The same tree also runs 24/7 on a headless mini PC (Debian 13 + k3s, managed
over Tailscale): `make homelab-up`. Install and bootstrap runbook:
[homelab/README.md](homelab/README.md).

### Accessing the apps

- **Juice Shop** is exposed through the cluster's **Traefik ingress** (the k3d
  loadbalancer container), so it's reachable persistently at
  **<http://localhost:8081>** — no terminal/port-forward needed. `make juice-ui`
  is just an ad-hoc alternative on `:3000`.
- **ArgoCD UI** uses `make argocd-ui` (port-forward, terminal-bound) at
  <https://localhost:8080> — self-signed cert, so accept the browser warning.
  User `admin`, password from `make argocd-pass`.

## How NetworkPolicies are actually enforced

The CNI is **Cilium** (flannel + the k3s netpol controller are disabled in
`cluster/k3d-config.yaml`; `make up` bootstraps Cilium before ArgoCD). So the
`default-deny` policies in [chart/templates/networkpolicy.yaml](chart/templates/networkpolicy.yaml)
are **enforced for real**, and we also get **Hubble** network observability and
L7-aware policies. The runtime-detection layer (Falco + Cilium L7) is project #5,
[runtime-security](../runtime-security), pulled into this cluster via ArgoCD.

## Two layers of policy: chart vs Kyverno

- The **Helm chart** ships the workload's *own* NetworkPolicies + pod security —
  the app carries its cage with it.
- **Kyverno** ([policies/kyverno/](policies/kyverno/)) enforces guardrails
  *cluster-wide* at admission time (no `:latest`, non-root, resource limits),
  mutates missing security contexts, and generates a default-deny policy in any
  new namespace. Started in **Audit** mode — see [docs/architecture.md](docs/architecture.md).

## Repository layout

```
secure-k8s-lab/
├── Makefile                     # lifecycle: up / down / ui / password
├── cluster/
│   └── k3d-config.yaml          # declarative cluster definition
├── homelab/                     # same lab on a bare-metal mini PC (Debian 13 + k3s)
│   ├── README.md                # install + bootstrap runbook
│   ├── preseed.cfg              # unattended Debian install
│   ├── k3s-config.yaml          # k3s flags (Cilium-ready, no ServiceLB)
│   └── bootstrap-host.sh        # Tailscale + k3s + kubeconfig for the Mac
├── bootstrap/
│   └── argocd/
│       ├── root-app.yaml        # app-of-apps entry point
│       └── root-app-homelab.yaml# homelab entry point (adds apps/homelab/)
├── apps/
│   ├── argocd-apps/
│   │   ├── juice-shop.yaml      # ArgoCD Application -> renders chart/
│   │   ├── kyverno.yaml         # ArgoCD Application -> upstream Kyverno chart
│   │   └── kyverno-policies.yaml# ArgoCD Application -> policies/kyverno
│   └── homelab/                 # homelab-only Application variants
├── policies/
│   └── kyverno/                 # guardrails: validate / mutate / generate
│       ├── 01-disallow-latest-tag.yaml
│       ├── 02-require-non-root.yaml
│       ├── 03-require-resource-limits.yaml
│       ├── 04-mutate-default-securitycontext.yaml
│       └── 05-generate-default-deny-netpol.yaml
├── chart/                       # our own Helm chart (app + security controls)
│   ├── Chart.yaml
│   ├── values.yaml              # secure defaults (networkPolicy.enabled: true)
│   ├── values-insecure.yaml     # "before" overlay (networkPolicy.enabled: false)
│   └── templates/
│       ├── _helpers.tpl
│       ├── namespace.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml          # Traefik ingress -> http://localhost:8081
│       └── networkpolicy.yaml
├── .pre-commit-config.yaml      # local quality gates (gitleaks, helm lint, hygiene)
├── .markdownlint.yaml
├── .vscode/                     # recommended extensions + format-on-save
└── docs/
    └── architecture.md
```

### Insecure / secure demo

The whole defensive posture is a single value flip — ideal for a before/after:

```bash
helm template juice-shop chart                              # secure: 3 NetworkPolicies
helm template juice-shop chart -f chart/values-insecure.yaml # before: 0 NetworkPolicies
```

## ⚠️ Legal / safety note

OWASP Juice Shop is **intentionally vulnerable** and is meant to be attacked.
Run it **only** inside this isolated lab. Never expose it to the public internet,
and only ever scan/attack targets you own or platforms explicitly built for it
(TryHackMe, Hack The Box, PortSwigger Web Security Academy).

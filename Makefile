CLUSTER       := secure-lab
ARGOCD_VER    := v3.4.4
ARGOCD_NS     := argocd
CILIUM_VER    := 1.19.5
# Upstream DNS for CoreDNS = whatever Docker containers get (192.168.5.1 on
# Colima). Without it k3s falls back to 8.8.8.8, because the node's resolv.conf
# is Docker's 127.0.0.11 — which breaks on networks that block public DNS.
# Lives outside the repo; k3d bind-mounts it into every node.
K3S_RESOLV    := $(HOME)/.config/secure-k8s-lab/k3s-resolv.conf

.PHONY: help up down cilium argocd argocd-pass argocd-ui juice-ui root-app verify-netpol cilium-status hubble-ui falco-events

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

up: ## Create cluster, bootstrap Cilium, install ArgoCD, deploy the lab
	@mkdir -p $(dir $(K3S_RESOLV))
	docker run --rm busybox:1.38.0 cat /etc/resolv.conf | grep '^nameserver' > $(K3S_RESOLV)
	k3d cluster create --config cluster/k3d-config.yaml \
		--volume "$(K3S_RESOLV):/etc/k3s-resolv.conf@server:*;agent:*"
	$(MAKE) cilium
	$(MAKE) argocd
	@echo "==> Waiting for ArgoCD to be ready..."
	kubectl -n $(ARGOCD_NS) rollout status deploy/argocd-server --timeout=180s
	$(MAKE) root-app
	@echo ""
	@echo "Lab is up. Next:"
	@echo "  make argocd-pass   # admin password"
	@echo "  make argocd-ui     # https://localhost:8080"
	@echo "  make hubble-ui     # http://localhost:12000 (network flows)"
	@echo "  make falco-events  # tail runtime-detection alerts"

cilium: ## Bootstrap Cilium as the CNI (must precede ArgoCD — CNI chicken-and-egg)
	helm repo add cilium https://helm.cilium.io >/dev/null
	helm repo update >/dev/null
	helm upgrade --install cilium cilium/cilium --version $(CILIUM_VER) \
		--namespace kube-system -f cilium/values.yaml
	@echo "==> Waiting for Cilium (nodes become Ready once the CNI is up)..."
	kubectl -n kube-system rollout status ds/cilium --timeout=240s

argocd: ## Install ArgoCD into the cluster
	kubectl create namespace $(ARGOCD_NS) --dry-run=client -o yaml | kubectl apply -f -
	# Server-side apply: ArgoCD's ApplicationSet CRD is too large for the
	# client-side last-applied annotation (kubectl apply would fail).
	kubectl apply --server-side --force-conflicts -n $(ARGOCD_NS) \
		-f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VER)/manifests/install.yaml

root-app: ## Apply the app-of-apps (after pushing repo + editing repoURL)
	kubectl apply -f bootstrap/argocd/root-app.yaml

argocd-pass: ## Print the ArgoCD admin password
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d && echo

argocd-ui: ## Port-forward the ArgoCD UI to https://localhost:8080
	kubectl -n $(ARGOCD_NS) port-forward svc/argocd-server 8080:443

juice-ui: ## Port-forward Juice Shop to http://localhost:3000
	kubectl -n juice-shop port-forward svc/juice-shop 3000:3000

cilium-status: ## Show Cilium agent status
	kubectl -n kube-system exec ds/cilium -- cilium status

hubble-ui: ## Port-forward the Hubble UI to http://localhost:12000 (network flows)
	kubectl -n kube-system port-forward svc/hubble-ui 12000:80

falco-events: ## Tail Falco runtime-detection alerts (deployed via the #5 repo)
	kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco -f

kyverno-reports: ## Show Kyverno policy reports (what Audit mode flagged)
	kubectl get clusterpolicy
	@echo ""
	kubectl get policyreport -A 2>/dev/null || echo "(no reports yet — give the background controller a minute)"

verify-netpol: ## Prove egress is locked down (should FAIL to reach the internet)
	@echo "==> Spinning up a labelled debug pod to test external egress (expected: BLOCKED)"
	@# The juice-shop image is distroless (no shell), so we use a labelled busybox
	@# pod that inherits the same NetworkPolicies (podSelector app=juice-shop).
	@kubectl -n juice-shop delete pod netcheck --ignore-not-found >/dev/null 2>&1
	@kubectl -n juice-shop run netcheck --image=busybox:1.36 --labels=app=juice-shop \
		--restart=Never --command -- sleep 60 >/dev/null
	@kubectl -n juice-shop wait --for=condition=Ready pod/netcheck --timeout=60s >/dev/null
	@printf "external egress (1.1.1.1:443): "
	@kubectl -n juice-shop exec netcheck -- sh -c \
		'nc -w 4 -z 1.1.1.1 443 && echo "REACHABLE — netpol NOT enforced" || echo "BLOCKED — egress denied (expected)"'
	@printf "cluster DNS (allowed): "
	@kubectl -n juice-shop exec netcheck -- sh -c \
		'nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo "RESOLVES (expected)" || echo "FAILED"'
	@kubectl -n juice-shop delete pod netcheck --wait=false >/dev/null

down: ## Delete the cluster
	k3d cluster delete $(CLUSTER)

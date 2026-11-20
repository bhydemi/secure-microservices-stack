#!/usr/bin/env bash
# Step 4 runbook: Falco run-time monitoring + Prometheus/Grafana visualization.
#
# This needs a real, running RKE cluster (see starter/Vagrantfile and
# starter/cluster.yml) -- it is not something that can be faked. Run each
# section from the controlplane node (or anywhere with kubectl pointed at
# the cluster via kube_config_cluster.yml), in order, and take the
# screenshots called out below as you go.
set -euo pipefail

# --- 0. Kernel headers for the Falco kernel-module driver -----------------
# Falco's driver-loader downloads a prebuilt kernel module/eBPF probe for
# your exact kernel version when one exists; if not, it falls back to
# building one on the node with DKMS, which needs matching kernel headers
# installed. On openSUSE Leap the package is kernel-default-devel, and the
# installed version must exactly match `uname -r` (minus the "-default"
# suffix). Run this on the node itself, not via kubectl:
#   sudo zypper install -y "kernel-default-devel=$(uname -r | sed 's/-default$//')"
# If no prebuilt driver exists for this exact kernel and the DKMS build
# still fails, driver.kind=modern_ebpf (CO-RE eBPF, needs Linux 5.8+, no
# headers required at all) is the documented fallback -- swap the --set
# below to `--set driver.kind=modern_ebpf` if the kmod build is a blocker.

# --- 1. Helm + repos --------------------------------------------------------
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace falco --dry-run=client -o yaml | kubectl apply -f -

# --- 2. Falco itself (kernel-module driver, matching the SUSE kernel headers above) ---
helm install falco falcosecurity/falco \
  --namespace falco \
  --set driver.kind=kmod \
  --set tty=true

# --- 3. falco-exporter (Prometheus metrics for Falco's output events) -----
helm install falco-exporter falcosecurity/falco-exporter \
  --namespace falco

# Screenshot checkpoint #1 (kube_pods_screenshot.png): both of these
# should show Running, 1/1 or 2/2 Ready:
#   kubectl get pods -n falco

# --- 4. Generate a real Falco event by reading a sensitive file -----------
# Falco's default ruleset flags reads of files like /etc/shadow from
# inside a container. Exec into any running pod in the cluster (e.g. the
# sqli app pod) and trigger it:
#   kubectl exec -it <any-pod-name> -- cat /etc/shadow
# Then check Falco's own logs for the warning:
#   kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=50
# Screenshot checkpoint #2 (falco_alert_screenshot.png): the warning line
# from that log (or the corresponding counter on the falco-exporter
# /metrics page -- `kubectl port-forward -n falco svc/falco-exporter 9376:9376`
# then open http://localhost:9376/metrics and look for falco_events_total).

# --- 5. Prometheus Operator + Grafana ---------------------------------------
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace

# ServiceMonitor so Prometheus actually scrapes falco-exporter's /metrics.
# Its `release: kube-prometheus-stack` label has to match the Helm release
# name above -- that's what the kube-prometheus-stack chart's Prometheus CR
# looks for by default.
kubectl apply -f "$(dirname "$0")/falco_service_monitor.yaml"

# --- 6. Get into Grafana and import the Falco dashboard --------------------
# kube-prometheus-stack's default admin password (unless you overrode it):
#   kubectl get secret -n monitoring kube-prometheus-stack-grafana \
#     -o jsonpath="{.data.admin-password}" | base64 -d
# Port-forward to reach the UI:
#   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Then in Grafana (http://localhost:3000): Dashboards -> New -> Import,
# and import dashboard ID 11914 ("Falco Dashboard" -- the one the
# falco-exporter project itself links to: https://grafana.com/grafana/dashboards/11914),
# pointing it at the Prometheus datasource kube-prometheus-stack created.
# Screenshot checkpoint #3 (falco_grafana_screenshot.png): the dashboard
# panel showing the sensitive-file-read event from step 4. If nothing
# shows up, repeat step 4 (the event needs to happen after the
# ServiceMonitor/dashboard are wired up to be visible) and check
# `kubectl get servicemonitor -n falco` exists and
# `kubectl get prometheus -n monitoring -o yaml | grep -A3 serviceMonitorSelector`
# to confirm the release label actually matches.

# --- 7. Optional standout: custom rule -------------------------------------
# starter/falco_rules.local.yaml has a custom rule as a starting point
# (flags outbound connections to common cryptocurrency-mining pool ports --
# directly relevant to the crypto-miner payload used in the incident
# response step). Load it into the Falco chart with:
#   helm upgrade falco falcosecurity/falco -n falco \
#     --set driver.kind=kmod --set tty=true \
#     --set-file customRules."rules\.local\.yaml"="$(dirname "$0")/falco_rules.local.yaml"
# Screenshot checkpoint #4 (falco_custom_rule.png): the rule definition
# (e.g. `kubectl exec -n falco <falco-pod> -- cat /etc/falco/rules.d/rules.local.yaml`),
# and checkpoint #5 (grafana_custom_rule.png) after triggering it and
# seeing it show up in Grafana.

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

# --- 2. Falco itself ---------------------------------------------------
# driver.kind=kmod (DKMS-built kernel module, matching the SUSE kernel
# headers above) is the chart default and what this started with, but on
# this Lima/openSUSE node the DKMS build fails outright: the kernel was
# built with SUSE's gcc 7.5.0, while every gcc in the falco-driver-loader
# image (7/11/12) passes a -fmin-function-alignment flag that kernel's
# build scripts need but none of those gccs recognize -- a toolchain
# mismatch baked into the image, not something a flag or retry fixes. The
# documented fallback, modern_ebpf (CO-RE eBPF, no headers or compilation
# at all, needs Linux 5.8+ -- this node runs 6.4), works instead.
helm install falco falcosecurity/falco \
  --namespace falco \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set metrics.enabled=true \
  --set falco.webserver.prometheus_metrics_enabled=true

# --- 3. Prometheus metrics for Falco's events ------------------------------
# The original plan here was falcosecurity/falco-exporter, a separate
# sidecar that pulls events off Falco's gRPC output socket. It doesn't
# work with this Falco release (0.45.2 at chart version 9.2.2): the
# falco-exporter chart's own install notes say so outright --
# "Starting from Falco version 0.38, Falco can expose Prometheus metrics
# directly, eliminating the need for a separate exporter" -- and
# accordingly this chart version's values.yaml has no grpc/grpc_output
# section left to even turn on, so falco-exporter's gRPC client just sits
# there waiting forever and the pod never goes Ready.
# `metrics.enabled=true` + `falco.webserver.prometheus_metrics_enabled=true`
# above is that replacement: Falco exposes its own /metrics endpoint
# (Prometheus format, plain HTTP, no auth) on a chart-created
# `falco-metrics` Service, port 8765 -- see the updated
# starter/falco_service_monitor.yaml, which now targets that Service
# instead of falco-exporter's.

# Screenshot checkpoint #1 (kube_pods_screenshot.png):
#   kubectl get pods -n falco
# should show falco Running, 2/2 Ready.

# --- 4. Generate a real Falco event by reading a sensitive file -----------
# Falco's default ruleset flags reads of files like /etc/shadow from
# inside a container. Exec into any running pod in the cluster (e.g. the
# sqli app pod) and trigger it:
#   kubectl exec -it <any-pod-name> -- cat /etc/shadow
# Then check Falco's own logs for the warning:
#   kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=50
# Screenshot checkpoint #2 (falco_alert_screenshot.png): the warning line
# from that log (or the corresponding counter on Falco's own /metrics page --
# `kubectl port-forward -n falco svc/falco-metrics 8765:8765` then open
# http://localhost:8765/metrics and look for falcosecurity_falco_rules_matches_total).

# --- 5. Prometheus Operator + Grafana ---------------------------------------
# Chart version pinned to 39.13.3 (Prometheus Operator 0.58.0, mid-2022):
# the current chart's CRDs use CEL x-kubernetes-validations schema rules,
# the same Kubernetes-1.25+-only feature that forced canal -> flannel above,
# and this cluster is pinned to 1.20.4. --server-side=false works around a
# separate issue: Helm 4 defaults to server-side apply, and this apiserver's
# typed-patch support can't compute a merge key for a couple of the chart's
# Service manifests that omit an explicit `protocol: TCP` -- plain
# client-side apply doesn't hit that.
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 39.13.3 \
  --namespace monitoring --create-namespace \
  --server-side=false

# ServiceMonitor so Prometheus actually scrapes Falco's /metrics (the
# falco-metrics Service, not a separate falco-exporter -- see the README's
# "Bringing Step 4 up" section). Its `release: kube-prometheus-stack` label
# has to match the Helm release name above -- that's what the
# kube-prometheus-stack chart's Prometheus CR looks for by default.
kubectl apply -f "$(dirname "$0")/falco_service_monitor.yaml"

# --- 6. Get into Grafana and import the Falco dashboard --------------------
# kube-prometheus-stack's default admin password (unless you overrode it):
#   kubectl get secret -n monitoring kube-prometheus-stack-grafana \
#     -o jsonpath="{.data.admin-password}" | base64 -d
# Port-forward to reach the UI:
#   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# Then in Grafana (http://localhost:3000): Dashboards -> New -> Import,
# and import dashboard ID 11914 ("Falco Dashboard":
# https://grafana.com/grafana/dashboards/11914), pointing it at the
# Prometheus datasource kube-prometheus-stack created. Its two panels
# ("Events rate", "Totals") are written against falco-exporter's old
# falco_events/falco_events_total metrics, which no longer exist (see
# "Bringing Step 4 up" in the README) -- after importing, edit each
# panel's query to:
#   Events rate: sum(rate(falcosecurity_falco_rules_matches_total[5m])) by (rule_name)
#   Totals:      sum(falcosecurity_falco_rules_matches_total) by (rule_name)
# or the dashboard imports fine but shows no data at all.
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

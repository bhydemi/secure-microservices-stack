# Secure Microservices Stack

By Abdulhakeem Omotolani Yaqoob

Threat modeling, hardening, and run-time monitoring of a small microservices
stack: an OpenSUSE Docker host, a Rancher RKE Kubernetes cluster, and an
intentionally vulnerable Flask web application. The stack is hardened against
CIS benchmark findings, scanned for vulnerable dependencies, monitored at
run-time with Falco and Grafana, and tested end-to-end against a simulated
crypto-mining incident, which is then written up as a formal incident
response report.

## Project phases

1. **Threat model** the Docker host, RKE cluster, and Flask application using
   STRIDE — `starter/threat_modeling/`, `submissions/security_architecture_design.png`.
2. **Harden the Docker host** with Docker-bench against the CIS Docker
   Benchmark, and **harden the RKE cluster** with Kube-bench against the CIS
   Kubernetes Benchmark — `starter/Dockerfile`, `starter/Vagrantfile`,
   `starter/cluster.yml`.
3. **Harden the Flask app** (`vuln_app/`) by fixing XSS and other application
   security flaws, and scan its dependencies with Grype.
4. **Run-time monitoring**: deploy Falco (with OpenSUSE-specific kernel
   headers/drivers) and visualize its security events in Grafana.
5. **Incident response**: trigger a simulated crypto-mining payload
   (`starter/scripts/payload.sh`), detect it via Falco/Grafana, contain and
   remediate it, and write up the incident.

## Repository layout

- `starter/` — environment definitions: `Dockerfile` (OpenSUSE base image),
  `Vagrantfile` (local VM), `cluster.yml` / `reference_hardened_cluster.yml`
  (RKE cluster config), `docs/` (CIS/Rancher benchmark PDFs — kept locally
  only, not committed; see `.gitignore`), `incident_response/`,
  `threat_modeling/`, `security_architecture/`, and `scripts/payload.sh`.
- `vuln_app/` — the intentionally vulnerable Flask application (DVPWA) that
  gets hardened and deployed as part of this project.
- `submissions/` — all graded deliverables for this project: diagrams,
  before/after benchmark screenshots, the hardened `app.py`, the Kubernetes
  test plan, and the incident response report.

## Hardening changes (Step 2)

- `starter/Dockerfile` — pinned the base image to `opensuse/leap:15.6`
  instead of the mutable `latest` tag, defined and created a dedicated
  non-root `appuser` (the original `USER $SEC_USER` referenced a variable
  that was never defined), and cleaned the zypper package cache out of the
  image layer.
- `starter/docker_run_hardened.sh` — Docker-bench's runtime checks grade how
  a container is *run*, not just how its image is built. This documents the
  hardened `docker run` flags (`--cap-drop=ALL`, `--read-only`,
  `--security-opt=no-new-privileges`, memory/CPU/PID limits, a bounded
  restart policy) with the runtime weakness each one closes.
- `starter/cluster.yml` — merged in the baseline hardening fields from
  `starter/reference_hardened_cluster.yml`: Secrets encryption at rest,
  apiserver audit logging and event rate limiting, a restricted
  PodSecurityPolicy, `automountServiceAccountToken: false` on the default
  ServiceAccount, a non-root etcd uid/gid (52034:52034 — this is what fixes
  the Kube-bench 1.1.12 etcd data-directory-ownership check), kubelet TLS
  cipher suite restriction, `protect-kernel-defaults`, and kubelet serving
  certificate rotation — while keeping the actual node list, pinned
  `system_images`, and network plugin from the original (functional)
  `cluster.yml`, since the reference file is explicitly non-functional as-is.
- `submissions/kube_hardening_test_plan.txt` — the required Kubernetes
  hardening test plan.

## Flask app hardening + dependency remediation (Step 3)

- `vuln_app/sqli/app.py`, `vuln_app/sqli/dao/student.py`,
  `vuln_app/sqli/dao/user.py`, `vuln_app/sqli/templates/course.jinja2`,
  `vuln_app/migrations/001-fixtures.sql` — fixed 4 appsec vulnerabilities
  (XSS via disabled autoescaping, SQL injection in `Student.create`, CSRF
  protection that was implemented but never wired into the middleware
  chain, and unsalted MD5 password hashing). Full before/after detail in
  `submissions/appsec_vulnerabilities_remediated.txt`; the remediated
  `app.py` is also copied to `submissions/app.py` per the rubric.
- `vuln_app/Dockerfile.app`, `vuln_app/Dockerfile.db`,
  `vuln_app/requirements.txt`, `vuln_app/sqli/services/redis.py` —
  modernized the base images (EOL `python:alpine3.8` /
  `postgres:9.6.15-alpine` to `python:3.12-alpine` / `postgres:16-alpine`)
  and every pinned Python dependency, which is what a real Grype scan
  (`submissions/grype_app_out_of_box.png` /
  `submissions/grype_app_hardended.png`) actually called for — see
  `submissions/grype_remediation_notes.txt` for the full before/after and
  an explanation of the small number of findings left as documented,
  accepted residual risk (no upstream fix published yet, or only a
  pre-release fix exists). The modernized stack was verified end-to-end
  with `docker compose up` and real HTTP requests exercising login, CSRF
  enforcement, and session storage — not just a successful `pip install`.

## Run-time monitoring: Falco + Grafana (Step 4)

- `starter/setup_falco_grafana.sh` — the full runbook: kernel headers for
  the Falco kmod driver on OpenSUSE (`kernel-default-devel`, matched to
  `uname -r`, with `driver.kind=modern_ebpf` documented as the fallback if
  that build fails), installing Falco + falco-exporter via Helm,
  installing `kube-prometheus-stack` for Prometheus + Grafana, triggering
  a real Falco event (reading `/etc/shadow` inside a pod), and importing
  the Falco Grafana dashboard
  ([grafana.com/grafana/dashboards/11914](https://grafana.com/grafana/dashboards/11914),
  the one the falco-exporter project itself links to). Each screenshot
  the rubric asks for is called out inline as a "checkpoint" at the point
  in the script where it's actually available to capture. This step needs
  a real running RKE cluster and can't be faked — the script is ready to
  run once the cluster is up.
- `starter/falco_service_monitor.yaml` — fixed two bugs in the original:
  its `endpoints` list had `bearerTokenFile`/`port`/`interval` split
  across three separate one-key list entries instead of one endpoint
  object (each of which is invalid on its own — `port` is required per
  endpoint), and set its `release` label to a concrete value
  (`kube-prometheus-stack`) matching the Helm release name
  `setup_falco_grafana.sh` actually installs, instead of the placeholder
  timestamp value it shipped with.
- `starter/falco_rules.local.yaml` (optional standout) — a custom rule
  flagging outbound connections to well-known cryptocurrency-mining pool
  ports, aimed squarely at the crypto-miner payload used in the incident
  response step. Deliberately excludes port 8080, since that's this
  project's own vuln_app port.
- `starter/scripts/payload.sh` — removed the `--replicas` flag from each
  `kubectl run`; that flag was removed from `kubectl run` in modern
  kubectl (it only ever creates one Pod now), so the script as originally
  written would fail outright against any current cluster.

### Bringing the cluster up on Apple Silicon

`starter/setup_lima_node.sh` provisions the Lima node (see Setup above).
Getting an actual `rke up` to succeed against it, with a current RKE CLI
and Docker version, needed a few fixes beyond the Lima substitution itself
-- all now baked into `starter/cluster.yml` and the Lima script rather
than being one-off manual steps:

- **cri-dockerd**: modern RKE's hyperkube entrypoint talks to Docker
  through a CRI shim (`/var/run/cri-dockerd.sock`), which isn't installed
  by openSUSE's `docker` package. `setup_lima_node.sh` installs it and
  registers it as a systemd service.
- **`protect-kernel-defaults`**: this hardening flag (in `cluster.yml`'s
  kubelet config) makes kubelet refuse to start unless
  `kernel.panic_on_oops=1`, `kernel.panic=10`, and `vm.overcommit_memory=1`
  are already set on the node -- `setup_lima_node.sh` installs those via
  `/etc/sysctl.d`.
- **`internal_address`**: must be the node's real interface IP (shown by
  `ip -4 -o addr show` inside the VM), not `127.0.0.1` -- RKE hands it to
  the apiserver as `--advertise-address`, and a loopback address there
  makes the apiserver silently drop the `default/kubernetes` Endpoints
  object, which starves kube-proxy and breaks every addon deploy job that
  talks to the apiserver through that Service IP (canal/CNI included).
  `address`/`port` (127.0.0.1 and Lima's forwarded SSH port) stay separate
  -- those are just how the `rke` CLI on the Mac reaches the node over SSH.
- **CNI: flannel instead of canal**: this RKE build (1.8.14) bundles
  current canal/Calico addon manifests whose CRDs use CEL
  `x-kubernetes-validations` schema rules, which need Kubernetes 1.25+ to
  even validate -- but this cluster intentionally pins Kubernetes 1.20.4
  (`system_images` below) to keep the PodSecurityPolicy-based hardening in
  `addons`, since PSP was removed outright in 1.25. flannel needs no CRDs
  at all, so it sidesteps that version skew; its images were already
  pinned in `system_images`.
- **Known non-blocking issue**: the ingress-nginx addon
  (`rancher/nginx-ingress-controller:nginx-0.43.0-rancher1`, also pinned
  to 2021) crash-loops for the same reason the canal job failed --
  RKE 1.8.14 passes it flags that binary doesn't recognize. Nothing in
  this project's Falco/Grafana/incident-response steps routes through
  Ingress (the vuln app is reached directly via `docker compose`), so
  it's left as-is rather than chasing a third version-skew fix for an
  unused component.

## Setup

Requires Docker. The RKE node is a single VM, provisioned one of two ways:

- **Intel/x86_64 host:** Vagrant + VirtualBox, via `starter/Vagrantfile`.
- **Apple Silicon host (what this project was actually built and run on):**
  VirtualBox has no Apple Silicon support at all, so Vagrant/VirtualBox
  can't run here. `starter/setup_lima_node.sh` boots the same openSUSE
  Leap 15.6 guest as a native arm64 VM instead, using
  [Lima](https://lima-vm.io) (Apple's own Virtualization framework, no
  emulation).

Either way, point `rke up --config starter/cluster.yml` at the resulting
node's address/user/ssh_key_path (already filled in for the Lima node this
project uses). See `vuln_app/README.rst` for running the Flask app
directly with `docker compose up` (serves on `localhost:8080`) --
independent of the RKE cluster.

## Submission contents

Everything required for grading lives in `submissions/`:

- `security_architecture_design.png` — architecture/threat-model diagram.
- `threat_modeling_template.txt` — STRIDE attack surfaces + Docker-bench
  findings selected for hardening.
- `suse_docker_environment_out_of_box.png` / `_hardened.png` — Docker-bench
  before/after.
- `kube_cluster_out_of_box.png` / `_hardened.png` — Kube-bench before/after.
- `kube_hardening_test_plan.txt` — Kubernetes hardening test plan.
- `app.py` — the hardened Flask app code.
- `grype_app_out_of_box.png` / `_hardended.png` — Grype scan before/after.
- `kube_pods_screenshot.png`, `falco_alert_screenshot.png`,
  `falco_grafana_screenshot.png` — Falco + Grafana run-time monitoring
  evidence.
- `incident_response_report.txt` — the incident response write-up.

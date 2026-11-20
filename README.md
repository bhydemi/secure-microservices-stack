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

## Setup

Requires Docker, Vagrant, and VirtualBox (macOS/Linux host). See
`starter/Vagrantfile` and `starter/cluster.yml` for the VM and cluster
definitions, and `vuln_app/README.rst` for running the Flask app directly
with `docker compose up` (serves on `localhost:8080`).

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

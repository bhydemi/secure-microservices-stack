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
  restart policy) with the runtime weakness each one closes. Actually run
  against the live Lima node, before and after, with real
  `docker/docker-bench-security` output — see "Bringing Step 2 up" below and
  `starter/threat_modeling/threat_modeling_template.txt` for the 3 selected
  findings and their mapping back to the Docker threat model.
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
  Kube-bench run against the live cluster both with and without this block
  applied — see "Bringing Step 2 up" below.
- `submissions/kube_hardening_test_plan.txt` — the required Kubernetes
  hardening test plan.
- `starter/threat_modeling/threat_modeling_template.txt` (also copied to
  `submissions/`) — the STRIDE threat model for both Docker and Kubernetes
  (5 threats each), plus the Docker-bench findings section filled in from
  the actual scan below.

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
  `uname -r`, with `driver.kind=modern_ebpf` as the fallback this cluster
  actually ended up needing — see below), installing Falco via Helm with
  its own native Prometheus metrics endpoint, installing
  `kube-prometheus-stack` for Prometheus + Grafana, triggering a real
  Falco event (reading `/etc/shadow` inside a pod), and importing the
  Falco Grafana dashboard
  ([grafana.com/grafana/dashboards/11914](https://grafana.com/grafana/dashboards/11914)).
  Each screenshot the rubric asks for is called out inline as a
  "checkpoint" at the point in the script where it's actually available
  to capture. This has been run end-to-end against the live cluster
  (not just written and left untested) — see "Bringing Step 4 up" below
  for what that actually took.
- `starter/falco_service_monitor.yaml` — fixed two bugs in the original:
  its `endpoints` list had `bearerTokenFile`/`port`/`interval` split
  across three separate one-key list entries instead of one endpoint
  object (each of which is invalid on its own — `port` is required per
  endpoint), and set its `release` label to a concrete value
  (`kube-prometheus-stack`) matching the Helm release name
  `setup_falco_grafana.sh` actually installs, instead of the placeholder
  timestamp value it shipped with. Its `selector` now targets the
  `falco-metrics` Service (Falco's own built-in metrics endpoint) instead
  of the separate `falco-exporter` release, and the `bearerTokenFile` is
  gone entirely — see "Bringing Step 4 up" below for why.
- `starter/falco_rules.local.yaml` (optional standout) — a custom rule
  flagging outbound connections to well-known cryptocurrency-mining pool
  ports, aimed squarely at the crypto-miner payload used in the incident
  response step. Deliberately excludes port 8080, since that's this
  project's own vuln_app port. Also matches on the `xmrig` process name
  directly, added after actually running the exercise against this
  cluster surfaced a real gap in the port-only version — see "Running
  Step 5" below and `submissions/incident_response_report.txt`.
- `starter/scripts/payload.sh` — removed the `--replicas` flag from each
  `kubectl run`; that flag was removed from `kubectl run` in modern
  kubectl (it only ever creates one Pod now), so the script as originally
  written would fail outright against any current cluster.

### Running Step 5 (incident response) on Apple Silicon

`payload.sh`'s three demo images are all `linux/amd64`-only 2018-era
builds that compile `xmrig` from source on every start rather than
shipping a binary. Two problems, same root cause as everywhere else in
this README: an architecture/age mismatch between old pinned artifacts
and this arm64 host.

- **QEMU emulation**: without it, both `moneropool` and `cryptotonight`
  fail immediately with `exec format error` (their binaries are amd64,
  the node is arm64, and the node has no binfmt_misc emulation
  registered by default). Fixed with a one-time
  `docker run --rm --privileged tonistiigi/binfmt --install all` on the
  node -- after that, both pull and run correctly, just slowly (compiling
  the full `xmrig` + `argon2`/OpenCL/CUDA backend under x86-on-arm64
  emulation on a 2-vCPU VM took several minutes each).
- **`minergate` is permanently gone**: `servethehome/monero_cpu_minergate`
  returns "repository does not exist" on pull -- the image has been
  deleted from Docker Hub outright, not an emulation or arch issue. No
  working substitute was run in its place (random same-named images from
  unverified Docker Hub accounts are not something to run in a security
  exercise); `incident_response_report.txt` documents this as a dead
  upstream artifact rather than a detection gap, since nothing of it ever
  executed.
- **The custom rule's port list had a real blind spot**: once
  `moneropool` actually ran, its pool (`mine.moneropool.com`) turned out
  to be listening on port 80, not anywhere in the rule's hardcoded port
  list -- and `cryptotonight` reached a real, currently-live pool
  (`pool.supportxmr.com:8100`) on a different port again. `port: 80/443`
  can't just be added to the list (constant false positives on normal
  HTTP), so the rule now also matches on the `xmrig` process name
  (confirmed via `ps aux` inside the running container) as an independent
  signal. Both payloads were detected and contained within seconds of
  this fix.

### Bringing Step 2 up (Docker-bench + Kube-bench)

Both benchmarks were actually run against the live environment, before and
after hardening, rather than just documented as intended config changes.

- **Docker-bench**: built and ran `secure-microservices-stack:outofbox`
  (the original, unmodified `starter/Dockerfile` -- mutable `latest` tag,
  undefined `USER $SEC_USER`) with a bare `docker run`, then
  `docker/docker-bench-security` against the live Lima node
  (`submissions/suse_docker_environment_out_of_box.png`, `Checks: 105,
  Score: 4`). Rebuilt as `secure-microservices-stack:hardened` and started
  with every flag from `docker_run_hardened.sh`
  (`submissions/suse_docker_environment_hardened.png`), and confirmed via
  `docker inspect` that each flag actually took effect (non-root user,
  `CapDrop: [ALL]`, read-only rootfs, a 256 MiB memory limit, and a 100
  PIDs limit). The 3 findings selected for
  `threat_modeling_template.txt` (4.1 running-as-root, 5.10 no memory
  limit, 5.28 no PIDs limit) all flip from WARN to resolved once the
  hardened flags are applied -- the two images had to be built and run
  with QEMU emulation registered (see "Running Step 5" above), since
  `docker/docker-bench-security`'s own image is amd64-only too.
- **Kube-bench**: ran `aquasec/kube-bench` with the `rke-cis-1.7` benchmark
  profile (matching `starter/docs/Rancher_Benchmark_Assessment.pdf`)
  against the live cluster in its hardened state
  (`submissions/kube_cluster_hardened.png`, `56 PASS / 2 FAIL / 39 WARN /
  34 INFO`). To get a genuine "before" baseline without standing up a
  second cluster, `cluster.yml` was temporarily edited back to the
  original scaffold's values for every Step-2 hardening field (etcd
  uid/gid, PSP, secrets encryption, audit log, event rate limit, kubelet
  flags, serving-cert generation, addons) and re-applied in place with
  `rke up --config cluster.yml` -- reusing the *same* config filename so
  RKE reconciles the existing running cluster instead of generating a
  fresh CA for what it would otherwise treat as a brand new cluster (the
  first attempt, against a differently-named config file, failed exactly
  that way: a `tls: bad certificate` error from etcd, caught before any
  control-plane container was actually touched). Captured the "before"
  result (`submissions/kube_cluster_out_of_box.png`, `55 PASS / 2 FAIL /
  40 WARN / 34 INFO`), then restored `cluster.yml` to the real hardened
  content and ran `rke up` again, which re-encrypted all 69 Secrets at
  rest and brought every check back to the original hardened numbers.
  Only one automated check actually differs between the two runs
  (`1.2.9 EventRateLimit`, PASS vs WARN) -- most of this project's other
  Step-2 hardening (PSP enforcement, RBAC scope, NetworkPolicy) falls
  under kube-bench's Section 5 "Kubernetes Policies" checks, which need
  live API access to verify and are marked Manual/INFO regardless of
  actual cluster state in this run mode (no kubeconfig was mounted into
  the kube-bench container); they're reviewed manually in the threat
  model and test plan instead.

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
- **metrics-server RBAC**: RKE 1.8.14's bundled `system:metrics-server`
  ClusterRole grants `nodes/metrics` but not `nodes/stats` -- the resource
  kubelet's authorization webhook actually checks for the `/stats/summary`
  endpoint this metrics-server version scrapes, so it crash-loops with
  `403 Forbidden` until that's added:
  `kubectl patch clusterrole system:metrics-server --type=json -p='[{"op":"add","path":"/rules/0/resources/-","value":"nodes/stats"}]'`.
  This is a one-time post-`rke up` step, not something `cluster.yml` can
  express -- the addon's manifest is baked into the RKE binary -- so it
  needs re-running after any `rke remove`/fresh `rke up`.
- **The Lima SSH port and QEMU emulation don't survive a VM restart**:
  `cluster.yml`'s `port` field (the `rke` CLI's SSH path to the node) goes
  stale every time the Lima VM stops and starts again -- Lima picks a new
  forwarded port on each boot, so `limactl list rke-node1` has to be
  re-checked and `cluster.yml` updated before any further `rke up` against
  a VM that was ever stopped. Likewise, the one-time QEMU emulation setup
  from "Running Step 5" below (`tonistiigi/binfmt --install all`) registers
  a binfmt_misc handler that does not persist across a VM restart either --
  it needs re-running any time the VM comes back up and an amd64-only image
  is needed again. Both of these bit this project directly while capturing
  the CIS benchmark evidence below, after the VM had been stopped and
  restarted between sessions.
- **Known non-blocking issue**: the ingress-nginx addon
  (`rancher/nginx-ingress-controller:nginx-0.43.0-rancher1`, also pinned
  to 2021) crash-loops for the same reason the canal job failed --
  RKE 1.8.14 passes it flags that binary doesn't recognize. Nothing in
  this project's Falco/Grafana/incident-response steps routes through
  Ingress (the vuln app is reached directly via `docker compose`), so
  it's left as-is rather than chasing a third version-skew fix for an
  unused component.

### Bringing Step 4 up (Falco + Grafana)

Running `setup_falco_grafana.sh` for real against the live cluster surfaced
three more fixes, on top of the ones above:

- **br_netfilter**: openSUSE Leap's default image doesn't load the
  `br_netfilter` kernel module, so bridged pod-to-pod traffic through
  flannel's `cni0` bridge skips iptables NAT in one direction -- a request
  to a ClusterIP backed by a pod on the *same* node gets DNATed correctly
  on the way in, but the reply never gets re-NATed back to the Service IP,
  so the client's kernel sees an unsolicited packet and drops it. On a
  single-node cluster this breaks every same-node Service call, including
  kube-dns: pods could resolve a pod IP directly, but every DNS query
  through the kube-dns Service IP (`10.43.0.10`) timed out -- which is
  exactly what made Falco's `falcoctl-artifact-install` init container
  (and the kmod driver-loader before it) fail with `dial tcp: i/o timeout`
  despite the node itself having working DNS and internet access.
  `setup_lima_node.sh` now loads the module and sets
  `net.bridge.bridge-nf-call-iptables=1` (and the ip6tables equivalent) via
  `/etc/modules-load.d` and `/etc/sysctl.d`.
- **Falco driver: modern_ebpf, not kmod**: the chart default (`kmod`, a
  DKMS-built kernel module) fails outright here -- the node's kernel was
  built with SUSE's gcc 7.5.0, but every gcc in the `falco-driver-loader`
  image (7/11/12) passes a kernel-build flag
  (`-fmin-function-alignment=8`) that none of them recognize. That's a
  toolchain mismatch baked into the image, not something a retry or a
  flag fixes. `modern_ebpf` (CO-RE eBPF, no headers or compilation,
  Linux 5.8+ -- this node runs 6.4) is the documented fallback and what
  `setup_falco_grafana.sh` now installs with.
- **falco-exporter replaced with Falco's own metrics endpoint**: the
  original plan was `falcosecurity/falco-exporter`, a sidecar reading
  Falco's gRPC output socket. It doesn't work with the Falco version this
  chart installs (0.45.2) -- the falco-exporter chart's own install notes
  say outright that "Starting from Falco version 0.38, Falco can expose
  Prometheus metrics directly, eliminating the need for a separate
  exporter," and this chart version's values no longer have a
  `grpc`/`grpc_output` section to even turn on, so falco-exporter's gRPC
  client just hangs forever and the pod never goes Ready.
  `setup_falco_grafana.sh` instead sets `metrics.enabled=true` and
  `falco.webserver.prometheus_metrics_enabled=true` on the Falco release
  itself, which exposes a plain-HTTP, no-auth `/metrics` endpoint on a
  chart-created `falco-metrics` Service (port 8765) -- what
  `falco_service_monitor.yaml` now targets. The metric name changed too:
  `falcosecurity_falco_rules_matches_total` (labeled by `rule_name`)
  instead of falco-exporter's `falco_events`/`falco_events_total`, which
  also means the dashboard imported from
  [grafana.com/grafana/dashboards/11914](https://grafana.com/grafana/dashboards/11914)
  needs its two panel queries (`Events rate`, `Totals`) rewritten to the
  new metric name before it shows any data -- it still imports with the
  old queries and just silently shows nothing otherwise.
- **kube-prometheus-stack: pin an old chart version, and `--server-side=false`**:
  the current chart's CRDs hit the exact same CEL `x-kubernetes-validations`
  problem as canal did -- they need Kubernetes 1.25+ to validate, and this
  cluster is pinned to 1.20.4. Chart `39.13.3` (Prometheus Operator
  `0.58.0`, mid-2022) predates CEL in these CRDs and installs cleanly.
  Separately, Helm 4 defaults to server-side apply, and this apiserver's
  typed-patch support is too old to compute a merge key for a couple of
  the chart's Service manifests that omit an explicit `protocol: TCP`
  (relying on the apiserver's own defaulting, which SSA's structured-merge
  diff doesn't fall back to here) -- `helm install ... --server-side=false`
  avoids that by using the older three-way client-side merge instead.

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

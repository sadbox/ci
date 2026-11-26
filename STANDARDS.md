# Project baseline

What every project follows, so projects don't drift apart. New projects
start from this; existing ones are brought in line. A deliberate deviation
is recorded under [Deviations](#deviations) by PR, with the reason, never
left to drift. Change this file by PR, then update the projects.

## Services

Every long-running service:

- **Health check in the binary, as a flag.** `<binary> -healthcheck`
  exits 0 when the service is healthy and non-zero otherwise, by calling
  the running process (e.g. its `/healthz` on loopback) with a short
  timeout. It is the only health check: the Quadlet unit's `HealthCmd`
  runs it (Podman ignores an image's `HEALTHCHECK`), with
  `Notify=healthy` so a unit is only started once healthy and
  podman-auto-update rolls back an image that never is. No `wget`, `curl`
  or shell from a base image.
- **Configuration from files and environment, secrets from 1Password.**
  Each service receives only its own secrets, rendered per service on the
  host (`quadlet/render-env.sh`, `op inject`) into an env file the unit
  reads. No service gets the host's 1Password service-account token.
- **Shared Go code lives in the shared module** (see [Go](#go)), not copied
  between repositories and not imported from another service's repository.
- **Logs:** `log/slog` text handler to stderr.

## Go

- **One Go version, from the build image.** The Dockerfile's
  `golang:X.Y.Z@sha256:<digest>` is the source of truth; CI runs the tests
  inside that build stage (as sprobot's `test` target does), so a
  Dependabot Docker bump moves the compiler and the tests together. No
  floating minor tags (`golang:1.27`); `go.mod`'s `go`/`toolchain` lines
  must not be newer than the image.
- **Static builds:** `CGO_ENABLED=0`, `-trimpath`. Prefer pure-Go libraries
  over cgo (e.g. `modernc.org/sqlite`, not `mattn/go-sqlite3`).
- **Checks in CI, on linux/amd64 and linux/arm64 natively:** `gofmt`,
  `go vet`, `go test -race`, `golangci-lint`, `govulncheck`, by sadbox/ci's
  `go.yml`, never a hand-rolled job (which keeps whatever it checked when it
  was written). lint.yml fails a repository with a Go module no `go.yml`
  call covers (`scripts/go-workflow.sh`); a module that can't use it is a
  deviation recorded below and listed in lint.yml's `go-exempt`.

## Other languages

Every language a repository uses gets a linter and a vulnerability check
in CI:

| Language / file type | Lint | Vulnerabilities |
|---|---|---|
| Go | gofmt, go vet, golangci-lint | govulncheck |
| JavaScript / npm | eslint where there is first-party JS | `npm audit --omit=dev` (production deps) and `npm audit signatures` |
| Python (uv) | ruff | `uv` + osv-scanner against `uv.lock` |
| Shell | shellcheck | – |
| GitHub Actions | actionlint, zizmor | zizmor (known-vulnerable actions) |
| Dockerfiles | hadolint | – (the dep-review gate merges only listed official images, after its minimum age, and reads nothing of an image) |
| Ansible | ansible-lint, `--syntax-check` | – |
| OpenTofu | `tofu fmt -check`, `tofu validate`, tflint | – (providers pinned by version and lockfile hash; each bump reviewed by a human, see [OpenTofu](#opentofu)) |

## Binary files

No binary file is tracked unless the repository declares it: a build's
output, an archive or a database committed by accident is megabytes of
history for good, and content no reviewer can read. lint.yml's `binaries`
step fails on any tracked file git takes for binary that no
`.gitattributes` line marks `binary`, and on a declared one over 5 MiB
(`binary-max-bytes`). Declare by the narrowest pattern that fits
(`docs/screenshots/*.png binary`, never `* binary`), in the PR that adds
the file.

## OpenTofu

For hosted services (DNS, monitoring, GitHub settings), not hosts: hosts
stay with Ansible.

- **OpenTofu, not Terraform.**
- **State encrypted on the client, enforced.** Every root has an
  `encryption` block (`pbkdf2` key provider, `aes_gcm` method) with
  `enforced = true` for both `state` and `plan`. The passphrase is a
  sensitive variable, randomly generated (not chosen) and supplied from
  1Password at run time, never written to a file. Without it `init`,
  `plan` and `apply` refuse to run, so a bare `tofu apply` can't write
  plaintext state.
- **Credentials only from 1Password, on the operator's machine**
  (`op run`), for attended plans and applies. CI holds none: it runs
  lint.yml's `tofu` job only (`fmt`, `validate` with `-backend=false`,
  tflint).
- **Versions pinned:** `required_version`, an exact `version` for every
  provider, and each root's `.terraform.lock.hcl` committed with hashes for
  linux_amd64, linux_arm64 and darwin_arm64 (`tofu providers lock
  -platform=…`). CI's `init` is `-lockfile=readonly`.
- **Dependabot:** the `opentofu` ecosystem, one entry per root directory.
  The dep-review gate doesn't handle it (a branch for an ecosystem it
  doesn't know is classified unverified), so every bump goes to a human:
  read the provider's changelog, and plan with no unexpected changes
  before merging.
- **Existing resources are imported** with `import` blocks, and the first
  apply follows a plan that shows no changes.

## Container images

- **Runtime: distroless.** `gcr.io/distroless/static-debian12:nonroot`
  for static binaries. No shell, no package manager in a runtime image.
  Pinned `tag@sha256:<index digest>`.
- **Build stages: Debian, not Alpine.** Node stages use `node:<major>-slim`
  (glibc; nodejs.org publishes and signs the binaries for every
  architecture we build). Go stages use the official `golang` image.
- **Architectures: linux/amd64 and linux/arm64**, built and tested natively
  on `ubuntu-26.04` and `ubuntu-26.04-arm` (no QEMU), so local development
  on the Mac and production on bonnet run the same image.
- **Tags:** `:latest` plus one immutable tag, `sha-<7-char commit>`, on
  every publish; labels `org.opencontainers.image.source` and
  `org.opencontainers.image.revision`. BuildKit provenance and SBOM
  attestations on every image, private repositories included
  (`provenance: mode=max`, `sbom: true`). GitHub artifact attestations
  (`actions/attest-build-provenance`) on public repositories only: on
  private ones they need GitHub Enterprise Cloud, which isn't worth paying
  for here. Private images go without them; that is not a deviation.
- **`:latest` never moves back.** The step before the one that moves
  `:latest` is sadbox/ci's `newer-than-latest` action: when `:latest` was
  built from a later commit than this run's (a re-run of an old publish,
  after a newer one), the run tags `sha-<7>` alone and sends no report.
  Otherwise the host's auto-update would install the older build, on
  whatever state the newer one left. sprobot's own check (the commit is
  still the tip of the default branch) does the same and more.
- **Publish report.** The step after the one that moves `:latest` is
  sadbox/ci's `report-publish` action, once for the images the host runs
  (`names:` each container's name there). It records the build in Grafana
  Cloud, when and where it sits in the repository's history
  (`sadbox_image_published_timestamp_seconds` and `..._commits`, by
  `name` and `version`), which an alert compares with what the host runs:
  a build newer in git history than the running one, published and not
  running hours later, is an update that didn't land. A second workflow,
  `report-latest.yaml`, runs the action daily with `latest-of:` (what
  `:latest` is now, from the registry), which repairs a report that was
  missed. The two secrets (`GRAFANA_PUBLISH_URL`, `GRAFANA_PUBLISH_AUTH`)
  are in the repository's `publish` environment, limited to the default
  branch (homelab-configs `tofu/github`), and both jobs run in it: the
  token can write any series in the stack, so no other branch's workflow
  may read it. A failed report fails the job; a re-run reports it (and
  can't move `:latest` back, above), as does running `report-latest.yaml`
  by hand, or its next daily run.
- **Build cache:** the Actions cache (`type=gha`, one scope per runner
  architecture) is allowed, see [GitHub Actions](#github-actions).
- **`.dockerignore`** in every repository with a Dockerfile (at least
  `.git` and local data).
- **Non-root.** Every image runs as a non-root user (`nonroot` in
  distroless).

## Quadlet units (bonnet)

- `UserNS=auto`, volumes mounted `:idmap`, `ReadOnly=true`,
  `DropCapability=ALL`, `NoNewPrivileges=true` (add back only what a
  service needs, with a comment saying why).
- `Memory=` and `PidsLimit=` on every unit, sized from observed peak usage
  with headroom, plus `StopTimeout=`.
- Data under `/var/lib/<service>`, created by ansible with the ownership
  the container expects; nothing under `/root`.
- Ports below 1024 are published by Quadlet (`PublishPort=80:8080`);
  processes inside listen on high ports.
- `HealthCmd=["/<binary>", "-healthcheck"]` (see [Services](#services)).
- Image policy: `:latest` with `AutoUpdate=registry`, the unit gating its
  own start where state or config can be wrong (`ExecStartPre` checks).

## GitHub Actions

- **Workflow lockfile.** Every workflow is onboarded to
  `.github/workflows/actions.lock` with `gh actions-lock` (the extension
  installed at a pinned version, v0.4.1, the one lint.yml runs), in the
  same PR that adds or changes the workflow: Dependabot regenerates entries for onboarded workflows but
  never onboards one. This pins step-level actions and their transitive
  actions. Step `uses:` names an exact tag (`@v7.0.1`), never a floating
  one (`@v7`, `@main`), which would accept any commit in its history,
  rollbacks included. A workflow not yet onboarded keeps the previous rule:
  every `uses:` pinned by full commit SHA with a `# vX.Y.Z` comment.
  The runner enforces an onboarded workflow's lockfile with or without the
  policy: a `uses:` it doesn't list (a SHA pin included) fails the run
  before any job starts (seen on sadbox/ci#8, 2026-11-22).
- **Cross-repository reusable workflows** (job-level `uses:` of
  sadbox/ci, sadbox/dep-review) by full commit SHA with a `# vX.Y.Z`
  comment: the lockfile does not pin them. The called repository is
  onboarded to its own lockfile first, and a caller onboards only once it
  pins a callee commit that contains `actions.lock`. Same-repository calls
  (`uses: ./.github/workflows/…`) carry no ref.
- **Images in workflows** (`docker://` steps, job `container:` and
  `services:`) pinned `tag@sha256:<digest>`: the lockfile does not cover
  them.
- **`gh actions-lock --verify` on every PR**, as a required status check
  (sadbox/ci's `lint.yml`, check `lint / lint`; not path-filtered, per
  [Repository settings](#repository-settings)).
- **Triggers:** `pull_request`, plus `push` to the default branch only. A
  push trigger on every branch runs everything twice for each commit to a
  PR (once for the push, once for the PR). `schedule` for the dep-review
  sweep and the daily publish report (`report-latest.yaml`) only.
- **Concurrency:** a PR's new run cancels the one it supersedes; no other
  run cancels or waits:
  `group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.run_id }}`
  and `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`, as
  in `examples/ci.yaml` (a push or a `workflow_call` run is then a group of
  its own; a shared group would let a newer pending run displace an older
  one). A publish that must not overlap another keeps a fixed group.
- **Few jobs.** On private repositories each job bills at least a whole
  minute, so checks that take seconds are steps of one job (lint.yml's
  `lint`), not a job each. A new job is for another runner, real
  parallelism, or isolation: a step that runs untrusted code on the host
  (lint.yml's `ansible`) can forge the result of every step after it.
- **Path-gated work** reports through one job that always runs: a detect
  step decides, the expensive jobs skip by `if:`, and an aggregate job
  (`needs:` them, `if: always()`) fails unless each succeeded or was
  skipped. The aggregate is the required check: a matrix job skipped by
  `if:` never expands, so its per-entry checks would wait forever.
- **Require lockfile** (Settings → Actions → Policies, rule
  `require_lockfile`, all workflows, active) on every repository once
  `--verify` passes there. Created in the UI: the REST policies API
  accepts the rule in a read but not in a create or update (2026-11-22).
- Repository setting **Require actions to be pinned to a full-length
  commit SHA** on (`sha_pinning_required`); a workflow in the lockfile
  satisfies it.
- zizmor 1.32.0 or later (the first that accepts lockfile-pinned refs).
- **Actions cache allowed** (`actions/cache`, BuildKit `type=gha`,
  setup-go/setup-uv caching), an accepted risk (owner, 2026-11-22). The
  dep-review gate handles untrusted dependency contents in the default
  branch's cache scope. Entries there are first-write-wins, and every run
  falls back to that scope (main's, and a new PR's), so a planted entry
  could reach an image or a test result (a cached `go test` pass). Build
  times were judged worth that risk. zizmor's `cache-poisoning` audit is
  off in `configs/zizmor.yml` for the same reason.
- Top-level `permissions: contents: read` (or `{}`); jobs ask for more only
  where needed (`packages: write` only on the publish job).
- Untrusted event fields reach shells only through `env:`, never `${{ }}`
  inside `run:`.
- No `pull_request_target`; `workflow_run` only for the dep-review gate.
- Runners pinned to `ubuntu-26.04` / `ubuntu-26.04-arm`.
- `timeout-minutes` on every job.
- Default workflow token read-only (repository setting); "Allow GitHub
  Actions to create and approve pull requests" off.

## Dependabot

- `version: 2`, daily, for every ecosystem the repo has, including
  `github-actions` and `docker`.
- `cooldown: default-days: 3` set explicitly on every ecosystem, Docker
  included (it is Dependabot's default anyway, measured from the tag's last
  push); security updates skip it.
- Docker images grouped into one PR per directory.
- Reviewed and merged by the dep-review gate (sadbox/dep-review). The gate
  treats `actions.lock` as a dependency change: a PR whose lockfile diff
  goes beyond the entries for the action it bumps goes to a human.

## Repository settings

- Default branch ruleset: no deletion, no force-push, linear history, pull
  requests required, required status checks for CI (only checks that run on
  every PR, never path-filtered ones: path-gated work is required through
  its aggregate job, see [GitHub Actions](#github-actions)), and **signed
  commits required**.
- Dependabot alerts and security updates on; on public repositories also
  secret scanning and push protection.
- No unused secrets.

## Deviations

- **sadbox/sadbox.org:** default branch is `master`.
- **sadbox/dotfiles (chezmoi's source):** every machine commits and pushes
  straight to `master`, and only home Macs sign, so its default-branch
  ruleset has no pull requests, status checks or signed commits: only no
  deletion, no force-push and linear history (homelab-configs
  `tofu/github/rulesets.tf`). The owner's choice (2026-11-22).
- **Espresso-Aficionados/linkclean:** a library, no image; tests against a
  Go version matrix (1.26.x and stable) rather than a build image.
- **rproxy (Caddy) logs JSON**, not slog text: Caddy's own format, kept
  by the owner's choice (2026-11-18).
- **cloudflared (homelab-configs, the Cloudflare Tunnel):** upstream's
  `docker.io/cloudflare/cloudflared:latest` with `AutoUpdate=registry`,
  not an image built here from a pinned base, so a release reaches bonnet
  without Dependabot's cooldown or the dep-review gate. Its health check is
  `cloudflared tunnel ready`, the binary's own, not a `-healthcheck` flag.
  The owner's choice (2026-11-22): tunnel fixes land within
  podman-auto-update's 2 hours.
- **egress (homelab-configs, the outbound proxy):** Smokescreen v2
  (`github.com/stripe/smokescreen/v2`) is pinned to an untagged
  pseudo-version, since v2 has no tags yet, and Dependabot never moves a
  pseudo-version. `.github/workflows/smokescreen-bump.yaml` moves it
  weekly instead, to the newest master commit whose pull request merged at
  least 14 days ago (the cooldown, measured by `merged_at`, not the commit's
  own date), through a PR a person merges, not the dep-review gate. The
  rest of `egress/go.mod` and its base images are Dependabot's as usual.
  The owner's choice (2026-11-22): v2 is where Smokescreen's development
  is; remove this entry once v2 is tagged.
- **podman-proxy (homelab-configs, the door to Podman's API socket):** it
  links Go's standard library only (`go.mod` has no requirements), so it
  doesn't import `sadbox/svc`: its `-healthcheck` flag is the standard's,
  written again in the service, and it has no `svc/telemetry`. Its counts
  are a `/metrics` it writes itself, scraped by Alloy on a network of its
  own, not pushed over OTLP. The owner's choice (2026-11-22): it is the one
  container given that socket, so nothing else is linked into it.
- **container-watch (homelab-configs, which build each container runs):**
  one series, `sadbox_container_info`, is scraped from a `/metrics` of its
  own rather than pushed over OTLP like the rest of its telemetry. A scrape
  marks a stopped container's series gone at once; a pushed series lingers
  five minutes, and after every deploy both builds would read as running.
- **sadbox/ci `tools/go`:** the module that pins the CI tools' versions
  (golangci-lint, govulncheck) has no code of its own, so `go.yml` doesn't
  check it; it is in `ci.yml`'s `go-exempt`. Dependabot bumps it; the
  fixtures' runs are its test.
- Being brought in line (remove each entry when done):
  - amd64-only tests: linkclean.
  - govulncheck blind spot, rproxy (Caddy): Dependabot alerts on
    `github.com/go-jose/go-jose/v3` <= 3.0.5 (GHSA-vvm8-gf78-28g4,
    GHSA-4w3g-jfj2-cw2q, GHSA-mgcc-cww5-fp2q) have no fixed v3 release.
    `smallstep/certificates` pulls it in through `caddypki`, which
    `caddytls` imports, so trimming Caddy's modules can't drop it. The
    vulnerable code is unreachable: the Caddyfile has no `acme_server`,
    `tls internal` or `pki`. Blocked on smallstep/certificates moving to
    `go.step.sm/crypto` v0.92 (go-jose v4). vuln.go.dev has no entry for
    these yet (2026-11-21); if one lands as called, `go.yml` has no
    per-ID exclusion and rproxy's CI goes red.

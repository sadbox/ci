# sadbox/ci

The standard base for sadbox projects:

- [STANDARDS.md](STANDARDS.md): the project baseline every repository
  follows. Changed by PR here, then the projects are brought in line.
- Reusable GitHub Actions workflows that run the CI checks it requires:
  - [`go.yml`](.github/workflows/go.yml): gofmt, go vet, go test -race,
    golangci-lint and govulncheck, natively on linux/amd64
    (`ubuntu-26.04`) and linux/arm64 (`ubuntu-26.04-arm`).
  - [`lint.yml`](.github/workflows/lint.yml): the linters and
    vulnerability checks for everything else, each run only where the
    repository has files for it.
- [`report-publish`](report-publish/action.yml): the action a publish
  workflow runs after it moves `:latest`, so Grafana Cloud knows which
  build the host should be running.

## Adopting it

Copy [examples/ci.yaml](examples/ci.yaml) to `.github/workflows/ci.yaml`
and pin both `uses:` lines to the commit of a release tag, with the tag in
the comment:

```yaml
jobs:
  go:
    uses: sadbox/ci/.github/workflows/go.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
  lint:
    uses: sadbox/ci/.github/workflows/lint.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
```

Dependabot's `github-actions` ecosystem (which every repository has)
updates reusable-workflow pins like action pins: a new tag here becomes a
PR moving the SHA and the comment, after the cooldown. Callers never use a
branch or a tag directly.

The jobs need `contents: read` and nothing else: no secrets (zizmor's
online audits use the job's read-only token). The required status checks
are the jobs' names, e.g. `go / test (linux/amd64)`,
`go / test (linux/arm64)`, `lint / lint` and, where there is an ansible
directory, `lint / ansible`. lint.yml runs every linter as a step of one
job (skipped where it doesn't apply) except ansible, which runs code on
the host and so gets a runner of its own. Before v0.2.0 it was one job per
linter (`lint / actionlint`, `lint / zizmor`, ...); a skipped job counts as
passing.

### go.yml

**Docker mode** (the default) builds the Dockerfile's `test` target for
each platform and runs every check inside it, in its `WORKDIR`, so the
tests, the linters and the service all use the Go of the Dockerfile's
`golang:X.Y.Z@sha256:` build stage. The `test` target is the Go build
stage with the module's sources (and anything generated that they embed)
in its `WORKDIR`, which must be the module root:

```dockerfile
FROM golang:1.27.4@sha256:<digest> AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /svc .

# go.yml runs the checks in here; its CMD, if any, is ignored.
FROM build AS test
```

The image must run as root (the golang image does) and have `bash`.
golangci-lint and govulncheck are compiled inside the image too, so they
always support its Go. go test runs with `CGO_ENABLED=1` (the race
detector needs cgo) whatever the image sets.

**setup-go mode**, when `go-versions` is set, runs the same checks on the
runner after `actions/setup-go`, for each Go version and each module: for
a library with no image, or a tool built outside Docker.

| Input | Default | |
|---|---|---|
| `context` | `.` | Docker: the build context. |
| `dockerfile` | `<context>/Dockerfile` | Docker: the Dockerfile. |
| `test-target` | `test` | Docker: the target the checks run in. |
| `build-args` | | Docker: `NAME=VALUE` lines. |
| `go-versions` | | setup-go mode: a JSON list, e.g. `["1.26.x", "stable"]`; an entry ending in `go.mod` (`deploy/go.mod`) takes that file's version. |
| `modules` | `.` | setup-go: module directories, whitespace-separated. |
| `run-tests` | `true` | `false` when the caller runs its tests its own way (e.g. as root). |
| `go-test-flags` | | Extra `go test` flags. |
| `golangci-config` | | A golangci-lint configuration. |
| `timeout-minutes` | `30` | Per job. |

A repository with several services or modules calls go.yml once per
Dockerfile (Docker mode) or lists the modules (setup-go mode).

### lint.yml

| Linter | Runs when the repository has | Configuration it looks for |
|---|---|---|
| actionlint | always | `.github/actionlint.yaml` |
| zizmor | always | `zizmor.yml`, `.github/zizmor.yml` |
| shellcheck | `*.sh`, `*.bash`, `*.ksh`, `*.dash`, or a sh/bash/dash/ksh shebang | `.shellcheckrc` |
| hadolint | `Dockerfile*`, `Containerfile*`, `*.Dockerfile` | `.hadolint.yaml` |
| ruff check | `*.py` | `ruff.toml`, `pyproject.toml` `[tool.ruff]` |
| osv-scanner | `uv.lock` | `osv-scanner.toml` beside the lockfile |
| npm | `package-lock.json`: `npm ci --ignore-scripts`, `npm audit --omit=dev`, `npm audit signatures`, and eslint where an eslint config exists | the eslint config |
| ansible | the `ansible-directory`: `ansible-playbook --syntax-check` on each playbook with the directory's own locked uv environment, and ansible-lint with its collections | `.ansible-lint`, `.config/ansible-lint.yml` |
| tofu | `*.tf`, `*.tofu`: `tofu fmt -check`; in each root (a directory with a `.terraform.lock.hcl`), `tofu init -backend=false -lockfile=readonly` and `tofu validate`, with no credentials or state; tflint in every directory with `*.tf` files | `.tflint.hcl` in the repository root |

Files are the repository's tracked files (`git ls-files`).

| Input | Default | |
|---|---|---|
| `skip` | | Linters not to run: `actionlint zizmor shellcheck hadolint ruff osv-scanner npm eslint ansible tofu actions-lock`. |
| `exclude` | | An extended regex; matching paths are not linted. |
| `ansible-directory` | `ansible` | |
| `ansible-playbooks` | top-level `*.yml` naming `hosts:` or `import_playbook:` | Relative to `ansible-directory`. |
| `actionlint-config`, `zizmor-config`, `hadolint-config`, `ansible-lint-config`, `tflint-config` | | A configuration file. |
| `zizmor-online` | `true` | zizmor's online audits (known-vulnerable actions, impostor commits). |

Output: `linters`, the JSON list of the linters that ran.

### report-publish

A step, not a workflow, so it costs no extra job. Right after the step
that moves `:latest`, in a job that runs in the repository's `publish`
environment:

```yaml
  publish-merge:
    environment: publish # holds the two secrets; the default branch only
    steps:
      # ... the step that moves :latest ...
      - name: Tell Grafana what :latest now is
        uses: sadbox/ci/report-publish@vX.Y.Z
        with:
          names: sprobot stickybot
          url: ${{ secrets.GRAFANA_PUBLISH_URL }}
          auth: ${{ secrets.GRAFANA_PUBLISH_AUTH }}
```

It sends one sample per name to Grafana Cloud's Influx line-protocol
endpoint: `sadbox_image_published_timestamp_seconds{name, version}`, the
time of the report. `names` are the containers that run the images on the
host (what its `sadbox_container_info` calls them), so the two series
join. A step-level action: the caller names the tag and `gh actions-lock`
pins the commit (STANDARDS.md, GitHub Actions).

| Input | Default | |
|---|---|---|
| `names` | | Space-separated; each `[a-z0-9][a-z0-9-]*`. |
| `version` | the commit's first 7 characters | What the host reports as the build. |
| `url`, `auth` | | The `publish` environment's secrets. `auth` is `<instance id>:<token>`, a `metrics:write` token. |

It fails the job when the report isn't accepted or the secrets are
missing (a job outside the environment, or not on the default branch),
and never prints the endpoint or the credentials.

## Configuration

Each tool takes, in order: the workflow's `*-config` input; the
repository's own file where the tool looks for it (the tables above; for
golangci-lint, `.golangci.{yml,yaml,toml,json}` in the module); else the
default here in [configs/](configs/). A repository's file replaces the
default entirely, so start from a copy of it to extend it. ruff,
shellcheck and osv-scanner have no defaults here: their own defaults
apply.

## Tool versions

Every version is pinned here, in a file Dependabot updates (Dependabot
does not update `docker run` or `uses: docker://` references in
workflows, so the images are listed as Dockerfile stages):

| What | Pinned in | Dependabot ecosystem |
|---|---|---|
| actionlint, zizmor, shellcheck, hadolint, ruff, osv-scanner, uv, node, tofu, tflint | [tools/Dockerfile](tools/Dockerfile) (`tag@sha256`) | `docker` |
| golangci-lint, govulncheck | [tools/go/go.mod](tools/go/go.mod) (`tool` directives) | `gomod` |
| ansible-lint | [tools/ansible/uv.lock](tools/ansible/uv.lock) | `uv` |
| actions | the workflows (full SHA, `# vX.Y.Z`) | `github-actions` |

The workflows fetch this repository at their own commit
(`job.workflow_sha`), so a caller's pin fixes the workflows, the scripts,
the default configurations and every tool version together.

## Releasing

Merge to `main`, then push a signed tag `vX.Y.Z` on the merge commit
(`git tag -s`). Dependabot proposes it to the callers. A change that
makes a check stricter is a minor version; one that needs callers to
change (an input renamed, a Dockerfile requirement) is a major version.

## Layout

- `.github/workflows/`: `go.yml`, `lint.yml`, and `ci.yml` (this
  repository's CI: lint.yml on itself, go.yml in both modes against
  `testdata/gosvc` on both architectures, and `scripts/selftest.sh`).
- `scripts/`: what the workflows run; `selftest.sh` tests their failure
  paths.
- `report-publish/`: the action and its script (tested by `selftest.sh`
  against a local listener).
- `configs/`: the default tool configurations.
- `tools/`: the tool version pins.
- `testdata/`: fixtures CI runs the workflows against.
- `examples/ci.yaml`: a caller.

# The fixture service's image, in the shape go.yml expects: a Go build
# stage pinned by digest, a `test` target that is that stage (go.yml runs
# the checks inside it, in its WORKDIR), and a distroless runtime.
FROM golang:1.27.4@sha256:205c7636d74e0ffbe3d007162df7d74f859f5a8c8322dfb9f907977686c126cf AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /gosvc .

FROM build AS test

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /gosvc /gosvc
USER nonroot:nonroot
ENTRYPOINT ["/gosvc"]

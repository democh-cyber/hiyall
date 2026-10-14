// Package buildinfo carries what the build stamps into the binary, for the startup log and the
// hiyall_build_info metric. The image build sets them with -ldflags (see services/api/Dockerfile):
//
//	go build -ldflags "-X hiyall/services/api/internal/buildinfo.Commit=$(git rev-parse --short=12 HEAD) \
//	                   -X hiyall/services/api/internal/buildinfo.Version=1.0.0" ./cmd/api
//
// An unstamped build (go run, go test) reports "unknown" and "dev".
package buildinfo

// Commit is the git commit the binary was built from; Version is the release name.
var (
	Commit  = "unknown"
	Version = "dev"
)

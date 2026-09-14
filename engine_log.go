package main

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// logFactKind identifies what, if anything, a single engine log line told us.
// Parsing is split into two stages on purpose: parseLogLine below extracts a
// stateless "fact" from one line using patterns verified against UxPlay's
// actual source (github.com/leapbtw/libuxplay, uxplay.cpp), and the Engine
// (engine.go) turns a sequence of facts into stateful status transitions.
// Keeping extraction stateless makes it trivially unit-testable without a
// running engine or a real iPhone.
type logFactKind int

const (
	factNone logFactKind = iota
	factEngineReady
	factConnectionRequest
	factOpenConnections
	factVideoReceived
	factStreaming
	factVideoStopped
	factReceiverNotice
	factWarning
	factFatalError
)

type logFact struct {
	kind            logFactKind
	timestamp       time.Time
	hasTimestamp    bool
	openConnections int
	deviceName      string
	deviceModel     string
	message         string
}

// Native lifecycle markers come from the maintained receiver patches;
// connection/socket messages come from pinned libuxplay.
//
//	MIRRORME_RECEIVER_READY port=N (only after both Bonjour registrations)
//	LOGI("connection request from %s (%s) with deviceID = %s\n", name, model, deviceid)
//	LOGD("Open connections: %i", open_connections)              // conn_init / conn_destroy
//	MIRRORME_VIDEO_RECEIVED (encoded buffer accepted, not yet displayed)
//	MIRRORME_STREAMING (a real video sink reports a rendered frame)
//	MIRRORME_VIDEO_STOPPED
//	LOGI("*** ERROR lost connection with client (network problem?)")
//	LOGE("dnssd_register_raop failed ...") / LOGE("dnssd_register_airplay failed ...")
//	LOGE("Could not initialize dnssd library!...")
//
// The LOGD lines are only emitted when the engine is launched with "-d 1",
// which the Engine supervisor always includes (see buildEngineArgs) so that
// connect/disconnect transitions are observable without also enabling noisy
// per-packet debug output ("-d 1" suppresses that, per uxplay's own -d help
// text).
var (
	reEngineReady       = regexp.MustCompile(`^MIRRORME_RECEIVER_READY port=[1-9][0-9]{0,4}$`)
	reConnectionRequest = regexp.MustCompile(`connection request from (.+?) \((.+?)\) with deviceID`)
	reOpenConnections   = regexp.MustCompile(`Open connections: (\d+)`)
	reWarningLostConn   = regexp.MustCompile(`lost connection with client`)
	reFatalDNSSD        = regexp.MustCompile(`(?i)^MIRRORME_RECEIVER_ERROR\b|dnssd.*failed|could not initialize dnssd|no dns-sd server found`)
	reLogTimestamp      = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?)`)
)

// parseLogLine extracts a logFact from a single line of the engine's session
// output. It returns ok=false for lines that carry no state-relevant
// information (the vast majority of lines, e.g. GStreamer debug chatter).
func parseLogLine(line string) (logFact, bool) {
	if line == "" {
		return logFact{}, false
	}

	fact := logFact{}
	if ts, ok := extractLogTimestamp(line); ok {
		fact.timestamp = ts
		fact.hasTimestamp = true
	}
	// Production libuxplay prefixes LOGGER_ERR messages; offline probes and
	// adapter failures may emit the same protocol marker without that prefix.
	nativeError := strings.TrimPrefix(line, "*** ERROR: ")
	nativeWarning := strings.TrimPrefix(line, "*** WARNING: ")

	switch {
	case strings.HasPrefix(nativeWarning, "MIRRORME_RECEIVER_WARNING: "):
		fact.kind = factReceiverNotice
		fact.message = strings.TrimPrefix(nativeWarning, "MIRRORME_RECEIVER_WARNING: ")
	case reFatalDNSSD.MatchString(nativeError):
		fact.kind = factFatalError
		fact.message = strings.TrimSpace(strings.TrimPrefix(nativeError, "MIRRORME_RECEIVER_ERROR:"))
	case reWarningLostConn.MatchString(line):
		fact.kind = factWarning
		fact.message = line
	case reOpenConnections.MatchString(line):
		m := reOpenConnections.FindStringSubmatch(line)
		n, err := strconv.Atoi(m[1])
		if err != nil {
			return logFact{}, false
		}
		fact.kind = factOpenConnections
		fact.openConnections = n
	case reConnectionRequest.MatchString(line):
		m := reConnectionRequest.FindStringSubmatch(line)
		fact.kind = factConnectionRequest
		fact.deviceName = m[1]
		fact.deviceModel = m[2]
	case line == "MIRRORME_VIDEO_RECEIVED":
		fact.kind = factVideoReceived
	case line == "MIRRORME_STREAMING":
		fact.kind = factStreaming
	case line == "MIRRORME_VIDEO_STOPPED":
		fact.kind = factVideoStopped
	case reEngineReady.MatchString(line):
		fact.kind = factEngineReady
		fact.message = line
	default:
		return logFact{}, false
	}
	return fact, true
}

// Timestamps are optional; the background receiver emits unprefixed markers.
// Older saved diagnostic lines may include an ISO timestamp.
func extractLogTimestamp(line string) (time.Time, bool) {
	m := reLogTimestamp.FindStringSubmatch(line)
	if m == nil {
		return time.Time{}, false
	}
	layouts := []string{
		"2006-01-02T15:04:05.000",
		"2006-01-02T15:04:05,000",
		"2006-01-02T15:04:05",
		"2006-01-02 15:04:05.000",
		"2006-01-02 15:04:05",
	}
	for _, layout := range layouts {
		if t, err := time.ParseInLocation(layout, m[1], time.Local); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

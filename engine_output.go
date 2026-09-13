package main

import (
	"bytes"
	"strings"
	"sync"
)

const maxReceiverLine = 64 * 1024

// Process-pipe reads can split both lines and UTF-8 characters. Reassemble
// complete lines before parsing, with a bound for noisy decoder diagnostics.
type receiverOutput struct {
	mu         sync.Mutex
	pending    []byte
	discarding bool
	onLine     func(string)
}

func (o *receiverOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	size := len(p)
	for len(p) > 0 {
		newline := bytes.IndexByte(p, '\n')
		part := p
		if newline >= 0 {
			part = p[:newline]
		}
		if !o.discarding {
			if len(o.pending)+len(part) > maxReceiverLine {
				o.pending = nil
				o.discarding = true
			} else {
				o.pending = append(o.pending, part...)
			}
		}
		if newline < 0 {
			break
		}
		if !o.discarding {
			o.onLine(strings.TrimSuffix(string(o.pending), "\r"))
		}
		o.pending = nil
		o.discarding = false
		p = p[newline+1:]
	}
	return size, nil
}

func (o *receiverOutput) flush() {
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(o.pending) > 0 && !o.discarding {
		o.onLine(string(o.pending))
	}
	o.pending = nil
	o.discarding = false
}

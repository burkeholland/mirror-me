package main

import (
	"crypto/rand"
	"fmt"
	"math/big"
)

// generatePinCode returns a random 4-digit string ("0000"-"9999") used as
// the AirPlay connection PIN when the user enables "Require PIN to
// connect". It uses crypto/rand for unbiased digits; this is a
// convenience/privacy gate for a home network, not a security boundary.
func generatePinCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(10000))
	if err != nil {
		// crypto/rand failure is effectively unheard-of on Windows; fall
		// back to a fixed code rather than leaving PIN security silently
		// disabled.
		return "0000"
	}
	return fmt.Sprintf("%04d", n.Int64())
}

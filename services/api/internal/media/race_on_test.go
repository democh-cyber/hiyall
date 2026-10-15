//go:build race

package media

// The race detector instruments allocation and inflates heap figures, so the memory budget is only asserted in
// ordinary builds (the numbers in the deploy guide are from one).
const raceEnabled = true

package domain

import "time"

// UsernameChangeCooldown is how long a member must wait after changing their username before changing it
// again. Choosing the first real name over the generated one does not start it.
const UsernameChangeCooldown = 30 * 24 * time.Hour

// ErrUsernameCooldown is the 429 answered while the cooldown runs; it carries Retry-After (see RetryAfter).
var ErrUsernameCooldown = &PolicyError{429, "USERNAME_COOLDOWN", "You changed your username recently. You can change it again later."}

package domain

// Nearby probing limits. A search is centred on the member's own stored point, so finding someone by
// triangulation means moving that point to many places and searching from each. Moving is already capped
// (DailyLocationChanges, a plausible speed); these caps count the distinct centres actually searched from in
// one UTC day, per account and per source address, so a handful of accounts behind one address cannot add up
// to a survey either.
const (
	// NearbyCentresPerAccount is how many different centres one account may search from in a day.
	NearbyCentresPerAccount = 10
	// NearbyCentresPerAddress is the same per source address, for every account behind it (a household or a
	// mobile carrier's NAT shares one).
	NearbyCentresPerAddress = 30
	// DailyNearbyCentres is the kind named in the 429 DAILY_LIMIT answer.
	DailyNearbyCentres = "nearby_centres"
)

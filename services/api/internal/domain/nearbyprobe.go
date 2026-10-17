package domain

// Nearby probing limits. A search is centred on the member's own stored point, so finding someone by
// triangulation means moving that point to many places and searching from each. Moving is already capped
// (DailyLocationChanges, a plausible speed). Two counts sit on top, both per UTC day:
//
//   - per account, the distinct centres searched from. An ordinary account reaches at most
//     DailyLocationChanges+1 centres in a day, so the cap is set above that and only a client that moves its
//     point by other means is stopped by it;
//   - per source address, the distinct ACCOUNTS that searched. Counting centres per address (the first
//     version) stopped a school, an office or a mobile carrier's NAT from using Nearby at all while a script
//     using one account per /64 sailed through. Counting accounts lets a shared network work and still stops
//     one address from driving a farm of accounts. An IPv6 address counts as its /64, an IPv4 address as itself
//     (clientip.Bucket).
const (
	// NearbyCentresPerAccount is how many different centres one account may search from in a day. The five
	// location changes a day (DailyLocationChanges) reach six; the rest is headroom for a day boundary.
	NearbyCentresPerAccount = 12
	// DefaultNearbyAccountsPerAddress is how many different accounts one source address (an IPv6 /64) may
	// search from in a day (NEARBY_ACCOUNTS_PER_ADDRESS). Generous on purpose: a carrier's CGNAT or a campus
	// puts thousands of people behind one address, and this is a ceiling against account farms, not a quota.
	DefaultNearbyAccountsPerAddress = 500
	// DailyNearbyCentres is the kind named in the 429 DAILY_LIMIT answer for the per-account cap, and
	// DailyNearbyAddress for the per-address one.
	DailyNearbyCentres = "nearby_centres"
	DailyNearbyAddress = "nearby_address"
)

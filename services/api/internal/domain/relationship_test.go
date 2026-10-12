package domain

import "testing"

// "followers" admits the viewer who follows the owner (Following is the viewer's own follow on the owner)
// and friends; a pending request, the owner following the viewer, and strangers are not admitted.
func TestFollowersAudienceMeansTheViewerFollowsTheOwner(t *testing.T) {
	for _, c := range []struct {
		name string
		rel  Relationship
		want map[string]bool
	}{
		{"stranger", Relationship{Following: "none", Friendship: "none"}, map[string]bool{"everyone": true, "public": true, "followers": false, "friends": false, "nobody": false, "approval": false}},
		{"active follower", Relationship{Following: "active", Friendship: "none"}, map[string]bool{"everyone": true, "followers": true, "friends": false, "nobody": false}},
		{"pending request", Relationship{Following: "pending", Friendship: "none"}, map[string]bool{"everyone": true, "followers": false, "friends": false}},
		{"followed by the owner only", Relationship{Following: "none", FollowedBy: true, Friendship: "none"}, map[string]bool{"everyone": true, "followers": false, "friends": false}},
		{"friend", Relationship{Following: "none", Friendship: "accepted"}, map[string]bool{"followers": true, "friends": true, "nobody": false}},
		{"pending friend request", Relationship{Following: "none", Friendship: "pending_incoming"}, map[string]bool{"followers": false, "friends": false}},
	} {
		for audience, want := range c.want {
			if got := c.rel.Allows(audience); got != want {
				t.Errorf("%s: Allows(%q) = %v, want %v", c.name, audience, got, want)
			}
		}
	}
}

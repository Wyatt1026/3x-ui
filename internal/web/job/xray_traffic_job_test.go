package job

import (
	"reflect"
	"testing"
	"time"

	"github.com/mhsanaei/3x-ui/v3/internal/xray"
)

func TestFreshOnlineAPIEmailsDropsStaleGhost(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	users := []xray.OnlineUser{{
		Email: "ghost",
		IPs: []xray.OnlineIP{{
			IP:       "203.0.113.10",
			LastSeen: now.Add(-onlineAPIStaleAfter - time.Second).Unix(),
		}},
	}}

	if got := freshOnlineAPIEmails(users, nil, now); len(got) != 0 {
		t.Fatalf("stale API-only online entry must not be refreshed forever, got %v", got)
	}
}

func TestFreshOnlineAPIEmailsKeepsRecentAndUnknownTimestamps(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	users := []xray.OnlineUser{
		{
			Email: "recent",
			IPs: []xray.OnlineIP{{
				IP:       "203.0.113.11",
				LastSeen: now.Add(-onlineAPIStaleAfter + time.Second).Unix(),
			}},
		},
		{
			Email: "unknown-clock",
			IPs: []xray.OnlineIP{{
				IP:       "203.0.113.12",
				LastSeen: 0,
			}},
		},
	}

	got := freshOnlineAPIEmails(users, nil, now)
	want := []string{"recent", "unknown-clock"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("fresh API entries not preserved\ngot:  %v\nwant: %v", got, want)
	}
}

func TestFreshOnlineAPIEmailsSkipsAlreadyActiveAndEmptyIPs(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	users := []xray.OnlineUser{
		{
			Email: "delta-user",
			IPs: []xray.OnlineIP{{
				IP:       "203.0.113.13",
				LastSeen: now.Unix(),
			}},
		},
		{
			Email: "empty-ip",
			IPs: []xray.OnlineIP{{
				LastSeen: now.Unix(),
			}},
		},
	}

	got := freshOnlineAPIEmails(users, map[string]bool{"delta-user": true}, now)
	if len(got) != 0 {
		t.Fatalf("helper should only return extra API-only emails, got %v", got)
	}
}

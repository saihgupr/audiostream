package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestPersistentIDStable(t *testing.T) {
	first := persistentID("Album/01 - Song.m4a")
	second := persistentID("Album/01 - Song.m4a")
	if first == 0 {
		t.Fatal("persistentID returned 0")
	}
	if first != second {
		t.Fatalf("persistentID is not stable: %d != %d", first, second)
	}
	if persistentID("Album/02 - Other.m4a") == first {
		t.Fatal("different paths produced the same persistentID")
	}
}

func TestExtractTrackNumber(t *testing.T) {
	cases := map[string]int{
		"05 - Song.m4a":       5,
		"1-01 Intro.m4a":      1,
		"Track 03 Song.m4a":   3,
		"Song Without Number": 0,
	}
	for name, want := range cases {
		if got := extractTrackNumber(name); got != want {
			t.Errorf("extractTrackNumber(%q) = %d, want %d", name, got, want)
		}
	}
}

func TestFormatDuration(t *testing.T) {
	cases := map[float64]string{
		0:     "0:00",
		65:    "1:05",
		3599:  "59:59",
		3600:  "60:00",
		411.9: "6:52",
	}
	for seconds, want := range cases {
		if got := formatDuration(seconds); got != want {
			t.Errorf("formatDuration(%v) = %q, want %q", seconds, got, want)
		}
	}
}

func TestApplyMergeToTrack(t *testing.T) {
	albumGroups := []albumMergeGroup{{
		Members: []mergeIdentifier{
			{Title: "A Beautiful Lesson", Artist: "Bodhi Spirit"},
			{Title: "The Heart of the Tree", Artist: "Bodhi Spirit"},
		},
		TargetTitle:  "The Heart of the Tree",
		TargetArtist: "Bodhi Spirit",
	}}
	artistGroups := []artistMergeGroup{{
		Members:      []string{"Bodhi Spirit"},
		TargetArtist: "Bodhi",
	}}
	albumIndex := buildAlbumMergeIndex(albumGroups)
	artistIndex := buildArtistMergeIndex(artistGroups)
	got := applyMergeToTrack(APITrack{
		Album:  "A Beautiful Lesson",
		Artist: "Bodhi Spirit",
	}, albumIndex, artistIndex)
	if got.Album != "The Heart of the Tree" {
		t.Fatalf("album = %q, want %q", got.Album, "The Heart of the Tree")
	}
	if got.Artist != "Bodhi" {
		t.Fatalf("artist = %q, want %q", got.Artist, "Bodhi")
	}
}

func TestHandleStatusIncludesLastSync(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "sync-status.json"), []byte(`{"result":"ok","lastSuccess":"2026-11-08T19:19:51Z"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	s := &Server{dataDir: dir, entries: []CacheEntry{{}, {}}}
	req := httptest.NewRequest(http.MethodGet, "/api/status", nil)
	rec := httptest.NewRecorder()
	s.handleStatus(rec, req)

	var got struct {
		Status   string         `json:"status"`
		Songs    int            `json:"songsCount"`
		LastSync map[string]any `json:"lastSync"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if got.Status != "ok" || got.Songs != 2 {
		t.Fatalf("unexpected status: %+v", got)
	}
	if got.LastSync["result"] != "ok" {
		t.Fatalf("lastSync missing or wrong: %+v", got.LastSync)
	}
}

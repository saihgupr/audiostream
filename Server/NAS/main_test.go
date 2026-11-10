package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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

func TestWebUIMatchesSwiftSource(t *testing.T) {
	// The player HTML has one source of truth, the Swift string the iPhone
	// daemon compiles in. web/index.html is generated from it, so a mismatch
	// means someone edited one copy and forgot the other.
	src, err := os.ReadFile(filepath.Join("..", "Core", "MusicServerHTML.swift"))
	if err != nil {
		t.Fatalf("read Swift source: %v", err)
	}
	marker := "public static let content = \"\"\"\n"
	start := bytes.Index(src, []byte(marker))
	if start < 0 {
		t.Fatal("MusicServerHTML.content not found")
	}
	rest := src[start+len(marker):]
	end := bytes.LastIndex(rest, []byte("\n\"\"\""))
	if end < 0 {
		t.Fatal("unterminated Swift string")
	}
	want := append(append([]byte{}, rest[:end]...), '\n')
	if !bytes.Equal(want, webIndex) {
		t.Fatalf("web/index.html is stale (%d bytes, Swift source is %d); run ./sync_web_ui.sh", len(webIndex), len(want))
	}
}

func TestRootServesWebUI(t *testing.T) {
	s := &Server{}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	s.handleRoot(rec, req)

	if got := rec.Header().Get("Content-Type"); !strings.HasPrefix(got, "text/html") {
		t.Fatalf("Content-Type = %q, want text/html", got)
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("<!DOCTYPE html>")) {
		t.Fatal("response is not the player page")
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("/api/songs")) {
		t.Fatal("player page does not reference the library API")
	}
}

func TestRootGzipMatchesPlain(t *testing.T) {
	s := &Server{}

	plainReq := httptest.NewRequest(http.MethodGet, "/", nil)
	plainRec := httptest.NewRecorder()
	s.handleRoot(plainRec, plainReq)

	gzReq := httptest.NewRequest(http.MethodGet, "/", nil)
	gzReq.Header.Set("Accept-Encoding", "gzip")
	gzRec := httptest.NewRecorder()
	s.handleRoot(gzRec, gzReq)

	if got := gzRec.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("Content-Encoding = %q, want gzip", got)
	}
	if gzRec.Body.Len() >= plainRec.Body.Len() {
		t.Fatalf("gzip body (%d) is not smaller than plain (%d)", gzRec.Body.Len(), plainRec.Body.Len())
	}
	zr, err := gzip.NewReader(bytes.NewReader(gzRec.Body.Bytes()))
	if err != nil {
		t.Fatalf("gzip reader: %v", err)
	}
	got, err := io.ReadAll(zr)
	if err != nil {
		t.Fatalf("gunzip: %v", err)
	}
	if !bytes.Equal(got, plainRec.Body.Bytes()) {
		t.Fatal("gzipped page does not round-trip to the plain page")
	}
}

func TestSongsGzipMatchesPlain(t *testing.T) {
	s := &Server{}
	s.rebuild([]CacheEntry{
		{APITrack: APITrack{ID: 1, Title: "One", Artist: "A", Album: "X"}, Path: "X/01 One.m4a"},
		{APITrack: APITrack{ID: 2, Title: "Two", Artist: "A", Album: "X"}, Path: "X/02 Two.m4a"},
	})

	plainRec := httptest.NewRecorder()
	s.handleSongs(plainRec, httptest.NewRequest(http.MethodGet, "/api/songs", nil))

	gzReq := httptest.NewRequest(http.MethodGet, "/api/songs", nil)
	gzReq.Header.Set("Accept-Encoding", "gzip, deflate, br")
	gzRec := httptest.NewRecorder()
	s.handleSongs(gzRec, gzReq)

	if got := gzRec.Header().Get("Content-Encoding"); got != "gzip" {
		t.Fatalf("Content-Encoding = %q, want gzip", got)
	}
	zr, err := gzip.NewReader(bytes.NewReader(gzRec.Body.Bytes()))
	if err != nil {
		t.Fatalf("gzip reader: %v", err)
	}
	got, err := io.ReadAll(zr)
	if err != nil {
		t.Fatalf("gunzip: %v", err)
	}
	if !bytes.Equal(got, plainRec.Body.Bytes()) {
		t.Fatal("gzipped songs JSON does not round-trip")
	}
}

func TestAcceptsGzip(t *testing.T) {
	cases := map[string]bool{
		"":                     false,
		"gzip":                 true,
		"gzip, deflate, br":    true,
		"deflate":              false,
		"br;q=1.0, gzip;q=0.8": true,
	}
	for header, want := range cases {
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		if header != "" {
			req.Header.Set("Accept-Encoding", header)
		}
		if got := acceptsGzip(req); got != want {
			t.Errorf("acceptsGzip(%q) = %v, want %v", header, got, want)
		}
	}
}

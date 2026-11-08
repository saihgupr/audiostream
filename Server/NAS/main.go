package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dhowden/tag"
)

const (
	libraryVersion = 1
	audioM4A       = ".m4a"
	audioMP3       = ".mp3"
	audioFLAC      = ".flac"
	audioWAV       = ".wav"
	audioAIFF      = ".aiff"
	audioAAC       = ".aac"
)

var trackNumberPattern = regexp.MustCompile(`(?i)^(?:(\d{1,3})[.\-_](\d{1,3})|(?:track|trk)?\s*(\d{1,3}))`)

type APITrack struct {
	ID                int64   `json:"id"`
	PersistentID      string  `json:"persistentId"`
	Title             string  `json:"title"`
	Artist            string  `json:"artist"`
	Album             string  `json:"album"`
	Filename          string  `json:"filename"`
	Duration          float64 `json:"duration"`
	DurationFormatted string  `json:"durationFormatted"`
	DateAdded         float64 `json:"dateAdded"`
	TrackNumber       int     `json:"trackNumber,omitempty"`
}

type CacheEntry struct {
	APITrack
	Path    string `json:"path"`
	ModTime int64  `json:"modTime"`
	Size    int64  `json:"size"`
}

type LibraryCache struct {
	Version   int          `json:"version"`
	ScannedAt time.Time    `json:"scannedAt"`
	Tracks    []CacheEntry `json:"tracks"`
}

type Server struct {
	musicDir string
	dataDir  string

	mu        sync.RWMutex
	entries   []CacheEntry
	byPID     map[uint64]*CacheEntry
	byID      map[int64]*CacheEntry
	songsJSON []byte
	pingJSON  []byte

	scanMu sync.Mutex
}

func main() {
	musicDir := flag.String("music", "/music", "music library root")
	dataDir := flag.String("data", "/var/lib/music-server", "cache and artwork directory")
	addr := flag.String("addr", ":18080", "listen address")
	flag.Parse()

	if err := os.MkdirAll(*dataDir, 0755); err != nil {
		log.Fatalf("data dir: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(*dataDir, "artwork"), 0755); err != nil {
		log.Fatalf("artwork dir: %v", err)
	}

	s := &Server{musicDir: *musicDir, dataDir: *dataDir}
	if !s.loadCache() {
		s.scan()
	} else {
		go s.scan()
	}
	go s.periodicScan(10 * time.Minute)

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleRoot)
	mux.HandleFunc("/api/ping", s.handlePing)
	mux.HandleFunc("/api/status", s.handlePing)
	mux.HandleFunc("/api/songs", s.handleSongs)
	mux.HandleFunc("/api/playlists", s.handlePlaylists)
	mux.HandleFunc("/api/rescan", s.handleRescan)
	mux.HandleFunc("/api/refresh", s.handleRescan)
	mux.HandleFunc("/api/delete", s.handleDelete)
	mux.HandleFunc("/music/", s.handleMusic)
	mux.HandleFunc("/artwork/", s.handleArtwork)

	log.Printf("AudioStream NAS listening on %s (music=%s, data=%s)", *addr, *musicDir, *dataDir)
	server := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}

func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintln(w, "AudioStream NAS is running.")
}

func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	data := s.pingJSON
	s.mu.RUnlock()
	writeJSON(w, data)
}

func (s *Server) handleSongs(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("refresh") == "true" || r.URL.Query().Get("refresh") == "1" {
		s.scan()
	}
	s.mu.RLock()
	data := s.songsJSON
	s.mu.RUnlock()
	writeJSON(w, data)
}

func (s *Server) handlePlaylists(w http.ResponseWriter, r *http.Request) {
	// The iOS client builds Recently Added / Month / 3 Months / 6 Months /
	// Year playlists itself from dateAdded. Custom playlists can be added here
	// later if they need to be shared across devices.
	writeJSON(w, []byte("[]"))
}

func (s *Server) handleRescan(w http.ResponseWriter, r *http.Request) {
	s.scan()
	s.mu.RLock()
	count := len(s.entries)
	s.mu.RUnlock()
	body, _ := json.Marshal(map[string]any{"status": "ok", "songsCount": count})
	writeJSON(w, body)
}

func (s *Server) handleDelete(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusForbidden)
	fmt.Fprint(w, `{"success":false,"error":"This library is a read-only mirror of the iPhone. Delete from the source device."}`)
}

func (s *Server) handleMusic(w http.ResponseWriter, r *http.Request) {
	rel := strings.TrimPrefix(r.URL.Path, "/music/")
	if rel == "" {
		http.NotFound(w, r)
		return
	}
	// The iOS app historically percent-encoded the path twice. net/http has
	// already decoded it once, so try the decoded form as a fallback. This
	// keeps older app builds working while new clients send a single encoding.
	candidates := []string{rel}
	if decoded, err := url.PathUnescape(rel); err == nil && decoded != rel {
		candidates = append(candidates, decoded)
	}

	root := filepath.Clean(s.musicDir)
	full := ""
	for _, candidate := range candidates {
		clean := filepath.Clean("/" + candidate)
		candidateFull := filepath.Join(s.musicDir, clean)
		if candidateFull != root && !strings.HasPrefix(candidateFull, root+string(os.PathSeparator)) {
			continue
		}
		info, err := os.Stat(candidateFull)
		if err == nil && !info.IsDir() {
			full = candidateFull
			break
		}
	}
	if full == "" {
		log.Printf("music not found: path=%q", r.URL.Path)
		http.NotFound(w, r)
		return
	}
	switch strings.ToLower(filepath.Ext(full)) {
	case ".m4a", ".aac":
		w.Header().Set("Content-Type", "audio/mp4")
	case ".mp3":
		w.Header().Set("Content-Type", "audio/mpeg")
	case ".flac":
		w.Header().Set("Content-Type", "audio/flac")
	}
	w.Header().Set("Cache-Control", "public, max-age=86400")
	http.ServeFile(w, r, full)
}

func (s *Server) handleArtwork(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/artwork/")
	pid, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		http.NotFound(w, r)
		return
	}

	s.mu.RLock()
	entry := s.byPID[pid]
	s.mu.RUnlock()
	if entry == nil {
		http.NotFound(w, r)
		return
	}
	fullPath := filepath.Join(s.musicDir, filepath.FromSlash(entry.Path))

	cacheDir := filepath.Join(s.dataDir, "artwork")
	for _, ext := range []string{"jpg", "jpeg", "png", "gif", "webp"} {
		path := filepath.Join(cacheDir, fmt.Sprintf("%d.%s", pid, ext))
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			serveImage(w, r, path)
			return
		}
	}

	if _, _, data := extractEmbeddedArtwork(fullPath); len(data) > 0 {
		cachePath := filepath.Join(cacheDir, fmt.Sprintf("%d.%s", pid, extForData(data)))
		_ = os.WriteFile(cachePath, data, 0644)
		w.Header().Set("Content-Type", http.DetectContentType(data))
		w.Header().Set("Cache-Control", "public, max-age=86400")
		w.Write(data)
		return
	}

	if path := findFolderArtwork(fullPath); path != "" {
		serveImage(w, r, path)
		return
	}

	http.NotFound(w, r)
}

func serveImage(w http.ResponseWriter, r *http.Request, path string) {
	ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(path)), ".")
	w.Header().Set("Content-Type", mimeForExt(ext))
	w.Header().Set("Cache-Control", "public, max-age=86400")
	http.ServeFile(w, r, path)
}

func mimeForExt(ext string) string {
	switch strings.ToLower(ext) {
	case "jpg", "jpeg":
		return "image/jpeg"
	case "png":
		return "image/png"
	case "gif":
		return "image/gif"
	case "webp":
		return "image/webp"
	default:
		return "application/octet-stream"
	}
}

func extractEmbeddedArtwork(audioPath string) (path, ext string, data []byte) {
	f, err := os.Open(audioPath)
	if err != nil {
		return "", "", nil
	}
	defer f.Close()
	meta, err := tag.ReadFrom(f)
	if err != nil || meta == nil {
		return "", "", nil
	}
	pic := meta.Picture()
	if pic == nil || len(pic.Data) == 0 {
		return "", "", nil
	}
	ext = strings.TrimPrefix(strings.ToLower(pic.Ext), ".")
	if ext == "" {
		ext = "jpg"
	}
	return audioPath, ext, pic.Data
}

func extForData(data []byte) string {
	switch http.DetectContentType(data) {
	case "image/png":
		return "png"
	case "image/gif":
		return "gif"
	case "image/webp":
		return "webp"
	default:
		return "jpg"
	}
}

func findFolderArtwork(audioPath string) string {
	dir := filepath.Dir(audioPath)
	for _, name := range []string{
		"cover.jpg", "folder.jpg", "cover.jpeg", "folder.jpeg",
		"cover.png", "folder.png", "artwork.jpg", "artwork.png",
		"Cover.jpg", "Folder.jpg", "Cover.png", "Folder.png",
	} {
		path := filepath.Join(dir, name)
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, data []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Write(data)
}

func (s *Server) periodicScan(interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C {
		s.scan()
	}
}

func (s *Server) scan() {
	s.scanMu.Lock()
	defer s.scanMu.Unlock()

	start := time.Now()
	s.mu.RLock()
	known := make(map[string]CacheEntry, len(s.entries))
	for _, entry := range s.entries {
		known[entry.Path] = entry
	}
	s.mu.RUnlock()

	type candidate struct {
		path string
		rel  string
		info fs.FileInfo
	}
	var candidates []candidate

	err := filepath.WalkDir(s.musicDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		if strings.HasPrefix(name, ".") {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		if !isAudio(name) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		rel, err := filepath.Rel(s.musicDir, path)
		if err != nil {
			return nil
		}
		candidates = append(candidates, candidate{path: path, rel: filepath.ToSlash(rel), info: info})
		return nil
	})
	if err != nil {
		log.Printf("scan: walk: %v", err)
	}

	entries := make([]CacheEntry, len(candidates))
	workers := 4
	sem := make(chan struct{}, workers)
	var wg sync.WaitGroup
	for i, c := range candidates {
		if old, ok := known[c.rel]; ok && old.Size == c.info.Size() && old.ModTime == c.info.ModTime().Unix() {
			entries[i] = old
			entries[i].Path = c.rel
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(i int, c candidate) {
			defer wg.Done()
			defer func() { <-sem }()
			entries[i] = readEntry(c.path, c.rel, c.info)
		}(i, c)
	}
	wg.Wait()

	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Album != entries[j].Album {
			return strings.ToLower(entries[i].Album) < strings.ToLower(entries[j].Album)
		}
		if entries[i].TrackNumber != entries[j].TrackNumber {
			return entries[i].TrackNumber < entries[j].TrackNumber
		}
		return strings.ToLower(entries[i].Title) < strings.ToLower(entries[j].Title)
	})

	s.rebuild(entries)
	s.saveCache(entries)
	log.Printf("scan: %d tracks in %s", len(entries), time.Since(start).Round(time.Millisecond))
}

// rebuild applies the iPhone's album/artist merge groups to a copy of the
// track metadata, then swaps the in-memory index. The cached entries stay raw
// so a merge change only requires a rebuild, not a rescan.
func (s *Server) rebuild(entries []CacheEntry) {
	albumGroups, artistGroups := loadMergeGroups(s.dataDir)
	albumIndex := buildAlbumMergeIndex(albumGroups)
	artistIndex := buildArtistMergeIndex(artistGroups)

	apiTracks := make([]APITrack, len(entries))
	for i := range entries {
		apiTracks[i] = applyMergeToTrack(entries[i].APITrack, albumIndex, artistIndex)
	}
	sort.Slice(apiTracks, func(i, j int) bool {
		if apiTracks[i].Album != apiTracks[j].Album {
			return strings.ToLower(apiTracks[i].Album) < strings.ToLower(apiTracks[j].Album)
		}
		if apiTracks[i].TrackNumber != apiTracks[j].TrackNumber {
			return apiTracks[i].TrackNumber < apiTracks[j].TrackNumber
		}
		return strings.ToLower(apiTracks[i].Title) < strings.ToLower(apiTracks[j].Title)
	})

	songsJSON, _ := json.Marshal(apiTracks)
	pingJSON, _ := json.Marshal(map[string]any{
		"status":         "ok",
		"songsCount":     len(entries),
		"playlistsCount": 0,
		"version":        "1.0.0",
	})

	byPID := make(map[uint64]*CacheEntry, len(entries))
	byID := make(map[int64]*CacheEntry, len(entries))
	for i := range entries {
		pid, _ := strconv.ParseUint(entries[i].PersistentID, 10, 64)
		byPID[pid] = &entries[i]
		byID[entries[i].ID] = &entries[i]
	}

	s.mu.Lock()
	s.entries = entries
	s.byPID = byPID
	s.byID = byID
	s.songsJSON = songsJSON
	s.pingJSON = pingJSON
	s.mu.Unlock()
}

func readEntry(path, rel string, info fs.FileInfo) CacheEntry {
	ext := strings.ToLower(filepath.Ext(rel))
	title, artist, album := "", "", ""
	trackNumber := 0

	if f, err := os.Open(path); err == nil {
		if meta, err := tag.ReadFrom(f); err == nil && meta != nil {
			title = strings.TrimSpace(meta.Title())
			artist = strings.TrimSpace(meta.Artist())
			album = strings.TrimSpace(meta.Album())
			if n, _ := meta.Track(); n > 0 {
				trackNumber = n
			}
		}
		f.Close()
	}

	parts := strings.Split(rel, "/")
	if len(parts) >= 3 {
		if artist == "" {
			artist = strings.TrimSpace(parts[0])
		}
		if album == "" {
			album = strings.TrimSpace(parts[1])
		}
	} else if len(parts) == 2 {
		if album == "" {
			album = strings.TrimSpace(parts[0])
		}
		if artist == "" {
			artist = "Unknown Artist"
		}
	} else {
		if album == "" {
			album = strings.TrimSpace(filepath.Base(filepath.Dir(path)))
		}
		if artist == "" {
			artist = "Unknown Artist"
		}
	}

	if title == "" {
		base := filepath.Base(rel)
		title = strings.TrimSpace(strings.TrimSuffix(base, filepath.Ext(base)))
	}
	if artist == "" {
		artist = "Unknown Artist"
	}
	if album == "" || album == "." || album == "/" {
		album = "Unknown Album"
	}
	if trackNumber == 0 {
		trackNumber = extractTrackNumber(filepath.Base(rel))
	}

	duration := readDuration(path, ext)
	pid := persistentID(rel)
	id := int64(pid & 0x7FFFFFFFFFFFFFFF)
	if id == 0 {
		id = 1
	}

	return CacheEntry{
		APITrack: APITrack{
			ID:                id,
			PersistentID:      strconv.FormatUint(pid, 10),
			Title:             title,
			Artist:            artist,
			Album:             album,
			Filename:          rel,
			Duration:          duration,
			DurationFormatted: formatDuration(duration),
			DateAdded:         float64(info.ModTime().UnixNano()) / 1e9,
			TrackNumber:       trackNumber,
		},
		Path:    rel,
		ModTime: info.ModTime().Unix(),
		Size:    info.Size(),
	}
}

func isAudio(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case audioM4A, audioMP3, audioFLAC, audioWAV, audioAIFF, audioAAC:
		return true
	default:
		return false
	}
}

func extractTrackNumber(name string) int {
	match := trackNumberPattern.FindStringSubmatch(name)
	if len(match) == 0 {
		return 0
	}
	for i := 1; i < len(match); i++ {
		if match[i] == "" {
			continue
		}
		if n, err := strconv.Atoi(match[i]); err == nil && n > 0 {
			return n
		}
	}
	return 0
}

func readDuration(path, ext string) float64 {
	switch ext {
	case audioM4A, audioAAC:
		return m4aDuration(path)
	case audioMP3:
		return mp3Duration(path)
	default:
		return 0
	}
}

func m4aDuration(path string) float64 {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return 0
	}
	fileSize := stat.Size()

	for offset := int64(0); offset+8 <= fileSize; {
		var header [8]byte
		if _, err := f.ReadAt(header[:], offset); err != nil {
			return 0
		}
		size := int64(binary.BigEndian.Uint32(header[0:4]))
		boxType := string(header[4:8])
		headerSize := int64(8)

		if size == 1 {
			var extended [8]byte
			if _, err := f.ReadAt(extended[:], offset+8); err != nil {
				return 0
			}
			size = int64(binary.BigEndian.Uint64(extended[:]))
			headerSize = 16
		} else if size == 0 {
			size = fileSize - offset
		}

		if size < headerSize || offset+size > fileSize {
			return 0
		}
		if boxType == "moov" {
			if size > 50<<20 {
				return 0
			}
			payload := make([]byte, size-headerSize)
			if _, err := f.ReadAt(payload, offset+headerSize); err != nil {
				return 0
			}
			return parseMoovDuration(payload)
		}
		offset += size
	}
	return 0
}

func parseMoovDuration(moov []byte) float64 {
	for offset := 0; offset+8 <= len(moov); {
		size := int64(binary.BigEndian.Uint32(moov[offset : offset+4]))
		boxType := string(moov[offset+4 : offset+8])
		headerSize := int64(8)

		if size == 1 {
			if offset+16 > len(moov) {
				return 0
			}
			size = int64(binary.BigEndian.Uint64(moov[offset+8 : offset+16]))
			headerSize = 16
		} else if size == 0 {
			size = int64(len(moov) - offset)
		}

		if size < headerSize || int64(offset)+size > int64(len(moov)) {
			return 0
		}
		if boxType == "mvhd" {
			return parseMvhd(moov[offset+int(headerSize) : offset+int(size)])
		}
		offset += int(size)
	}
	return 0
}

func parseMvhd(payload []byte) float64 {
	if len(payload) < 4 {
		return 0
	}
	version := payload[0]
	if version == 1 {
		if len(payload) < 32 {
			return 0
		}
		timescale := binary.BigEndian.Uint32(payload[20:24])
		duration := binary.BigEndian.Uint64(payload[24:32])
		if timescale == 0 {
			return 0
		}
		return float64(duration) / float64(timescale)
	}
	if len(payload) < 20 {
		return 0
	}
	timescale := binary.BigEndian.Uint32(payload[12:16])
	duration := binary.BigEndian.Uint32(payload[16:20])
	if timescale == 0 {
		return 0
	}
	return float64(duration) / float64(timescale)
}

// mp3Duration estimates duration from the first valid frame header and the
// file size. This library only has one MP3, so an estimate is good enough.
func mp3Duration(path string) float64 {
	data, err := os.ReadFile(path)
	if err != nil || len(data) < 4 {
		return 0
	}
	bitrates := []int{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0}
	for i := 0; i+4 <= len(data); i++ {
		if data[i] != 0xFF || data[i+1]&0xE0 != 0xE0 {
			continue
		}
		version := (data[i+1] >> 3) & 0x03
		layer := (data[i+1] >> 1) & 0x03
		if version == 1 || layer == 0 {
			continue
		}
		bitrateIdx := int(data[i+2] >> 4)
		rateIdx := int((data[i+2] >> 2) & 0x03)
		if bitrateIdx == 0 || bitrateIdx == 15 || rateIdx == 3 {
			continue
		}
		bitrate := bitrates[bitrateIdx] * 1000
		if bitrate == 0 {
			continue
		}
		return float64(len(data)*8) / float64(bitrate)
	}
	return 0
}

func formatDuration(seconds float64) string {
	if seconds < 0 {
		seconds = 0
	}
	total := int(seconds + 0.5)
	return fmt.Sprintf("%d:%02d", total/60, total%60)
}

// persistentID matches the daemon's hash so artwork URLs stay stable if the
// same relative path is served by the iPhone or the NAS.
func persistentID(value string) uint64 {
	var hash uint64 = 5381
	for _, b := range []byte(value) {
		hash = 127*(hash&0x00FFFFFFFFFFFFFF) + uint64(b)
	}
	if hash == 0 {
		return 1
	}
	return hash
}

func (s *Server) loadCache() bool {
	data, err := os.ReadFile(filepath.Join(s.dataDir, "library.json"))
	if err != nil {
		return false
	}
	var cache LibraryCache
	if err := json.Unmarshal(data, &cache); err != nil || cache.Version != libraryVersion {
		return false
	}
	s.rebuild(cache.Tracks)
	log.Printf("loaded %d tracks from cache", len(cache.Tracks))
	return true
}

func (s *Server) saveCache(entries []CacheEntry) {
	cache := LibraryCache{
		Version:   libraryVersion,
		ScannedAt: time.Now().UTC(),
		Tracks:    entries,
	}
	data, err := json.Marshal(cache)
	if err != nil {
		log.Printf("cache marshal: %v", err)
		return
	}
	path := filepath.Join(s.dataDir, "library.json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		log.Printf("cache write: %v", err)
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		log.Printf("cache rename: %v", err)
	}
}

type mergeIdentifier struct {
	Title  string `json:"title"`
	Artist string `json:"artist"`
}

type albumMergeGroup struct {
	Members      []mergeIdentifier `json:"members"`
	TargetTitle  string            `json:"targetTitle"`
	TargetArtist string            `json:"targetArtist"`
}

type artistMergeGroup struct {
	Members      []string `json:"members"`
	TargetArtist string   `json:"targetArtist"`
}

type mergeTarget struct {
	title  string
	artist string
}

func loadMergeGroups(dataDir string) ([]albumMergeGroup, []artistMergeGroup) {
	var albums []albumMergeGroup
	if data, err := os.ReadFile(filepath.Join(dataDir, "mergegroups.json")); err == nil {
		if err := json.Unmarshal(data, &albums); err != nil {
			log.Printf("mergegroups.json: %v", err)
		}
	}
	var artists []artistMergeGroup
	if data, err := os.ReadFile(filepath.Join(dataDir, "artistmergegroups.json")); err == nil {
		if err := json.Unmarshal(data, &artists); err != nil {
			log.Printf("artistmergegroups.json: %v", err)
		}
	}
	return albums, artists
}

func buildAlbumMergeIndex(groups []albumMergeGroup) map[string]mergeTarget {
	index := make(map[string]mergeTarget)
	for _, group := range groups {
		for _, member := range group.Members {
			key := mergeKey(member.Title) + "|" + mergeKey(member.Artist)
			if _, exists := index[key]; !exists {
				index[key] = mergeTarget{title: group.TargetTitle, artist: group.TargetArtist}
			}
		}
	}
	return index
}

func buildArtistMergeIndex(groups []artistMergeGroup) map[string]string {
	index := make(map[string]string)
	for _, group := range groups {
		for _, member := range group.Members {
			key := mergeKey(member)
			if _, exists := index[key]; !exists {
				index[key] = group.TargetArtist
			}
		}
	}
	return index
}

func applyMergeToTrack(track APITrack, albumIndex map[string]mergeTarget, artistIndex map[string]string) APITrack {
	if len(albumIndex) > 0 {
		if target, ok := albumIndex[mergeKey(track.Album)+"|"+mergeKey(track.Artist)]; ok {
			track.Album = target.title
			track.Artist = target.artist
		}
	}
	if len(artistIndex) > 0 {
		parts := strings.Split(track.Artist, ",")
		seen := make(map[string]bool, len(parts))
		canonical := make([]string, 0, len(parts))
		for _, part := range parts {
			value := strings.TrimSpace(part)
			if mapped, ok := artistIndex[mergeKey(value)]; ok {
				value = mapped
			}
			key := mergeKey(value)
			if value == "" || seen[key] {
				continue
			}
			seen[key] = true
			canonical = append(canonical, value)
		}
		track.Artist = strings.Join(canonical, ", ")
	}
	return track
}

func mergeKey(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}

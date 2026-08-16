package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// gifPerPage is the page size asked of Klipy, fixed server-side so a client can't turn a
// search into a way to pull an unbounded page.
const gifPerPage = 24

// defaultKlipyTimeout bounds how long the proxy waits on Klipy when the Server wasn't given
// a shorter one (see Server.klipyTimeout).
const defaultKlipyTimeout = 5 * time.Second

// gifItem is one gif as the app renders it: a grid preview plus the full-resolution file to
// download and re-host. Nothing here ever carries the Klipy key.
type gifItem struct {
	ID            string `json:"id"`
	Title         string `json:"title"`
	PreviewURL    string `json:"previewUrl"`
	PreviewWidth  int    `json:"previewWidth"`
	PreviewHeight int    `json:"previewHeight"`
	GifURL        string `json:"gifUrl"`
	Width         int    `json:"width"`
	Height        int    `json:"height"`
}

type gifSearchResp struct {
	Gifs    []gifItem `json:"gifs"`
	HasNext bool      `json:"hasNext"`
}

// klipyResponse is the shape https://api.klipy.com/api/v1/{key}/gifs/{search,trending}
// answers with. Only the fields the proxy actually maps are named; everything else in the
// upstream payload is dropped rather than passed through.
type klipyResponse struct {
	Result bool `json:"result"`
	Data   struct {
		Data        []klipyItem `json:"data"`
		CurrentPage int         `json:"current_page"`
		PerPage     int         `json:"per_page"`
		HasNext     bool        `json:"has_next"`
	} `json:"data"`
}

type klipyItem struct {
	ID    int64  `json:"id"`
	Slug  string `json:"slug"`
	Title string `json:"title"`
	File  struct {
		HD klipyRendition `json:"hd"`
		MD klipyRendition `json:"md"`
		SM klipyRendition `json:"sm"`
	} `json:"file"`
}

// klipyRendition is one size tier of a gif, in each format Klipy offers. Only gif and webp
// are used by the proxy (webp for the picker's preview grid, gif for the eventual re-hosted
// attachment); jpg/mp4/webm ride along in the upstream response but are never read.
type klipyRendition struct {
	Gif  klipyMedia `json:"gif"`
	Webp klipyMedia `json:"webp"`
}

type klipyMedia struct {
	URL    string `json:"url"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}

// handleGifSearch answers a slim, keyless projection of Klipy's search (or, for an empty
// query, trending) results. Every response - success or failure - must never let the
// configured key reach the client: it lives only in the upstream request URL this handler
// builds, never in anything written back.
func (s *Server) handleGifSearch(w http.ResponseWriter, r *http.Request) {
	if s.cfg.KlipyKey == "" {
		writeErr(w, http.StatusServiceUnavailable, "gif search is not configured on this server")
		return
	}
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	page := 1
	if p := r.URL.Query().Get("page"); p != "" {
		if n, err := strconv.Atoi(p); err == nil && n > 0 {
			page = n
		}
	}
	endpoint := "trending"
	if q != "" {
		endpoint = "search"
	}

	ctx, cancel := context.WithTimeout(r.Context(), s.klipyTimeoutOrDefault())
	defer cancel()
	raw, err := s.fetchKlipy(ctx, endpoint, q, page)
	if err != nil {
		// Never fmt.Errorf the underlying error into the response: an http.Client failure
		// (e.g. a context-deadline message) embeds the full request URL, key included.
		writeErr(w, http.StatusBadGateway, "could not reach gif search")
		return
	}
	writeJSON(w, http.StatusOK, mapKlipyResponse(raw))
}

func (s *Server) klipyTimeoutOrDefault() time.Duration {
	if s.klipyTimeout > 0 {
		return s.klipyTimeout
	}
	return defaultKlipyTimeout
}

// fetchKlipy issues one call to Klipy's search or trending endpoint and decodes the raw
// response. The key travels only in the URL of this outbound request.
func (s *Server) fetchKlipy(ctx context.Context, endpoint, q string, page int) (klipyResponse, error) {
	var out klipyResponse
	base := strings.TrimRight(s.cfg.KlipyBaseURL, "/")
	url := base + "/api/v1/" + s.cfg.KlipyKey + "/gifs/" + endpoint

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return out, err
	}
	query := req.URL.Query()
	if q != "" {
		query.Set("q", q)
	}
	query.Set("page", strconv.Itoa(page))
	query.Set("per_page", strconv.Itoa(gifPerPage))
	req.URL.RawQuery = query.Encode()

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return out, errKlipyStatus
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return out, err
	}
	return out, nil
}

var errKlipyStatus = &klipyStatusError{}

// klipyStatusError marks a non-200 upstream response. A distinct type rather than
// fmt.Errorf, so nothing ever risks interpolating a response body (which, on some upstream
// error, could itself be an echo of the request URL) into the error string.
type klipyStatusError struct{}

func (*klipyStatusError) Error() string { return "klipy: non-200 response" }

// mapKlipyResponse projects Klipy's payload down to the slim shape the app renders, dropping
// the id's precision-losing float round-trip risk (kept as int64 throughout) along with
// everything the client doesn't need - most importantly the key, which never appears here
// because it was only ever part of the outbound request.
func mapKlipyResponse(raw klipyResponse) gifSearchResp {
	out := gifSearchResp{HasNext: raw.Data.HasNext, Gifs: make([]gifItem, 0, len(raw.Data.Data))}
	for _, item := range raw.Data.Data {
		gifURL, w, h := fullGif(item)
		if gifURL == "" {
			continue // nothing this client could attach; skip rather than emit a dead entry
		}
		previewURL, pw, ph := previewGif(item)
		if previewURL == "" {
			// No webp/gif preview rendition at all (shouldn't happen given gifURL above, but
			// the fallback chain in previewGif already covers it) - fall back to the full gif
			// so the grid still has something to show.
			previewURL, pw, ph = gifURL, w, h
		}
		out.Gifs = append(out.Gifs, gifItem{
			ID:            strconv.FormatInt(item.ID, 10),
			Title:         item.Title,
			PreviewURL:    previewURL,
			PreviewWidth:  pw,
			PreviewHeight: ph,
			GifURL:        gifURL,
			Width:         w,
			Height:        h,
		})
	}
	return out
}

// previewGif picks the picker grid's thumbnail: the smallest webp available (sm, then md),
// falling back through the gif renditions (sm, md, hd) for a source with no webp at all.
// Smallest-first keeps the grid light; the fallback chain is defensive against a rendition
// Klipy's response happens to omit for a given item.
func previewGif(item klipyItem) (url string, w, h int) {
	for _, m := range []klipyMedia{item.File.SM.Webp, item.File.MD.Webp,
		item.File.SM.Gif, item.File.MD.Gif, item.File.HD.Gif} {
		if m.URL != "" {
			return m.URL, m.Width, m.Height
		}
	}
	return "", 0, 0
}

// fullGif picks the file downloaded and re-hosted once a gif is chosen: the md rendition,
// falling back to hd, then sm, for a source missing that size.
func fullGif(item klipyItem) (url string, w, h int) {
	for _, m := range []klipyMedia{item.File.MD.Gif, item.File.HD.Gif, item.File.SM.Gif} {
		if m.URL != "" {
			return m.URL, m.Width, m.Height
		}
	}
	return "", 0, 0
}

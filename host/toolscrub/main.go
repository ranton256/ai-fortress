// ai-fortress-toolscrub: a small reverse proxy that strips server-side
// LLM tools from inbound Anthropic Messages API requests before they
// reach Bifrost.
//
// The fortress isolates the agent process at the network and syscall
// layers. It cannot, at those layers, isolate the model itself: when a
// client advertises Anthropic's server-side tools (web_search,
// web_fetch, code_execution, computer use) in the `tools` array of a
// Messages API request, the model can invoke them and the work happens
// on Anthropic's infrastructure. This proxy strips those tool
// definitions from inbound requests before forwarding to Bifrost,
// closing the channel at the proxy layer regardless of how the agent
// is configured.
//
// Bytes-in == bytes-out for any request that does not match a scrub
// path or has no server-side tools to strip; the JSON parser only runs
// when the URL path matches and the request body is JSON. Streaming
// responses (SSE) pass through unchanged.

package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strings"
)

type Config struct {
	Listen        string   `json:"listen"`
	Upstream      string   `json:"upstream"`
	ScrubPaths    []string `json:"scrub_paths"`
	DenyToolTypes []string `json:"deny_tool_types"`
	FailOpen      bool     `json:"fail_open"`
	LogStripped   bool     `json:"log_stripped"`
	MaxBodyBytes  int64    `json:"max_body_bytes"`
}

type compiledConfig struct {
	listen       string
	upstream     *url.URL
	scrubPaths   []string
	denyPatterns []*regexp.Regexp
	failOpen     bool
	logStripped  bool
	maxBodyBytes int64
}

func loadConfig(path string) (*compiledConfig, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	var c Config
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if c.Listen == "" {
		c.Listen = "127.0.0.1:4001"
	}
	if c.Upstream == "" {
		c.Upstream = "http://127.0.0.1:4000"
	}
	if c.MaxBodyBytes == 0 {
		c.MaxBodyBytes = 10 * 1024 * 1024 // 10 MB; legitimate Messages requests are well under this
	}
	u, err := url.Parse(c.Upstream)
	if err != nil {
		return nil, fmt.Errorf("parse upstream URL: %w", err)
	}
	patterns := make([]*regexp.Regexp, 0, len(c.DenyToolTypes))
	for _, p := range c.DenyToolTypes {
		re, err := regexp.Compile(p)
		if err != nil {
			return nil, fmt.Errorf("bad deny pattern %q: %w", p, err)
		}
		patterns = append(patterns, re)
	}
	return &compiledConfig{
		listen:       c.Listen,
		upstream:     u,
		scrubPaths:   c.ScrubPaths,
		denyPatterns: patterns,
		failOpen:     c.FailOpen,
		logStripped:  c.LogStripped,
		maxBodyBytes: c.MaxBodyBytes,
	}, nil
}

func (c *compiledConfig) shouldScrubPath(p string) bool {
	for _, prefix := range c.scrubPaths {
		if strings.HasPrefix(p, prefix) {
			return true
		}
	}
	return false
}

func (c *compiledConfig) typeIsDenied(t string) bool {
	for _, re := range c.denyPatterns {
		if re.MatchString(t) {
			return true
		}
	}
	return false
}

// scrubBody parses the JSON body, removes top-level tools[] entries
// whose .type matches the denylist, and returns the result.
//
// Returned values:
//
//	out      — the (possibly modified) body bytes. If nothing was
//	           stripped, out == in (the caller can rely on this for a
//	           byte-identical passthrough check).
//	stripped — types that were removed, in original order.
//	err      — non-nil only on JSON parse error.
//
// The caller decides what to do with (in, parse-error): forward
// unchanged (fail-open) or reject with 400 (fail-closed).
func (c *compiledConfig) scrubBody(in []byte) (out []byte, stripped []string, err error) {
	var doc map[string]any
	if err := json.Unmarshal(in, &doc); err != nil {
		return in, nil, err
	}
	tools, ok := doc["tools"].([]any)
	if !ok || len(tools) == 0 {
		return in, nil, nil
	}
	kept := make([]any, 0, len(tools))
	stripped = stripped[:0]
	for _, t := range tools {
		m, ok := t.(map[string]any)
		if !ok {
			kept = append(kept, t)
			continue
		}
		typ, _ := m["type"].(string)
		if typ != "" && c.typeIsDenied(typ) {
			stripped = append(stripped, typ)
			continue
		}
		kept = append(kept, t)
	}
	if len(stripped) == 0 {
		// Don't re-marshal — preserve byte-identical passthrough so
		// any downstream consumer (Bifrost) sees exactly what the
		// client sent.
		return in, nil, nil
	}
	doc["tools"] = kept
	out, err = json.Marshal(doc)
	if err != nil {
		return in, nil, fmt.Errorf("re-marshal scrubbed body: %w", err)
	}
	return out, stripped, nil
}

func (c *compiledConfig) handleRequest(rp *httputil.ReverseProxy, w http.ResponseWriter, r *http.Request) {
	// Fast path: not a scrub-target path, or not JSON, or not POST.
	if r.Method != http.MethodPost ||
		!strings.Contains(r.Header.Get("Content-Type"), "application/json") ||
		!c.shouldScrubPath(r.URL.Path) {
		rp.ServeHTTP(w, r)
		return
	}
	// Read body up to maxBodyBytes; oversized bodies pass through unscrubbed.
	body, err := io.ReadAll(io.LimitReader(r.Body, c.maxBodyBytes+1))
	r.Body.Close()
	if err != nil {
		http.Error(w, "read body: "+err.Error(), http.StatusBadGateway)
		return
	}
	if int64(len(body)) > c.maxBodyBytes {
		log.Printf("toolscrub: body exceeds max_body_bytes=%d for path=%s; forwarding unscrubbed", c.maxBodyBytes, r.URL.Path)
		// Forward unscrubbed.
		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
		rp.ServeHTTP(w, r)
		return
	}

	out, stripped, parseErr := c.scrubBody(body)
	if parseErr != nil {
		if c.failOpen {
			log.Printf("toolscrub: JSON parse failed (fail_open=true; forwarding unchanged): path=%s err=%v", r.URL.Path, parseErr)
		} else {
			http.Error(w, "scrub: malformed JSON", http.StatusBadRequest)
			return
		}
	}
	if len(stripped) > 0 && c.logStripped {
		log.Printf("toolscrub: stripped %d tool(s) path=%s types=%v", len(stripped), r.URL.Path, stripped)
	}
	r.Body = io.NopCloser(bytes.NewReader(out))
	r.ContentLength = int64(len(out))
	r.Header.Set("Content-Length", fmt.Sprintf("%d", len(out)))
	rp.ServeHTTP(w, r)
}

func main() {
	cfgPath := flag.String("config", "/etc/ai-fortress/toolscrub.json", "path to config file")
	flag.Parse()

	c, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("toolscrub: %v", err)
	}

	rp := httputil.NewSingleHostReverseProxy(c.upstream)
	// FlushInterval -1 makes the reverse proxy flush each write
	// immediately — necessary for SSE streaming to arrive token-by-token
	// instead of being buffered.
	rp.FlushInterval = -1

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		c.handleRequest(rp, w, r)
	})

	log.Printf("toolscrub: listen=%s upstream=%s scrub_paths=%v deny_patterns=%d fail_open=%v",
		c.listen, c.upstream, c.scrubPaths, len(c.denyPatterns), c.failOpen)

	srv := &http.Server{
		Addr:    c.listen,
		Handler: mux,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("toolscrub: %v", err)
	}
}

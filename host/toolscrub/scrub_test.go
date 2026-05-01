// Table-driven tests for the body-scrub logic. The HTTP-level proxying
// path is tested separately via verify-phase1.sh's integration tests;
// here we focus on the load-bearing question: given a JSON request
// body in, do we strip exactly the entries we should and preserve
// byte-for-byte everything else?

package main

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func mustConfig(t *testing.T) *compiledConfig {
	t.Helper()
	cfg := Config{
		Listen:   "127.0.0.1:4001",
		Upstream: "http://127.0.0.1:4000",
		ScrubPaths: []string{
			"/anthropic/v1/messages",
		},
		DenyToolTypes: []string{
			`^web_search_\d{8}$`,
			`^web_fetch_\d{8}$`,
			`^code_execution_\d{8}$`,
			`^computer_\d{8}$`,
		},
		FailOpen:    true,
		LogStripped: true,
	}
	raw, _ := json.Marshal(cfg)
	tmp := t.TempDir() + "/cfg.json"
	if err := bytesToFile(tmp, raw); err != nil {
		t.Fatal(err)
	}
	c, err := loadConfig(tmp)
	if err != nil {
		t.Fatalf("loadConfig: %v", err)
	}
	return c
}

func bytesToFile(p string, b []byte) error {
	return writeFile(p, b)
}

// import os.WriteFile via a helper to keep tests independent of the
// import order the linter prefers.
func writeFile(p string, b []byte) error {
	return osWriteFile(p, b, 0o644)
}

// Tests --------------------------------------------------------------

func TestScrubBody_NoToolsArray_BytesIdentical(t *testing.T) {
	c := mustConfig(t)
	in := []byte(`{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"hi"}],"max_tokens":50}`)
	out, stripped, err := c.scrubBody(in)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(stripped) != 0 {
		t.Fatalf("unexpected stripped: %v", stripped)
	}
	if &out[0] != &in[0] {
		t.Fatalf("expected pointer-identical body when nothing changed; got distinct slices")
	}
}

func TestScrubBody_EmptyToolsArray_BytesIdentical(t *testing.T) {
	c := mustConfig(t)
	in := []byte(`{"model":"x","tools":[],"messages":[]}`)
	out, stripped, err := c.scrubBody(in)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(stripped) != 0 || !bytes.Equal(out, in) || &out[0] != &in[0] {
		t.Fatalf("expected pointer-identical passthrough on empty tools[]")
	}
}

func TestScrubBody_OnlyClientTools_BytesIdentical(t *testing.T) {
	c := mustConfig(t)
	cases := []string{
		`{"tools":[{"type":"custom","name":"foo","input_schema":{}}]}`,
		`{"tools":[{"type":"function","function":{"name":"bar"}}]}`,
		`{"tools":[{"type":"text_editor_20250728","name":"str_replace_editor"}]}`,
		`{"tools":[{"type":"bash_20250124","name":"bash"}]}`,
		`{"tools":[{"type":"custom","name":"a"},{"type":"function","function":{"name":"b"}}]}`,
	}
	for i, in := range cases {
		t.Run(string(rune('a'+i)), func(t *testing.T) {
			out, stripped, err := c.scrubBody([]byte(in))
			if err != nil {
				t.Fatalf("err: %v", err)
			}
			if len(stripped) != 0 {
				t.Fatalf("unexpected stripped: %v", stripped)
			}
			if !bytes.Equal(out, []byte(in)) {
				t.Fatalf("expected unchanged; got %s", out)
			}
		})
	}
}

func TestScrubBody_AllServerSideFamilies_Stripped(t *testing.T) {
	c := mustConfig(t)
	cases := []struct {
		name   string
		typ    string
		family string
	}{
		{"web_search current", "web_search_20250305", "web_search"},
		{"web_search future-dated", "web_search_20260209", "web_search"},
		{"web_fetch current", "web_fetch_20250910", "web_fetch"},
		{"web_fetch future-dated", "web_fetch_20260209", "web_fetch"},
		{"code_execution current", "code_execution_20250825", "code_execution"},
		{"code_execution future-dated", "code_execution_20260120", "code_execution"},
		{"computer use 2025-01", "computer_20250124", "computer"},
		{"computer use 2025-11", "computer_20251124", "computer"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := []byte(`{"tools":[{"type":"` + tc.typ + `","name":"x"}]}`)
			out, stripped, err := c.scrubBody(body)
			if err != nil {
				t.Fatalf("err: %v", err)
			}
			if !reflect.DeepEqual(stripped, []string{tc.typ}) {
				t.Fatalf("expected stripped=[%s]; got %v", tc.typ, stripped)
			}
			// kept tools[] should be empty
			var parsed map[string]any
			if err := json.Unmarshal(out, &parsed); err != nil {
				t.Fatalf("re-parse: %v", err)
			}
			if tools, _ := parsed["tools"].([]any); len(tools) != 0 {
				t.Fatalf("expected empty tools[] after stripping; got %v", tools)
			}
		})
	}
}

func TestScrubBody_MixedServerAndClient_OnlyServerStripped(t *testing.T) {
	c := mustConfig(t)
	in := []byte(`{
		"model":"claude-sonnet-4-6",
		"tools":[
			{"type":"custom","name":"my_tool","input_schema":{}},
			{"type":"web_fetch_20250910","name":"web_fetch","max_uses":5},
			{"type":"function","function":{"name":"helper"}},
			{"type":"computer_20250124","name":"computer"},
			{"type":"text_editor_20250728","name":"str_replace_editor"}
		]
	}`)
	_, stripped, err := c.scrubBody(in)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	want := []string{"web_fetch_20250910", "computer_20250124"}
	if !reflect.DeepEqual(stripped, want) {
		t.Fatalf("stripped mismatch: got %v want %v", stripped, want)
	}
}

func TestScrubBody_KeptToolsRetainAllFields(t *testing.T) {
	c := mustConfig(t)
	// custom tool with nested input_schema and extra fields — those
	// must round-trip intact when the tool is kept.
	in := []byte(`{"tools":[{"type":"custom","name":"my_tool","description":"does a thing","input_schema":{"type":"object","properties":{"x":{"type":"string"}},"required":["x"]},"cache_control":{"type":"ephemeral"}}]}`)
	out, stripped, err := c.scrubBody(in)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(stripped) != 0 {
		t.Fatalf("unexpected stripped: %v", stripped)
	}
	if !bytes.Equal(out, in) {
		t.Fatalf("expected byte-identical when nothing stripped; got\n  in: %s\n out: %s", in, out)
	}
}

func TestScrubBody_MalformedJSON_ReturnsError(t *testing.T) {
	c := mustConfig(t)
	in := []byte(`{this is not valid json`)
	out, stripped, err := c.scrubBody(in)
	if err == nil {
		t.Fatalf("expected parse error")
	}
	if !bytes.Equal(out, in) || len(stripped) != 0 {
		t.Fatalf("on parse error, scrubBody must return the input unchanged and no stripped list")
	}
}

func TestScrubBody_TopLevelToolsIsNotArray_PassThrough(t *testing.T) {
	c := mustConfig(t)
	// some hypothetical client sends tools as an object, not an array;
	// don't crash, don't try to strip.
	in := []byte(`{"tools":{"unexpected":"shape"},"messages":[]}`)
	out, stripped, err := c.scrubBody(in)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(stripped) != 0 {
		t.Fatalf("unexpected stripped: %v", stripped)
	}
	if !bytes.Equal(out, in) {
		t.Fatalf("expected passthrough on non-array tools")
	}
}

func TestScrubBody_NoMatchingTools_BytesIdentical(t *testing.T) {
	c := mustConfig(t)
	// tools array with only types that don't match the denylist (and aren't dated).
	in := []byte(`{"tools":[{"type":"web_search","name":"undated"}]}`) // undated, doesn't match \d{8}$
	out, stripped, err := c.scrubBody(in)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(stripped) != 0 {
		t.Fatalf("undated %q should NOT match the regex; got stripped=%v", "web_search", stripped)
	}
	if !bytes.Equal(out, in) {
		t.Fatalf("expected byte-identical when nothing matched; got %s", out)
	}
}

func TestShouldScrubPath(t *testing.T) {
	c := mustConfig(t)
	cases := []struct {
		path   string
		expect bool
	}{
		{"/anthropic/v1/messages", true},
		{"/anthropic/v1/messages?stream=true", true}, // shouldScrubPath uses prefix on URL.Path which doesn't include query
		{"/api/governance/virtual-keys", false},
		{"/health", false},
		{"/openai/v1/chat/completions", false}, // not in scrubPaths in test config
	}
	for _, tc := range cases {
		got := c.shouldScrubPath(strings.SplitN(tc.path, "?", 2)[0])
		if got != tc.expect {
			t.Errorf("shouldScrubPath(%q): got %v want %v", tc.path, got, tc.expect)
		}
	}
}

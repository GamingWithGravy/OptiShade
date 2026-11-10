package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestChannelTemplateMatchesSignedComponentTargets(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "distribution", "channels.template.json"))
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Schema     int    `json:"schema"`
		Repository string `json:"repository"`
		Channels   map[string]struct {
			StableBranch string `json:"stableBranch"`
			BetaBranch   string `json:"betaBranch"`
			ComponentID  string `json:"componentId"`
			Manifest     string `json:"manifest"`
			Transport    string `json:"packageTransport"`
			MaximumBytes int64  `json:"maximumBytes"`
		} `json:"channels"`
	}
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	if config.Schema != 2 || config.Repository != "GamingWithGravy/OptiShade" {
		t.Fatalf("unexpected channel template identity: schema=%d repository=%q", config.Schema, config.Repository)
	}
	want := map[string]struct{ branch, component string }{
		"launcher":       {"launcher", "OptiShade.Launcher"},
		"core":           {"core", "OptiShade.Core"},
		"optimfg":        {"optimfg", "OptiShade.OptiMFG"},
		"effects":        {"effects", "OptiShade.Effects"},
		"providersAmd":   {"providers-amd", "OptiShade.Providers.AMD"},
		"providersIntel": {"providers-intel", "OptiShade.Providers.Intel"},
	}
	if len(config.Channels) != len(want) {
		t.Fatalf("channel template has %d entries, want exactly %d: %#v", len(config.Channels), len(want), config.Channels)
	}
	for name, expected := range want {
		channel, ok := config.Channels[name]
		if !ok {
			t.Errorf("channel template omits %s", name)
			continue
		}
		if channel.StableBranch != expected.branch+"-stable" || channel.BetaBranch != expected.branch+"-beta" || channel.ComponentID != expected.component || channel.Manifest != "channel.json" || channel.Transport != "github-raw" || channel.MaximumBytes <= 0 || channel.MaximumBytes > componentDownloadMaxBytes {
			t.Errorf("channel %s does not match the runtime release contract: %#v", name, channel)
		}
	}
}

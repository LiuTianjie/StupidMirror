package main

import "testing"

func TestParsePortMappings(t *testing.T) {
	mappings, err := parsePortMappings([]string{"8100", "9200:19200"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(mappings) != 2 {
		t.Fatalf("expected 2 mappings, got %d", len(mappings))
	}
	if mappings[0] != (portMapping{devicePort: 8100, localPort: 0}) {
		t.Fatalf("unexpected first mapping: %+v", mappings[0])
	}
	if mappings[1] != (portMapping{devicePort: 9200, localPort: 19200}) {
		t.Fatalf("unexpected second mapping: %+v", mappings[1])
	}
	for _, bad := range []string{"0", "70000", "abc", "8100:x", "8100:99999"} {
		if _, err := parsePortMappings([]string{bad}); err == nil {
			t.Errorf("expected %q to be rejected", bad)
		}
	}
}

func TestParseFlagsCollectsRepeatedAndSingleValues(t *testing.T) {
	f := parseFlags([]string{
		"--udid", "X", "--env", "A=1", "--env=B=2", "--tcp", "8100", "--watch-stdin", "on",
	}, "env", "tcp")
	if f.values["udid"] != "X" {
		t.Fatalf("udid not parsed: %+v", f.values)
	}
	if got := f.lists["env"]; len(got) != 2 || got[0] != "A=1" || got[1] != "B=2" {
		t.Fatalf("env list not parsed: %v", got)
	}
	if got := f.lists["tcp"]; len(got) != 1 || got[0] != "8100" {
		t.Fatalf("tcp list not parsed: %v", got)
	}
	if _, ok := f.values["watch-stdin"]; !ok {
		t.Fatalf("boolean flag not recorded: %+v", f.values)
	}
	if got := f.lists["_"]; len(got) != 1 || got[0] != "on" {
		t.Fatalf("positional argument not recorded: %v", got)
	}
}

package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestTouchDecoderRequiresCompleteBoundedInput(t *testing.T) {
	valid := `{"type":"touch","phase":"down","gesture_id":"g","seq":0,"x":0.2,"y":0.8,"device":"forged-device"}`
	if _, ok := decodeTouch([]byte(valid)); !ok {
		t.Fatal("valid touch rejected")
	}
	for _, input := range []string{
		`{"type":"touch","phase":"down","gesture_id":"g","seq":0,"y":0.8}`,
		`{"type":"touch","phase":"down","gesture_id":"g","seq":null,"x":0.2,"y":0.8}`,
		`{"type":"touch","phase":"move","gesture_id":"g","seq":-1,"x":0.2,"y":0.8}`,
		`{"type":"touch","phase":"move","gesture_id":"g","seq":1,"x":2,"y":0.8}`,
	} {
		if _, ok := decodeTouch([]byte(input)); ok {
			t.Fatalf("malformed input accepted: %s", input)
		}
	}
}

func TestTouchQueueSerializesDownMoveAndRelease(t *testing.T) {
	output := &bytes.Buffer{}
	touch := &touchPeer{}
	b := &bridge{output: output, peers: map[string]peer{"trusted-peer": {device: "trusted-device", touch: touch}}}
	makeTouch := func(phase string, seq int64) touchMessage {
		return touchMessage{Type: "touch", Phase: phase, GestureID: "finger", Sequence: seq, X: 0.2, Y: 0.8}
	}
	b.enqueueTouch("trusted-peer", makeTouch("down", 0))
	defer func() {
		if touch.timer != nil {
			touch.timer.Stop()
		}
	}()
	for i := int64(1); i <= 1000; i++ {
		b.enqueueTouch("trusted-peer", makeTouch("move", i))
	}
	b.enqueueTouch("trusted-peer", makeTouch("up", 1001))
	if len(touch.queue) != 2 || touch.queue[0].Sequence != 1000 || touch.queue[1].Phase != "up" {
		t.Fatalf("terminal event lost or moves unbounded: %+v", touch.queue)
	}
	var events []map[string]any
	for touch.inflight != nil {
		var event map[string]any
		if err := json.NewDecoder(output).Decode(&event); err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
		touch.timer.Stop()
		touch.inflight = nil
		b.dispatchTouchLocked("trusted-peer", touch)
	}
	if len(events) != 3 {
		t.Fatalf("expected down/latest move/up, got %d", len(events))
	}
	for i, phase := range []string{"down", "move", "up"} {
		if events[i]["peer"] != "trusted-peer" || events[i]["touch"].(map[string]any)["phase"] != phase {
			t.Fatalf("incorrect peer or order: %+v", events[i])
		}
		if _, ok := events[i]["device"]; ok {
			t.Fatal("touch route must be resolved by parent peer binding")
		}
	}
}

func TestTouchSequenceCannotReleaseAnotherGestureOrReplayDown(t *testing.T) {
	sequence := touchSequence{}
	message := func(phase, gesture string, seq int64) touchMessage {
		return touchMessage{Phase: phase, GestureID: gesture, Sequence: seq}
	}
	for _, event := range []touchMessage{message("down", "first", 0), message("move", "first", 4), message("up", "first", 5), message("down", "second", 0)} {
		if !sequence.accept(event) {
			t.Fatalf("ordered gesture rejected: %+v", event)
		}
	}
	for _, event := range []touchMessage{message("up", "first", 6), message("move", "second", 0), message("down", "third", 0)} {
		if sequence.accept(event) {
			t.Fatalf("stale/cross-gesture input accepted: %+v", event)
		}
	}
	if !sequence.accept(message("cancel", "second", 1)) {
		t.Fatal("valid release rejected")
	}
	if sequence.accept(message("down", "first", 0)) {
		t.Fatal("completed gesture was replayed")
	}
}

func TestScrollDecoderRequiresCompleteFiniteDeltasAndEmptyRelease(t *testing.T) {
	message := func(phase, scroll string) []byte {
		return []byte(`{"type":"touch","phase":"` + phase + `","gesture_id":"wheel","seq":0,"x":0.2,"y":0.8,"scroll":` + scroll + `}`)
	}
	for _, scroll := range []string{`{"delta_x":0,"delta_y":-12.5}`, `{"delta_x":1000000,"delta_y":0}`} {
		if _, ok := decodeTouch(message("down", scroll)); !ok {
			t.Fatalf("valid scroll rejected: %s", scroll)
		}
	}
	for _, scroll := range []string{
		`null`, `{}`, `{"delta_x":2}`, `{"delta_x":0,"delta_y":null}`,
		`{"delta_x":"2","delta_y":0}`, `{"delta_x":1e309,"delta_y":0}`,
		`{"delta_x":1000001,"delta_y":0}`, `{"delta_x":0,"delta_y":-1000001}`,
	} {
		if _, ok := decodeTouch(message("down", scroll)); ok {
			t.Fatalf("malformed scroll accepted: %s", scroll)
		}
	}
	for _, phase := range []string{"up", "cancel"} {
		if _, ok := decodeTouch(message(phase, `{"delta_x":0,"delta_y":1}`)); ok {
			t.Fatalf("release with motion accepted: %s", phase)
		}
		if _, ok := decodeTouch(message(phase, `{"delta_x":0,"delta_y":0}`)); !ok {
			t.Fatalf("empty release rejected: %s", phase)
		}
	}
}

func TestScrollSequenceCannotChangeInputType(t *testing.T) {
	sequence := touchSequence{}
	scroll := touchMessage{Phase: "down", GestureID: "wheel", Sequence: 0, Scroll: &touchScroll{DeltaY: 1}}
	if !sequence.accept(scroll) {
		t.Fatal("scroll start rejected")
	}
	for _, phase := range []string{"move", "up"} {
		if sequence.accept(touchMessage{Phase: phase, GestureID: "wheel", Sequence: 1}) {
			t.Fatalf("scroll changed to direct touch: %s", phase)
		}
	}
	if !sequence.accept(touchMessage{Phase: "cancel", GestureID: "wheel", Sequence: 1}) {
		t.Fatal("generic owner cancellation rejected")
	}
	if !sequence.accept(touchMessage{Phase: "down", GestureID: "finger", Sequence: 0}) {
		t.Fatal("next direct contact rejected")
	}
	if sequence.accept(touchMessage{Phase: "move", GestureID: "finger", Sequence: 1, Scroll: &touchScroll{DeltaY: 1}}) {
		t.Fatal("direct touch changed to scroll")
	}
}

func TestScrollQueuePreservesEveryRelativeIncrement(t *testing.T) {
	output := &bytes.Buffer{}
	touch := &touchPeer{}
	b := &bridge{output: output, peers: map[string]peer{"trusted-peer": {device: "trusted-device", touch: touch}}}
	makeScroll := func(phase string, seq int64, delta float64) touchMessage {
		return touchMessage{Type: "touch", Phase: phase, GestureID: "wheel", Sequence: seq, X: 0.2, Y: 0.8,
			Scroll: &touchScroll{DeltaY: delta}}
	}
	b.enqueueTouch("trusted-peer", makeScroll("down", 0, 1))
	defer func() {
		if touch.timer != nil {
			touch.timer.Stop()
		}
	}()
	b.enqueueTouch("trusted-peer", makeScroll("move", 1, 2))
	b.enqueueTouch("trusted-peer", makeScroll("move", 2, -3))
	b.enqueueTouch("trusted-peer", makeScroll("up", 3, 0))
	if len(touch.queue) != 3 || touch.queue[0].Scroll.DeltaY != 2 || touch.queue[1].Scroll.DeltaY != -3 || touch.queue[2].Phase != "up" {
		t.Fatalf("relative increments or release were merged: %+v", touch.queue)
	}
}

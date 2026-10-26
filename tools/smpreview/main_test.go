package main

import (
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

func TestLoopbackVideoAndPeerCleanup(t *testing.T) {
	b, err := newBridge()
	if err != nil {
		t.Fatal(err)
	}
	reader, writer := io.Pipe()
	b.output = writer
	defer reader.Close()
	defer writer.Close()
	messages := make(chan map[string]any, 32)
	go func() {
		decoder := json.NewDecoder(reader)
		for {
			var value map[string]any
			if decoder.Decode(&value) != nil {
				return
			}
			messages <- value
		}
	}()
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(true)
	browser, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer browser.Close()
	_, err = browser.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly})
	if err != nil {
		t.Fatal(err)
	}
	touch, err := browser.CreateDataChannel(touchChannelLabel, nil)
	if err != nil {
		t.Fatal(err)
	}
	touch.OnOpen(func() {
		_ = touch.SendText(`{"type":"touch","phase":"down","gesture_id":"loopback-finger","seq":0,"x":0.25,"y":0.75,"geometry_id":"1","device":"forged-phone"}`)
	})
	touch.OnMessage(func(message webrtc.DataChannelMessage) {
		var value map[string]any
		if json.Unmarshal(message.Data, &value) == nil && value["type"] == "ack" && value["accepted"] == true {
			_ = touch.Close()
		}
	})
	received := make(chan struct{}, 1)
	browser.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if _, _, err := track.ReadRTP(); err == nil {
			received <- struct{}{}
		}
	})
	offer, err := browser.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	done := webrtc.GatheringCompletePromise(browser)
	if err = browser.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("browser ICE timeout")
	}
	go b.offer(command{ID: "offer-1", Op: "offer", Peer: "peer-1", Device: "phone-1", SDP: browser.LocalDescription().SDP})
	var answer string
	deadline := time.After(10 * time.Second)
	for answer == "" {
		select {
		case message := <-messages:
			if message["id"] == "offer-1" {
				if message["error"] != nil {
					t.Fatal(message["error"])
				}
				answer, _ = message["sdp"].(string)
			}
		case <-deadline:
			t.Fatal("answer timeout")
		}
	}
	count := 0
	for _, line := range strings.Split(answer, "\n") {
		if strings.HasPrefix(line, "a=candidate:") {
			fields := strings.Fields(line)
			if len(fields) < 5 || fields[4] != "127.0.0.1" {
				t.Fatalf("non-loopback candidate: %s", line)
			}
			count++
		}
	}
	if count == 0 {
		t.Fatal("missing loopback candidate")
	}
	if err = browser.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); err != nil {
		t.Fatal(err)
	}
	ticker := time.NewTicker(30 * time.Millisecond)
	defer ticker.Stop()
	timeout := time.After(10 * time.Second)
	videoReceived, touchCancelled := false, false
	for {
		select {
		case <-ticker.C:
			b.mu.Lock()
			track := b.tracks["phone-1"]
			b.mu.Unlock()
			if track != nil {
				_ = track.WriteSample(media.Sample{Data: []byte{0, 0, 0, 1, 0x65, 0x88, 0x84, 0}, Duration: time.Second / 30})
			}
		case message := <-messages:
			if message["event"] == "touch" {
				if message["peer"] != "peer-1" || message["device"] != nil {
					t.Fatalf("untrusted touch binding: %+v", message)
				}
				b.touchResult(command{Op: "touch_result", Peer: "peer-1", TouchID: message["touch_id"].(string), Accepted: true})
			}
			if message["event"] == "touch_cancel" && message["peer"] == "peer-1" {
				touchCancelled = true
			}
		case <-received:
			videoReceived = true
		case <-timeout:
			t.Fatalf("incomplete loopback: video=%v, touchCancellation=%v", videoReceived, touchCancelled)
		}
		if videoReceived && touchCancelled {
			b.close("peer-1")
			b.mu.Lock()
			peers, tracks := len(b.peers), len(b.tracks)
			b.mu.Unlock()
			if peers != 0 || tracks != 0 {
				t.Fatalf("peer cleanup leaked: %d peers, %d tracks", peers, tracks)
			}
			return
		}
	}
}

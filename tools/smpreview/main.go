// smpreview carries H264 over local DTLS/SRTP. Signaling and video input use
// the parent app's private stdio pipes. Touch uses an ordered data channel;
// the parent app authorizes every input against the peer's bound device.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

type command struct {
	ID       string  `json:"id"`
	Op       string  `json:"op"`
	Device   string  `json:"device"`
	Peer     string  `json:"peer"`
	SDP      string  `json:"sdp"`
	Data     string  `json:"data"`
	Duration float64 `json:"duration"`
	TouchID  string  `json:"touch_id"`
	Accepted bool    `json:"accepted"`
	Error    string  `json:"error"`
}

type peer struct {
	connection *webrtc.PeerConnection
	device     string
	touch      *touchPeer
}
type bridge struct {
	output   io.Writer
	mu       sync.Mutex
	outputMu sync.Mutex
	api      *webrtc.API
	tracks   map[string]*webrtc.TrackLocalStaticSample
	peers    map[string]peer
}

func (b *bridge) emit(value map[string]any) {
	b.outputMu.Lock()
	defer b.outputMu.Unlock()
	_ = json.NewEncoder(b.output).Encode(value)
}
func (b *bridge) fail(id string, err error) { b.emit(map[string]any{"id": id, "error": err.Error()}) }

func newBridge() (*bridge, error) {
	engine := &webrtc.MediaEngine{}
	if err := engine.RegisterDefaultCodecs(); err != nil {
		return nil, err
	}
	settings := webrtc.SettingEngine{}
	settings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	settings.SetIncludeLoopbackCandidate(true)
	settings.SetIPFilter(func(ip net.IP) bool { return ip.IsLoopback() })
	settings.SetICETimeouts(5*time.Second, 10*time.Second, 2*time.Second)
	return &bridge{output: os.Stdout, api: webrtc.NewAPI(webrtc.WithMediaEngine(engine), webrtc.WithSettingEngine(settings)), tracks: map[string]*webrtc.TrackLocalStaticSample{}, peers: map[string]peer{}}, nil
}
func (b *bridge) offer(c command) {
	if c.Peer == "" || c.Device == "" || len(c.SDP) > 256*1024 {
		b.fail(c.ID, fmt.Errorf("invalid offer"))
		return
	}
	b.close(c.Peer)
	pc, err := b.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		b.fail(c.ID, err)
		return
	}
	b.mu.Lock()
	if len(b.peers) >= 8 {
		b.mu.Unlock()
		_ = pc.Close()
		b.fail(c.ID, fmt.Errorf("too many preview peers"))
		return
	}
	b.peers[c.Peer] = peer{connection: pc, device: c.Device}
	b.mu.Unlock()
	pc.OnDataChannel(func(channel *webrtc.DataChannel) { b.bindTouch(c.Peer, channel) })
	success := false
	defer func() {
		if !success {
			b.close(c.Peer)
		}
	}()
	b.mu.Lock()
	track := b.tracks[c.Device]
	if track == nil {
		track, err = webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000, SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"}, "screen", c.Device)
		if err == nil {
			b.tracks[c.Device] = track
		}
	}
	b.mu.Unlock()
	if err != nil {
		_ = pc.Close()
		b.fail(c.ID, err)
		return
	}
	sender, err := pc.AddTrack(track)
	if err != nil {
		_ = pc.Close()
		b.fail(c.ID, err)
		return
	}
	go func() {
		for {
			packets, _, err := sender.ReadRTCP()
			if err != nil {
				return
			}
			for _, packet := range packets {
				switch packet.(type) {
				case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
					b.emit(map[string]any{"event": "keyframe", "device": c.Device})
				}
			}
		}
	}()
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		b.emit(map[string]any{"event": "state", "peer": c.Peer, "device": c.Device, "state": state.String()})
		if state == webrtc.PeerConnectionStateConnected {
			b.emit(map[string]any{"event": "keyframe", "device": c.Device})
		}
		if state == webrtc.PeerConnectionStateFailed || state == webrtc.PeerConnectionStateDisconnected {
			go b.close(c.Peer)
		}
	})
	if err = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: c.SDP}); err != nil {
		_ = pc.Close()
		b.fail(c.ID, err)
		return
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		_ = pc.Close()
		b.fail(c.ID, err)
		return
	}
	complete := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(answer); err != nil {
		_ = pc.Close()
		b.fail(c.ID, err)
		return
	}
	select {
	case <-complete:
	case <-time.After(8 * time.Second):
		_ = pc.Close()
		b.fail(c.ID, fmt.Errorf("ICE gathering timed out"))
		return
	}
	success = true
	b.emit(map[string]any{"id": c.ID, "peer_id": c.Peer, "type": "answer", "sdp": pc.LocalDescription().SDP})
}
func (b *bridge) close(id string) {
	b.mu.Lock()
	p, ok := b.peers[id]
	delete(b.peers, id)
	remaining := false
	for _, other := range b.peers {
		if other.device == p.device {
			remaining = true
			break
		}
	}
	if ok && !remaining {
		delete(b.tracks, p.device)
	}
	if ok && p.touch != nil && p.touch.timer != nil {
		p.touch.timer.Stop()
	}
	b.mu.Unlock()
	if ok {
		_ = p.connection.Close()
		b.emit(map[string]any{"event": "closed", "peer": id, "device": p.device})
	}
}
func (b *bridge) sample(c command) {
	b.mu.Lock()
	track := b.tracks[c.Device]
	b.mu.Unlock()
	if track == nil {
		return
	}
	data, err := base64.StdEncoding.DecodeString(c.Data)
	if err != nil {
		return
	}
	duration := time.Duration(c.Duration * float64(time.Second))
	if duration <= 0 || duration > time.Second {
		duration = time.Second / 30
	}
	_ = track.WriteSample(media.Sample{Data: data, Duration: duration})
}
func main() {
	b, err := newBridge()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		var c command
		if json.Unmarshal(scanner.Bytes(), &c) != nil {
			continue
		}
		switch c.Op {
		case "offer":
			go b.offer(c)
		case "close":
			b.close(c.Peer)
			b.emit(map[string]any{"id": c.ID, "peer_id": c.Peer})
		case "frame":
			b.sample(c)
		case "touch_result":
			b.touchResult(c)
		}
	}
	b.mu.Lock()
	ids := make([]string, 0, len(b.peers))
	for id := range b.peers {
		ids = append(ids, id)
	}
	b.mu.Unlock()
	for _, id := range ids {
		b.close(id)
	}
}

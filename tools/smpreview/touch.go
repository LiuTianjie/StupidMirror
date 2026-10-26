package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"time"

	"github.com/pion/webrtc/v4"
)

const touchChannelLabel = "stupidmirror-touch"

type touchScroll struct {
	DeltaX float64 `json:"delta_x"`
	DeltaY float64 `json:"delta_y"`
}

type touchMessage struct {
	Type       string       `json:"type"`
	Phase      string       `json:"phase"`
	GestureID  string       `json:"gesture_id"`
	Sequence   int64        `json:"seq"`
	X          float64      `json:"x"`
	Y          float64      `json:"y"`
	GeometryID string       `json:"geometry_id,omitempty"`
	Scroll     *touchScroll `json:"scroll,omitempty"`
}
type queuedTouch struct {
	id      string
	message touchMessage
}

type touchSequence struct {
	active  bool
	gesture string
	last    int64
	scroll  bool
	recent  []string
}

func (s *touchSequence) accept(message touchMessage) bool {
	if message.Phase == "down" {
		if s.active || message.Sequence != 0 {
			return false
		}
		for _, id := range s.recent {
			if id == message.GestureID {
				return false
			}
		}
		s.recent = append(s.recent, message.GestureID)
		if len(s.recent) > 64 {
			s.recent = s.recent[1:]
		}
		s.active = true
		s.gesture = message.GestureID
		s.last = 0
		s.scroll = message.Scroll != nil
		return true
	}
	if !s.active || message.GestureID != s.gesture || message.Sequence <= s.last {
		return false
	}
	// Cancellation releases the bound owner regardless of its input type;
	// ordinary samples must never change a touch into a relative gesture.
	if message.Phase != "cancel" && (message.Scroll != nil) != s.scroll {
		return false
	}
	s.last = message.Sequence
	if message.Phase == "up" || message.Phase == "cancel" {
		s.active = false
	}
	return true
}

// Protected by bridge.mu. Only one input may await the parent per peer.
type touchPeer struct {
	channel  *webrtc.DataChannel
	queue    []touchMessage
	inflight *queuedTouch
	counter  uint64
	timer    *time.Timer
	closed   bool
	sequence touchSequence
}

func validTouch(m touchMessage) bool {
	phase := m.Phase == "down" || m.Phase == "move" || m.Phase == "up" || m.Phase == "cancel"
	if m.Scroll != nil {
		for _, delta := range []float64{m.Scroll.DeltaX, m.Scroll.DeltaY} {
			if math.IsNaN(delta) || math.IsInf(delta, 0) || math.Abs(delta) > 1_000_000 {
				return false
			}
		}
		if (m.Phase == "up" || m.Phase == "cancel") && (m.Scroll.DeltaX != 0 || m.Scroll.DeltaY != 0) {
			return false
		}
	}
	return m.Type == "touch" && phase && len(m.GestureID) > 0 && len(m.GestureID) <= 128 &&
		m.Sequence >= 0 && m.Sequence <= 9007199254740991 && len(m.GeometryID) <= 128 &&
		!math.IsNaN(m.X) && !math.IsNaN(m.Y) && m.X >= 0 && m.X <= 1 && m.Y >= 0 && m.Y <= 1
}

func decodeTouch(data []byte) (touchMessage, bool) {
	var message touchMessage
	var fields map[string]json.RawMessage
	if len(data) > 4096 || json.Unmarshal(data, &fields) != nil || json.Unmarshal(data, &message) != nil {
		return message, false
	}
	for _, key := range []string{"type", "phase", "gesture_id", "seq", "x", "y"} {
		if len(fields[key]) == 0 || string(fields[key]) == "null" {
			return message, false
		}
	}
	if raw, exists := fields["scroll"]; exists {
		var scrollFields map[string]json.RawMessage
		if message.Scroll == nil || json.Unmarshal(raw, &scrollFields) != nil {
			return message, false
		}
		for _, key := range []string{"delta_x", "delta_y"} {
			value := bytes.TrimSpace(scrollFields[key])
			if len(value) == 0 || bytes.Equal(value, []byte("null")) {
				return message, false
			}
		}
	}
	return message, validTouch(message)
}

func (b *bridge) bindTouch(id string, channel *webrtc.DataChannel) {
	if channel.Label() != touchChannelLabel || !channel.Ordered() || channel.MaxRetransmits() != nil || channel.MaxPacketLifeTime() != nil {
		_ = channel.Close()
		return
	}
	b.mu.Lock()
	p, exists := b.peers[id]
	if !exists || p.touch != nil {
		b.mu.Unlock()
		_ = channel.Close()
		return
	}
	p.touch = &touchPeer{channel: channel}
	b.peers[id] = p
	b.mu.Unlock()
	channel.OnOpen(func() { _ = channel.SendText(`{"type":"status","ready":true}`) })
	channel.OnClose(func() { b.dropTouch(id, "Touch channel closed") })
	channel.OnError(func(error) { b.dropTouch(id, "Touch channel failed") })
	channel.OnMessage(func(data webrtc.DataChannelMessage) {
		message, valid := decodeTouch(data.Data)
		if !data.IsString || !valid {
			b.dropTouch(id, "Invalid touch message")
			return
		}
		b.enqueueTouch(id, message)
	})
}

func (b *bridge) enqueueTouch(id string, message touchMessage) {
	b.mu.Lock()
	p, exists := b.peers[id]
	if !exists || p.touch == nil || p.touch.closed {
		b.mu.Unlock()
		return
	}
	t := p.touch
	if !t.sequence.accept(message) {
		b.mu.Unlock()
		b.dropTouch(id, "Touch gesture or sequence is stale")
		return
	}
	n := len(t.queue)
	if n > 0 && message.Scroll == nil && t.queue[n-1].Scroll == nil &&
		message.Phase == "move" && t.queue[n-1].Phase == "move" && t.queue[n-1].GestureID == message.GestureID {
		t.queue[n-1] = message
	} else if n < 32 {
		t.queue = append(t.queue, message)
	} else {
		b.mu.Unlock()
		b.dropTouch(id, "Touch queue is full")
		return
	}
	b.dispatchTouchLocked(id, t)
	b.mu.Unlock()
}

func (b *bridge) dispatchTouchLocked(id string, t *touchPeer) {
	if t.closed || t.inflight != nil || len(t.queue) == 0 {
		return
	}
	t.counter++
	work := &queuedTouch{id: fmt.Sprintf("%s:%d", id, t.counter), message: t.queue[0]}
	t.queue = t.queue[1:]
	t.inflight = work
	t.timer = time.AfterFunc(3*time.Second, func() { b.expireTouch(id, work.id) })
	// Emit while holding the peer lock so disconnect cancellation cannot overtake
	// this event. stdout is a private pipe carrying only small input/status data.
	b.emit(map[string]any{"event": "touch", "peer": id, "touch_id": work.id, "touch": work.message})
}

func (b *bridge) expireTouch(id, requestID string) {
	b.dropTouchIf(id, "Touch acknowledgement timed out", requestID)
}

func (b *bridge) touchResult(c command) {
	b.mu.Lock()
	p, exists := b.peers[c.Peer]
	if !exists || p.touch == nil || p.touch.closed || p.touch.inflight == nil || p.touch.inflight.id != c.TouchID {
		b.mu.Unlock()
		return
	}
	t := p.touch
	work := t.inflight
	if t.timer != nil {
		t.timer.Stop()
		t.timer = nil
	}
	t.inflight = nil
	if c.Accepted {
		b.dispatchTouchLocked(c.Peer, t)
	}
	b.mu.Unlock()
	response, _ := json.Marshal(map[string]any{"type": "ack", "gesture_id": work.message.GestureID, "seq": work.message.Sequence, "accepted": c.Accepted, "error": c.Error})
	_ = t.channel.SendText(string(response))
	if !c.Accepted {
		b.dropTouch(c.Peer, "Touch rejected")
	}
}

func (b *bridge) dropTouch(id, reason string) {
	b.dropTouchIf(id, reason, "")
}

func (b *bridge) dropTouchIf(id, reason, requestID string) {
	b.mu.Lock()
	p, exists := b.peers[id]
	if !exists || p.touch == nil || p.touch.closed {
		b.mu.Unlock()
		return
	}
	t := p.touch
	if requestID != "" && (t.inflight == nil || t.inflight.id != requestID) {
		b.mu.Unlock()
		return
	}
	t.closed = true
	t.queue = nil
	t.inflight = nil
	if t.timer != nil {
		t.timer.Stop()
		t.timer = nil
	}
	b.emit(map[string]any{"event": "touch_cancel", "peer": id, "reason": reason})
	b.mu.Unlock()
	_ = t.channel.Close()
}

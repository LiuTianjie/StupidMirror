// Package forward exposes in-tunnel device ports on the Mac's loopback
// interface so ordinary clients (an HTTP client, an SRT receiver) can reach
// them without knowing anything about the tunnel.
package forward

import (
	"context"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/LiuTianjie/StupidMirror/tools/smtunnel/internal/utun"
)

// Mapping describes one published loopback port.
type Mapping struct {
	Protocol   string `json:"proto"`
	DevicePort int    `json:"devicePort"`
	LocalPort  int    `json:"localPort"`
}

// TCP listens on 127.0.0.1 (an ephemeral port when localPort is 0) and proxies
// every accepted connection to devicePort inside the tunnel.
func TCP(tunnel *utun.Tunnel, devicePort, localPort int) (Mapping, func() error, error) {
	listener, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", localPort))
	if err != nil {
		return Mapping{}, nil, err
	}
	go func() {
		for {
			client, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				remote, err := tunnel.DialTCP(ctx, devicePort)
				cancel()
				if err != nil {
					client.Close()
					return
				}
				utun.Pipe(client, remote)
			}()
		}
	}()
	return Mapping{
		Protocol:   "tcp",
		DevicePort: devicePort,
		LocalPort:  listener.Addr().(*net.TCPAddr).Port,
	}, listener.Close, nil
}

const udpIdleTimeout = 90 * time.Second

// UDP binds a loopback UDP socket and relays datagrams to devicePort inside
// the tunnel. Each local sender gets its own in-tunnel socket so replies find
// their way back to the right client.
func UDP(tunnel *utun.Tunnel, devicePort, localPort int) (Mapping, func() error, error) {
	local, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: localPort})
	if err != nil {
		return Mapping{}, nil, err
	}
	relay := &udpRelay{tunnel: tunnel, local: local, devicePort: devicePort, flows: map[string]*udpFlow{}, done: make(chan struct{})}
	go relay.run()
	return Mapping{
		Protocol:   "udp",
		DevicePort: devicePort,
		LocalPort:  local.LocalAddr().(*net.UDPAddr).Port,
	}, relay.close, nil
}

type udpRelay struct {
	tunnel     *utun.Tunnel
	local      *net.UDPConn
	devicePort int
	mu         sync.Mutex
	flows      map[string]*udpFlow
	done       chan struct{}
	closeOnce  sync.Once
}

type udpFlow struct {
	remote   net.Conn
	lastSeen time.Time
}

func (r *udpRelay) run() {
	go r.reap()
	buffer := make([]byte, 65535)
	for {
		n, client, err := r.local.ReadFromUDP(buffer)
		if err != nil {
			return
		}
		flow, err := r.flow(client)
		if err != nil {
			continue
		}
		if _, err := flow.remote.Write(buffer[:n]); err != nil {
			r.drop(client.String())
		}
	}
}

func (r *udpRelay) flow(client *net.UDPAddr) (*udpFlow, error) {
	key := client.String()
	r.mu.Lock()
	defer r.mu.Unlock()
	if flow, ok := r.flows[key]; ok {
		flow.lastSeen = time.Now()
		return flow, nil
	}
	remote, err := r.tunnel.DialUDP(r.devicePort)
	if err != nil {
		return nil, err
	}
	flow := &udpFlow{remote: remote, lastSeen: time.Now()}
	r.flows[key] = flow
	go func() {
		buffer := make([]byte, 65535)
		for {
			n, err := remote.Read(buffer)
			if err != nil {
				r.drop(key)
				return
			}
			r.mu.Lock()
			flow.lastSeen = time.Now()
			r.mu.Unlock()
			if _, err := r.local.WriteToUDP(buffer[:n], client); err != nil {
				r.drop(key)
				return
			}
		}
	}()
	return flow, nil
}

func (r *udpRelay) drop(key string) {
	r.mu.Lock()
	flow, ok := r.flows[key]
	delete(r.flows, key)
	r.mu.Unlock()
	if ok {
		flow.remote.Close()
	}
}

func (r *udpRelay) reap() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-r.done:
			return
		case <-ticker.C:
		}
		r.mu.Lock()
		var stale []string
		for key, flow := range r.flows {
			if time.Since(flow.lastSeen) > udpIdleTimeout {
				stale = append(stale, key)
			}
		}
		r.mu.Unlock()
		for _, key := range stale {
			r.drop(key)
		}
	}
}

func (r *udpRelay) close() error {
	r.closeOnce.Do(func() { close(r.done) })
	err := r.local.Close()
	r.mu.Lock()
	flows := r.flows
	r.flows = map[string]*udpFlow{}
	r.mu.Unlock()
	for _, flow := range flows {
		flow.remote.Close()
	}
	return err
}

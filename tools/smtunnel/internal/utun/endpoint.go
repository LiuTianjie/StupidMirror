package utun

import (
	"context"
	"sync"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

const outboundQueueLength = 1024

// linkEndpoint bridges the device packet stream and the gVisor network stack.
// Inbound packets read from the device are injected into the stack; outbound
// packets the stack produces are written back to the device.
type linkEndpoint struct {
	*channel.Endpoint
	stream *packetStream
	mtu    int
	once   sync.Once
	done   chan struct{}
	err    error
	errMu  sync.Mutex
}

func newLinkEndpoint(stream *packetStream, mtu uint32) *linkEndpoint {
	return &linkEndpoint{
		Endpoint: channel.New(outboundQueueLength, mtu, ""),
		stream:   stream,
		mtu:      int(mtu),
		done:     make(chan struct{}),
	}
}

// Attach starts the two pump loops once the stack attaches a dispatcher.
func (e *linkEndpoint) Attach(dispatcher stack.NetworkDispatcher) {
	e.Endpoint.Attach(dispatcher)
	e.once.Do(func() {
		ctx, cancel := context.WithCancel(context.Background())
		var pumps sync.WaitGroup
		pumps.Add(2)
		go func() {
			defer pumps.Done()
			e.outbound(ctx)
		}()
		go func() {
			defer pumps.Done()
			defer cancel()
			e.inbound()
		}()
		go func() {
			pumps.Wait()
			close(e.done)
		}()
	})
}

// Done is closed once the data plane has stopped for any reason.
func (e *linkEndpoint) Done() <-chan struct{} { return e.done }

// Err reports why the data plane stopped, or nil when it is still running or
// was closed deliberately.
func (e *linkEndpoint) Err() error {
	e.errMu.Lock()
	defer e.errMu.Unlock()
	return e.err
}

func (e *linkEndpoint) setErr(err error) {
	e.errMu.Lock()
	defer e.errMu.Unlock()
	if e.err == nil {
		e.err = err
	}
}

func (e *linkEndpoint) inbound() {
	for {
		packet, err := e.stream.ReadPacket(e.mtu)
		if err != nil {
			e.setErr(err)
			return
		}
		if !e.IsAttached() {
			continue
		}
		pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
			Payload: buffer.MakeWithData(packet),
		})
		e.InjectInbound(header.IPv6ProtocolNumber, pkt)
		pkt.DecRef()
	}
}

func (e *linkEndpoint) outbound(ctx context.Context) {
	for {
		pkt := e.ReadContext(ctx)
		if pkt == nil {
			return
		}
		buf := pkt.ToBuffer()
		packet := buf.Flatten()
		buf.Release()
		pkt.DecRef()
		if err := e.stream.WritePacket(packet); err != nil {
			e.setErr(err)
			return
		}
	}
}

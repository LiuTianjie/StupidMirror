// Package utun carries a CoreDevice tunnel over an ordinary TCP stream using an
// in-process IPv6 network stack. Nothing here touches kernel interfaces, so no
// elevated privileges are needed.
package utun

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// DefaultRequestedMTU is asked for in the handshake. The device may grant less.
const DefaultRequestedMTU = 16000

// Tunnel is a live CoreDevice tunnel: an in-process network stack whose single
// interface is the stream to the device.
type Tunnel struct {
	Parameters Parameters
	DeviceIP   net.IP

	stack    *stack.Stack
	nic      tcpip.NICID
	endpoint *linkEndpoint
	stream   *packetStream

	closeOnce sync.Once
	closed    bool
	closeMu   sync.Mutex
}

// Open runs the handshake on a CoreDeviceProxy stream and brings up the stack.
func Open(conn io.ReadWriteCloser, requestedMTU int) (*Tunnel, error) {
	parameters, err := Handshake(conn, requestedMTU)
	if err != nil {
		conn.Close()
		return nil, err
	}
	clientIP := net.ParseIP(parameters.ClientParameters.Address)
	deviceIP := net.ParseIP(parameters.ServerAddress)
	if clientIP == nil || deviceIP == nil {
		conn.Close()
		return nil, fmt.Errorf("handshake returned unusable addresses %q / %q", parameters.ClientParameters.Address, parameters.ServerAddress)
	}

	stream := newPacketStream(conn)
	mtu := uint32(parameters.ClientParameters.MTU)
	endpoint := newLinkEndpoint(stream, mtu)
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	nic := tcpip.NICID(s.UniqueID())
	if tcpErr := s.CreateNIC(nic, endpoint); tcpErr != nil {
		conn.Close()
		return nil, fmt.Errorf("create interface: %v", tcpErr)
	}
	address := tcpip.AddrFromSlice(clientIP.To16()).WithPrefix()
	address.PrefixLen = 64
	if tcpErr := s.AddProtocolAddress(nic, tcpip.ProtocolAddress{
		Protocol:          ipv6.ProtocolNumber,
		AddressWithPrefix: address,
	}, stack.AddressProperties{}); tcpErr != nil {
		conn.Close()
		return nil, fmt.Errorf("assign tunnel address: %v", tcpErr)
	}
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv6EmptySubnet, NIC: nic}})

	return &Tunnel{
		Parameters: parameters,
		DeviceIP:   deviceIP,
		stack:      s,
		nic:        nic,
		endpoint:   endpoint,
		stream:     stream,
	}, nil
}

// Done is closed when the tunnel's data plane stops, whether because Close was
// called or because the connection to the device broke.
func (t *Tunnel) Done() <-chan struct{} { return t.endpoint.Done() }

// Err explains an unexpected data-plane stop; nil after a deliberate Close.
func (t *Tunnel) Err() error {
	t.closeMu.Lock()
	closed := t.closed
	t.closeMu.Unlock()
	if closed {
		return nil
	}
	return t.endpoint.Err()
}

// RSDPort is the device's RemoteServiceDiscovery port inside the tunnel.
func (t *Tunnel) RSDPort() int { return int(t.Parameters.ServerRSDPort) }

func (t *Tunnel) deviceAddress(port int) tcpip.FullAddress {
	return tcpip.FullAddress{
		NIC:  t.nic,
		Addr: tcpip.AddrFromSlice(t.DeviceIP.To16()),
		Port: uint16(port),
	}
}

// DialTCP opens a TCP connection to the device's in-tunnel address.
func (t *Tunnel) DialTCP(ctx context.Context, port int) (net.Conn, error) {
	conn, err := gonet.DialContextTCP(ctx, t.stack, t.deviceAddress(port), ipv6.ProtocolNumber)
	if err != nil {
		return nil, fmt.Errorf("dial [%s]:%d through the tunnel: %w", t.DeviceIP, port, err)
	}
	return conn, nil
}

// DialUDP opens a connected UDP socket to the device's in-tunnel address.
func (t *Tunnel) DialUDP(port int) (*gonet.UDPConn, error) {
	remote := t.deviceAddress(port)
	conn, err := gonet.DialUDP(t.stack, nil, &remote, ipv6.ProtocolNumber)
	if err != nil {
		return nil, fmt.Errorf("dial udp [%s]:%d through the tunnel: %w", t.DeviceIP, port, err)
	}
	return conn, nil
}

// Close tears down the stack and the stream to the device.
func (t *Tunnel) Close() error {
	var err error
	t.closeOnce.Do(func() {
		t.closeMu.Lock()
		t.closed = true
		t.closeMu.Unlock()
		err = t.stream.Close()
		t.stack.Close()
	})
	return err
}

// ServeRelay accepts go-ios style relay connections on listener: each client
// first sends a 16-byte IPv6 address and a 4-byte little-endian port, then the
// bytes that follow are proxied to that in-tunnel endpoint. go-ios' own service
// clients (RemoteServiceDiscovery, testmanagerd, appservice) dial this way when
// a device entry is marked as using a userspace tunnel.
func (t *Tunnel) ServeRelay(listener net.Listener) {
	for {
		client, err := listener.Accept()
		if err != nil {
			return
		}
		go t.serveRelayClient(client)
	}
}

func (t *Tunnel) serveRelayClient(client net.Conn) {
	defer client.Close()
	preamble := make([]byte, 20)
	if _, err := io.ReadFull(client, preamble); err != nil {
		return
	}
	port := int(binary.LittleEndian.Uint32(preamble[16:20]))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	remote, err := t.DialTCP(ctx, port)
	cancel()
	if err != nil {
		return
	}
	Pipe(client, remote)
}

// Pipe copies in both directions until either side ends, then closes both.
func Pipe(a, b io.ReadWriteCloser) {
	var once sync.Once
	closeBoth := func() {
		once.Do(func() {
			a.Close()
			b.Close()
		})
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(a, b)
		closeBoth()
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(b, a)
		closeBoth()
	}()
	wg.Wait()
}

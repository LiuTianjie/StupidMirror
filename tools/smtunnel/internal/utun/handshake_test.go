package utun

import (
	"bytes"
	"encoding/binary"
	"io"
	"testing"
)

// fakeStream answers the handshake with a canned device response and records
// what the client sent.
type fakeStream struct {
	sent     bytes.Buffer
	response bytes.Buffer
}

func (f *fakeStream) Read(p []byte) (int, error)  { return f.response.Read(p) }
func (f *fakeStream) Write(p []byte) (int, error) { return f.sent.Write(p) }

func TestHandshakeExchangesCDTunnelFrames(t *testing.T) {
	stream := &fakeStream{}
	body := `{"clientParameters":{"address":"fd82:a74c:d7b8::2","netmask":"ffff:ffff:ffff:ffff::","mtu":16000},"serverAddress":"fd82:a74c:d7b8::1","serverRSDPort":62029,"type":"serverHandshakeResponse"}`
	stream.response.WriteString(handshakeMagic)
	stream.response.WriteByte(byte(len(body)))
	stream.response.WriteString(body)

	parameters, err := Handshake(stream, 16000)
	if err != nil {
		t.Fatalf("handshake failed: %v", err)
	}
	if parameters.ServerAddress != "fd82:a74c:d7b8::1" || parameters.ServerRSDPort != 62029 {
		t.Fatalf("unexpected server parameters: %+v", parameters)
	}
	if parameters.ClientParameters.Address != "fd82:a74c:d7b8::2" || parameters.ClientParameters.MTU != 16000 {
		t.Fatalf("unexpected client parameters: %+v", parameters.ClientParameters)
	}

	sent := stream.sent.Bytes()
	if !bytes.HasPrefix(sent, []byte(handshakeMagic)) {
		t.Fatalf("request does not start with the CDTunnel magic: %q", sent)
	}
	length := int(sent[len(handshakeMagic)])
	request := sent[len(handshakeMagic)+1:]
	if len(request) != length {
		t.Fatalf("length byte %d does not match request body of %d bytes", length, len(request))
	}
	if !bytes.Contains(request, []byte(`"clientHandshakeRequest"`)) || !bytes.Contains(request, []byte(`"mtu":16000`)) {
		t.Fatalf("unexpected request body: %s", request)
	}
}

func TestHandshakeRejectsAForeignMagic(t *testing.T) {
	stream := &fakeStream{}
	stream.response.WriteString("NOTATUNNEL\x00")
	if _, err := Handshake(stream, 1280); err == nil {
		t.Fatal("expected an error for a foreign handshake header")
	}
}

type packetSource struct {
	bytes.Buffer
}

func (p *packetSource) Close() error { return nil }

func ipv6Packet(payloadLength int, fill byte) []byte {
	packet := make([]byte, ipv6HeaderLength+payloadLength)
	packet[0] = 6 << 4
	binary.BigEndian.PutUint16(packet[4:6], uint16(payloadLength))
	for i := ipv6HeaderLength; i < len(packet); i++ {
		packet[i] = fill
	}
	return packet
}

func TestPacketStreamSplitsCoalescedPackets(t *testing.T) {
	source := &packetSource{}
	first := ipv6Packet(10, 0xAA)
	second := ipv6Packet(3, 0xBB)
	source.Write(first)
	source.Write(second)
	stream := newPacketStream(source)

	got, err := stream.ReadPacket(1500)
	if err != nil || !bytes.Equal(got, first) {
		t.Fatalf("first packet mismatch (err %v)", err)
	}
	got, err = stream.ReadPacket(1500)
	if err != nil || !bytes.Equal(got, second) {
		t.Fatalf("second packet mismatch (err %v)", err)
	}
	if _, err := stream.ReadPacket(1500); err != io.EOF {
		t.Fatalf("expected EOF after the last packet, got %v", err)
	}
}

func TestPacketStreamRefusesOversizedPackets(t *testing.T) {
	source := &packetSource{}
	source.Write(ipv6Packet(200, 0x01))
	stream := newPacketStream(source)
	if _, err := stream.ReadPacket(100); err == nil {
		t.Fatal("expected an error for a packet larger than the limit")
	}
}

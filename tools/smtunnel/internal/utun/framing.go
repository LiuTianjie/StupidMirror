package utun

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
)

const ipv6HeaderLength = 40

// packetStream re-frames the CoreDeviceProxy byte stream into whole IPv6
// packets. The TCP stream has no packet boundaries, so every Read must gather
// exactly one packet: the fixed header first, then the payload the header's
// length field announces.
type packetStream struct {
	reader *bufio.Reader
	writer io.Writer
	closer io.Closer
}

func newPacketStream(conn io.ReadWriteCloser) *packetStream {
	return &packetStream{reader: bufio.NewReaderSize(conn, 64*1024), writer: conn, closer: conn}
}

// ReadPacket returns one complete IPv6 packet. It allocates per packet so the
// returned slice can be handed to the network stack without copying.
func (s *packetStream) ReadPacket(maxSize int) ([]byte, error) {
	header := make([]byte, ipv6HeaderLength, maxSize)
	if _, err := io.ReadFull(s.reader, header); err != nil {
		return nil, err
	}
	if header[0]>>4 != 6 {
		return nil, fmt.Errorf("not an IPv6 packet (version %d)", header[0]>>4)
	}
	payloadLength := int(binary.BigEndian.Uint16(header[4:6]))
	total := ipv6HeaderLength + payloadLength
	if total > maxSize {
		return nil, fmt.Errorf("packet of %d bytes exceeds the %d byte limit", total, maxSize)
	}
	packet := header[:total]
	if _, err := io.ReadFull(s.reader, packet[ipv6HeaderLength:]); err != nil {
		return nil, err
	}
	return packet, nil
}

// WritePacket sends one IPv6 packet. The device re-frames on its side using
// the IPv6 header length, so a packet per Write is all it needs.
func (s *packetStream) WritePacket(packet []byte) error {
	_, err := s.writer.Write(packet)
	return err
}

func (s *packetStream) Close() error {
	return s.closer.Close()
}

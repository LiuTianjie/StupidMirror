package utun

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

// Parameters is what the device answers to a CoreDeviceProxy handshake: the
// address this side must use inside the tunnel, the MTU it granted, and the
// device's own in-tunnel address with the RemoteServiceDiscovery port.
type Parameters struct {
	ClientParameters struct {
		Address string `json:"address"`
		Netmask string `json:"netmask"`
		MTU     uint64 `json:"mtu"`
	} `json:"clientParameters"`
	ServerAddress string `json:"serverAddress"`
	ServerRSDPort uint64 `json:"serverRSDPort"`
}

const handshakeMagic = "CDTunnel\x00"

// Handshake performs the CoreDeviceProxy client handshake on a freshly started
// `com.apple.internal.devicecompute.CoreDeviceProxy` service stream. After it
// returns, the stream carries bare IPv6 packets in both directions.
func Handshake(stream io.ReadWriter, requestedMTU int) (Parameters, error) {
	request, err := json.Marshal(map[string]any{
		"type": "clientHandshakeRequest",
		"mtu":  requestedMTU,
	})
	if err != nil {
		return Parameters{}, err
	}
	if len(request) > 0xFF {
		return Parameters{}, fmt.Errorf("handshake request of %d bytes does not fit the one-byte length", len(request))
	}
	var frame bytes.Buffer
	frame.WriteString(handshakeMagic)
	frame.WriteByte(byte(len(request)))
	frame.Write(request)
	if _, err := stream.Write(frame.Bytes()); err != nil {
		return Parameters{}, fmt.Errorf("send handshake: %w", err)
	}

	header := make([]byte, len(handshakeMagic)+1)
	if _, err := io.ReadFull(stream, header); err != nil {
		return Parameters{}, fmt.Errorf("read handshake header: %w", err)
	}
	if string(header[:len(handshakeMagic)]) != handshakeMagic {
		return Parameters{}, fmt.Errorf("unexpected handshake magic %q", header[:len(handshakeMagic)])
	}
	body := make([]byte, int(header[len(header)-1]))
	if _, err := io.ReadFull(stream, body); err != nil {
		return Parameters{}, fmt.Errorf("read handshake body: %w", err)
	}
	var parameters Parameters
	if err := json.Unmarshal(body, &parameters); err != nil {
		return Parameters{}, fmt.Errorf("decode handshake body %q: %w", body, err)
	}
	if parameters.ClientParameters.Address == "" || parameters.ServerAddress == "" || parameters.ClientParameters.MTU == 0 {
		return Parameters{}, fmt.Errorf("incomplete handshake response %q", body)
	}
	return parameters, nil
}

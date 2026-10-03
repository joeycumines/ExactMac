module github.com/joeycumines/ExactMac/integration

go 1.27.1

replace github.com/joeycumines/ExactMac => ../

require (
	cloud.google.com/go/longrunning v1.3.0
	github.com/joeycumines/ExactMac v0.0.0-20260725215237-e90e731995ba
	github.com/rivo/uniseg v0.4.7
	google.golang.org/grpc v1.84.0
	google.golang.org/protobuf v1.36.12
)

require (
	golang.org/x/net v0.59.0 // indirect
	golang.org/x/sys v0.48.0 // indirect
	golang.org/x/text v0.42.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260921155816-b14227669459 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260921155816-b14227669459 // indirect
)

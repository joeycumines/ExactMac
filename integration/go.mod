module github.com/joeycumines/ExactMac/integration

go 1.27.2

replace github.com/joeycumines/ExactMac => ../

require (
	cloud.google.com/go/longrunning v1.3.0
	github.com/joeycumines/ExactMac v0.1.0
	github.com/rivo/uniseg v0.4.7
	google.golang.org/grpc v1.84.0
	google.golang.org/protobuf v1.36.12
)

require (
	golang.org/x/net v0.61.0 // indirect
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20261012220534-4341edf3f941 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20261012220534-4341edf3f941 // indirect
)

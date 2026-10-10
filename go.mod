module github.com/joeycumines/ExactMac

go 1.27.1

require (
	cloud.google.com/go/longrunning v1.2.0
	github.com/rivo/uniseg v0.4.7
	golang.org/x/image v0.46.0
	golang.org/x/sys v0.49.0
	golang.org/x/tools v0.50.0
	google.golang.org/genproto/googleapis/api v0.0.0-20260921155816-b14227669459
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260921155816-b14227669459
	google.golang.org/grpc v1.84.0
	google.golang.org/protobuf v1.36.12
)

require (
	github.com/BurntSushi/toml v1.6.0 // indirect
	github.com/KimMachineGun/automemlimit v1.0.0 // indirect
	github.com/dkorunic/betteralign v0.15.1 // indirect
	github.com/google/renameio/v2 v2.0.2 // indirect
	github.com/grailbio/base v0.0.11 // indirect
	github.com/grailbio/grit v0.0.0-20230416231552-d3b81e617b57 // indirect
	github.com/pbnjay/memory v0.0.0-20210728143218-7b4eea64cf58 // indirect
	golang.org/x/exp/typeparams v0.0.0-20260908205506-85c1c2202aba // indirect
	golang.org/x/mod v0.41.0 // indirect
	golang.org/x/net v0.59.0 // indirect
	golang.org/x/sync v0.23.0 // indirect
	golang.org/x/text v0.42.0 // indirect
	honnef.co/go/tools v0.8.1 // indirect
)

tool (
	github.com/dkorunic/betteralign/cmd/betteralign
	github.com/grailbio/grit
	honnef.co/go/tools/cmd/staticcheck
)

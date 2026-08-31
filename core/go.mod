module github.com/agjvrkgj/xiaov2bclient/core

go 1.20

require github.com/metacubex/mihomo v1.19.30

// Keep the exact upstream replacement used by Mihomo v1.19.30. Replace
// directives from dependency modules are not inherited by a consuming module.
replace google.golang.org/protobuf => github.com/metacubex/protobuf-go v0.0.0-20260306035419-7ceee0674686

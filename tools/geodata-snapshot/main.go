// SPDX-License-Identifier: GPL-3.0-only
// Uses the GPL-3.0 MetaCubeX/geo protobuf model and converter implementation.
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"

	"github.com/metacubex/geo/encoding/v2raygeo"
	"github.com/oschwald/maxminddb-golang"
	"google.golang.org/protobuf/proto"
)

type IPGroup struct {
	Code    string   `json:"code"`
	CIDRs   []string `json:"cidrs"`
	Reverse bool     `json:"reverse,omitempty"`
}
type Attribute struct {
	Key  string `json:"key"`
	Kind string `json:"kind"`
	Bool bool   `json:"bool,omitempty"`
	Int  int64  `json:"int,omitempty"`
}
type Domain struct {
	Type       string      `json:"type"`
	Value      string      `json:"value"`
	Attributes []Attribute `json:"attributes,omitempty"`
}
type SiteGroup struct {
	Code    string   `json:"code"`
	Domains []Domain `json:"domains"`
}
type Manifest struct {
	Format         string            `json:"format"`
	Kind           string            `json:"snapshot_kind"`
	MetaBuildEpoch int64             `json:"metadb_build_epoch"`
	Expected       map[string]string `json:"expected_sha256"`
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func hash(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func load(path string) []byte { data, err := os.ReadFile(path); must(err); return data }
func noUnknown(m proto.Message) {
	if len(m.ProtoReflect().GetUnknown()) != 0 {
		panic("unsupported protobuf extension fields")
	}
}
func writeJSON(path string, value any) {
	data, err := json.MarshalIndent(value, "", "  ")
	must(err)
	must(os.WriteFile(path, append(data, '\n'), 0644))
}
func writeGzipJSON(path string, value any) {
	f, err := os.Create(path)
	must(err)
	w, err := gzip.NewWriterLevel(f, gzip.BestCompression)
	must(err)
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	must(encoder.Encode(value))
	must(w.Close())
	must(f.Close())
}
func readGzipJSON(path string, value any) {
	f, err := os.Open(path)
	must(err)
	defer f.Close()
	r, err := gzip.NewReader(f)
	must(err)
	defer r.Close()
	must(json.NewDecoder(r).Decode(value))
}

func dump(input, output string) {
	must(os.MkdirAll(output, 0755))
	ipBytes := load(filepath.Join(input, "GeoIP.dat"))
	siteBytes := load(filepath.Join(input, "GeoSite.dat"))
	metaBytes := load(filepath.Join(input, "geoip.metadb"))
	ips := &v2raygeo.GeoIPList{}
	sites := &v2raygeo.GeoSiteList{}
	must(proto.Unmarshal(ipBytes, ips))
	must(proto.Unmarshal(siteBytes, sites))
	noUnknown(ips)
	noUnknown(sites)
	ipGroups := make([]IPGroup, 0, len(ips.Entry))
	siteGroups := make([]SiteGroup, 0, len(sites.Entry))
	for _, group := range ips.Entry {
		noUnknown(group)
		out := IPGroup{Code: group.CountryCode, Reverse: group.ReverseMatch, CIDRs: make([]string, 0, len(group.Cidr))}
		for _, cidr := range group.Cidr {
			noUnknown(cidr)
			addr, ok := netip.AddrFromSlice(cidr.Ip)
			if !ok {
				panic("invalid IP")
			}
			prefix := netip.PrefixFrom(addr, int(cidr.Prefix))
			if !prefix.IsValid() {
				panic("invalid prefix")
			}
			out.CIDRs = append(out.CIDRs, prefix.String())
		}
		ipGroups = append(ipGroups, out)
	}
	for _, group := range sites.Entry {
		noUnknown(group)
		out := SiteGroup{Code: group.CountryCode, Domains: make([]Domain, 0, len(group.Domain))}
		for _, domain := range group.Domain {
			noUnknown(domain)
			name, ok := v2raygeo.Domain_Type_name[int32(domain.Type)]
			if !ok {
				panic("unknown domain type")
			}
			d := Domain{Type: name, Value: domain.Value}
			for _, attribute := range domain.Attribute {
				noUnknown(attribute)
				a := Attribute{Key: attribute.Key, Kind: "unset"}
				switch v := attribute.TypedValue.(type) {
				case *v2raygeo.Domain_Attribute_BoolValue:
					a.Kind = "bool"
					a.Bool = v.BoolValue
				case *v2raygeo.Domain_Attribute_IntValue:
					a.Kind = "int"
					a.Int = v.IntValue
				case nil:
				default:
					panic("unknown attribute")
				}
				d.Attributes = append(d.Attributes, a)
			}
			out.Domains = append(out.Domains, d)
		}
		siteGroups = append(siteGroups, out)
	}
	reader, err := maxminddb.FromBytes(metaBytes)
	must(err)
	defer reader.Close()
	writeGzipJSON(filepath.Join(output, "geoip.json.gz"), ipGroups)
	writeGzipJSON(filepath.Join(output, "geosite.json.gz"), siteGroups)
	writeJSON(filepath.Join(output, "metadb-metadata.json"), reader.Metadata)
	writeJSON(filepath.Join(output, "manifest.json"), Manifest{Format: "lumaroute-geodata-inputs-v1", Kind: "normalized-editable-inputs-exported-losslessly-from-existing-artifacts", MetaBuildEpoch: int64(reader.Metadata.BuildEpoch), Expected: map[string]string{"GeoIP.dat": hash(ipBytes), "GeoSite.dat": hash(siteBytes), "geoip.metadb": hash(metaBytes)}})
	fmt.Printf("exported %d IP groups and %d domain groups; MetaDB epoch %d\n", len(ipGroups), len(siteGroups), reader.Metadata.BuildEpoch)
}

func rebuild(input, output string) {
	var ipGroups []IPGroup
	var siteGroups []SiteGroup
	var manifest Manifest
	readGzipJSON(filepath.Join(input, "geoip.json.gz"), &ipGroups)
	readGzipJSON(filepath.Join(input, "geosite.json.gz"), &siteGroups)
	must(json.Unmarshal(load(filepath.Join(input, "manifest.json")), &manifest))
	if manifest.Format != "lumaroute-geodata-inputs-v1" {
		panic("unsupported snapshot format")
	}
	ips := &v2raygeo.GeoIPList{}
	sites := &v2raygeo.GeoSiteList{}
	for _, group := range ipGroups {
		entry := &v2raygeo.GeoIP{CountryCode: group.Code, ReverseMatch: group.Reverse}
		for _, cidr := range group.CIDRs {
			prefix, err := netip.ParsePrefix(cidr)
			must(err)
			entry.Cidr = append(entry.Cidr, &v2raygeo.CIDR{Ip: prefix.Addr().AsSlice(), Prefix: uint32(prefix.Bits())})
		}
		ips.Entry = append(ips.Entry, entry)
	}
	for _, group := range siteGroups {
		entry := &v2raygeo.GeoSite{CountryCode: group.Code}
		for _, domain := range group.Domains {
			kind, ok := v2raygeo.Domain_Type_value[domain.Type]
			if !ok {
				panic("unknown domain type")
			}
			d := &v2raygeo.Domain{Type: v2raygeo.Domain_Type(kind), Value: domain.Value}
			for _, attribute := range domain.Attributes {
				a := &v2raygeo.Domain_Attribute{Key: attribute.Key}
				switch attribute.Kind {
				case "bool":
					a.TypedValue = &v2raygeo.Domain_Attribute_BoolValue{BoolValue: attribute.Bool}
				case "int":
					a.TypedValue = &v2raygeo.Domain_Attribute_IntValue{IntValue: attribute.Int}
				case "unset":
				default:
					panic("unknown attribute kind")
				}
				d.Attribute = append(d.Attribute, a)
			}
			entry.Domain = append(entry.Domain, d)
		}
		sites.Entry = append(sites.Entry, entry)
	}
	ipBytes, err := proto.Marshal(ips)
	must(err)
	siteBytes, err := proto.Marshal(sites)
	must(err)
	var meta bytes.Buffer
	must(buildMeta(ips.Entry, &meta, manifest.MetaBuildEpoch))
	must(os.MkdirAll(output, 0755))
	for name, data := range map[string][]byte{"GeoIP.dat": ipBytes, "GeoSite.dat": siteBytes, "geoip.metadb": meta.Bytes()} {
		actual := hash(data)
		must(os.WriteFile(filepath.Join(output, name), data, 0644))
		fmt.Printf("%s %s\n", actual, name)
		if actual != manifest.Expected[name] {
			panic("reconstructed checksum mismatch: " + name)
		}
	}
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: geodata-snapshot dump <existing-data-dir> <input-snapshot-dir> | rebuild <snapshot-dir> <output-dir>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "dump":
		dump(os.Args[2], os.Args[3])
	case "rebuild":
		rebuild(os.Args[2], os.Args[3])
	default:
		panic("unknown operation")
	}
}

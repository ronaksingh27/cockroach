// Copyright 2022 The Cockroach Authors.
//
// Use of this software is governed by the CockroachDB Software License
// included in the /LICENSE file.

// Command sctestgen generates test files for sctest.
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"text/template"

	"github.com/cockroachdb/cockroach/pkg/cli/exit"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var (
	app = cobra.Command{
		Use:  "generate schemachanger data-driven tests",
		Args: cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, arguments []string) error {
			var buf bytes.Buffer
			args.Files = make([]string, len(arguments))
			for i, arg := range arguments {
				args.Files[i] = filepath.Dir(arg)
			}
			if err := templ.Execute(&buf, args); err != nil {
				return err
			}
			var out io.Writer
			if args.out == "" {
				out = os.Stdout
			} else {
				f, err := os.Create(args.out)
				if err != nil {
					return err
				}
				defer func() { _ = f.Close() }()
				out = f
			}
			_, err := out.Write(buf.Bytes())
			return err
		},
	}
	args struct {
		Package string
		Suffix  string
		Factory string
		Tests   []string
		Files   []string
		CCL     bool
		out     string
	}
)

func init() {
	flags := pflag.NewFlagSet("run", pflag.ContinueOnError)
	flags.StringVar(
		&args.Factory, "new-cluster-factory",
		"", "name of factory to use to create a new cluster",
	)
	flags.StringVar(&args.Package, "package", "", "name of the package")
	flags.StringSliceVar(&args.Tests, "tests", nil, "tests to generate")
	flags.StringVar(&args.Suffix, "suffix", "", "tests to generate")
	flags.BoolVar(&args.CCL, "ccl", false, "determines the header")
	flags.StringVar(&args.out, "out", "", "output, stdout if empty")
	app.Flags().AddFlagSet(flags)
}

func main() {
	if err := app.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "%v", err)
		exit.WithCode(exit.UnspecifiedError())
	}

}

var templ = template.Must(template.New("t").Funcs(template.FuncMap{
	"basename": filepath.Base,
}).Parse(`
{{- define "cclHeader" -}}
// Copyright 2022 The Cockroach Authors.
//
// Use of this software is governed by the CockroachDB Software License
// included in the /LICENSE file.
{{- end }}

{{- define "bslHeader" -}}
// Copyright 2022 The Cockroach Authors.
//
// Use of this software is governed by the CockroachDB Software License
// included in the /LICENSE file.
{{- end }}

{{- define "header" }}
{{- if .CCL }}{{ template "cclHeader" }}
{{- else }}{{ template "bslHeader" }}{{ end }}
{{- end }}

{{- template "header" . }}

// Code generated by sctestgen, DO NOT EDIT.

package {{ .Package }}

import (
	"testing"

	"github.com/cockroachdb/cockroach/pkg/sql/schemachanger/sctest"
	"github.com/cockroachdb/cockroach/pkg/util/leaktest"
	"github.com/cockroachdb/cockroach/pkg/util/log"
)
{{ range $a, $test := $.Tests -}}
{{ range $index, $file := $.Files }}
func Test{{ $test }}{{ $.Suffix }}_{{ basename $file }}(t *testing.T) {
	defer leaktest.AfterTest(t)()
	defer log.Scope(t).Close(t)
	const path = "{{ $file }}"
	sctest.{{ $test }}(t, path, {{ $.Factory }})
}
{{ end }}
{{- end -}}
`))

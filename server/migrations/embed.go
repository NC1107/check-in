// Package migrations embeds the SQL migration files so the server can apply them at
// startup without depending on an external migration binary.
package migrations

import "embed"

// Files holds all .sql migration files, applied in lexical filename order.
//
//go:embed *.sql
var Files embed.FS

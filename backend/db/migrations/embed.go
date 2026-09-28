// Package migrations встраивает SQL-файлы миграций в бинарник,
// чтобы для запуска не нужно было копировать папку рядом с ним.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS

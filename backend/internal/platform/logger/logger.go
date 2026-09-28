// Package logger создаёт общий slog-логгер для всех процессов.
package logger

import (
	"io"
	"log/slog"
)

// New возвращает логгер: в dev — читаемый текст, в prod — JSON
// (его удобно собирать и искать по полям).
func New(w io.Writer, level string, json bool) *slog.Logger {
	opts := &slog.HandlerOptions{Level: parseLevel(level)}
	if json {
		return slog.New(slog.NewJSONHandler(w, opts))
	}
	return slog.New(slog.NewTextHandler(w, opts))
}

func parseLevel(level string) slog.Level {
	switch level {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

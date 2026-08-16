package db

import "testing"

// PreviewBody backs the debug dashboard's activity table, which used to render a gif-only
// comment as a blank cell (Body is empty; nothing said a gif was attached instead).
func TestCommentPreviewBody(t *testing.T) {
	mediaID := int64(9)

	t.Run("a body always wins over the media fallback", func(t *testing.T) {
		c := Comment{Body: "nice!", MediaID: &mediaID}
		if got := c.PreviewBody(); got != "nice!" {
			t.Errorf("PreviewBody() = %q, want the body", got)
		}
	})

	t.Run("an empty body with media falls back to GIF", func(t *testing.T) {
		c := Comment{Body: "", MediaID: &mediaID}
		if got := c.PreviewBody(); got != "GIF" {
			t.Errorf("PreviewBody() = %q, want \"GIF\"", got)
		}
	})

	t.Run("an empty body with no media has nothing to fall back to", func(t *testing.T) {
		c := Comment{Body: ""}
		if got := c.PreviewBody(); got != "" {
			t.Errorf("PreviewBody() = %q, want empty", got)
		}
	})
}

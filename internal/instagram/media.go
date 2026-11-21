package instagram

import (
	"cmp"
	"net/url"
	"strings"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"

	"github.com/rcnsh/dmbar/internal/core"
)

// convertMedia lists the attachments of a message's content that the app
// can show, the way upstream's igconv picks their URLs. View-once photos
// and videos are left out, so they stay a placeholder: opening one here
// would show it without Instagram counting the view.
func convertMedia(c slidetypes.MessageContent) []core.Media {
	var out []core.Media
	add := func(m core.Media) {
		// A video needs something to play; anything else needs a picture.
		if m.Kind == core.MediaVideo && m.URL != "" || m.Kind != core.MediaVideo && (m.URL != "" || m.Preview != "") {
			out = append(out, m)
		}
	}
	switch c := c.(type) {
	case *slidetypes.MessageContentImage:
		for _, a := range c.Attachments {
			add(attachment(a, core.MediaImage))
		}
	case *slidetypes.MessageContentVideo:
		for _, a := range c.Videos {
			add(attachment(a, core.MediaVideo))
		}
	case *slidetypes.MessageContentMultiMedia:
		for _, a := range c.Attachments {
			kind := core.MediaImage
			// Upstream doesn't say which a carousel item is either; the
			// typename, a DASH manifest or an .mp4 file give a video away.
			if a != nil && (a.DashManifest != "" || strings.Contains(a.Typename, "Video") || isMP4(a.AttachmentCDNURL)) {
				kind = core.MediaVideo
			}
			add(attachment(a, kind))
		}
	case *slidetypes.MessageContentRavenImage:
		if c.ViewMode == slidetypes.RavenViewModeKeepInChat {
			add(attachment(c.Attachment, core.MediaImage))
		}
	case *slidetypes.MessageContentRavenVideo:
		if c.ViewMode == slidetypes.RavenViewModeKeepInChat {
			add(attachment(c.Attachment, core.MediaVideo))
		}
	case *slidetypes.MessageContentAnimatedMedia:
		for _, a := range c.AnimatedMedia {
			if a == nil {
				continue
			}
			m := core.Media{Kind: core.MediaGIF, Preview: a.PreviewCDNURL, Width: a.PreviewWidth, Height: a.PreviewHeight}
			// The WebP is the animation for stickers; for GIFs it may be
			// missing and the MP4 is the one to play.
			if a.AttachmentWebpURL != "" && (a.IsSticker || a.AttachmentMP4URL == "") {
				m.URL = a.AttachmentWebpURL
				if a.IsSticker {
					m.Kind = core.MediaSticker
				}
			} else if a.AttachmentMP4URL != "" {
				m.Kind, m.URL = core.MediaVideo, a.AttachmentMP4URL
			}
			add(m)
		}
	case *slidetypes.MessageContentSticker:
		add(core.Media{Kind: core.MediaSticker, URL: c.PreviewURL, Width: c.PreviewWidth, Height: c.PreviewHeight})
	}
	return out
}

func attachment(a *slidetypes.Attachment, kind core.MediaKind) core.Media {
	if a == nil {
		return core.Media{}
	}
	m := core.Media{
		Kind:    kind,
		URL:     cmp.Or(a.AttachmentCDNURL, a.AttachmentCDNFallbackURL),
		Preview: cmp.Or(a.PreviewCDNURL, a.PreviewCDNFallbackURL),
		Width:   a.PreviewWidth,
		Height:  a.PreviewHeight,
	}
	if kind == core.MediaImage && m.URL == "" {
		m.URL = m.Preview
	}
	return m
}

// isMP4 reports whether a CDN URL's path names an MP4 file.
func isMP4(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && strings.HasSuffix(strings.ToLower(u.Path), ".mp4")
}

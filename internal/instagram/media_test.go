// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

package instagram

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"

	"github.com/rcnsh/dmbar/internal/core"
)

func TestConvertMedia(t *testing.T) {
	tests := []struct {
		name    string
		content string
		want    []core.Media
	}{
		{
			name: "photos",
			content: `{"__typename": "SlideMessageImageContent", "attachments": [
				{"attachment_cdn_url": "https://cdn.example/full.jpg", "preview_cdn_url": "https://cdn.example/small.jpg", "preview_width": 1080, "preview_height": 1350},
				{"preview_cdn_url": "https://cdn.example/only-preview.jpg"}]}`,
			want: []core.Media{
				{Kind: core.MediaImage, URL: "https://cdn.example/full.jpg", Preview: "https://cdn.example/small.jpg", Width: 1080, Height: 1350},
				{Kind: core.MediaImage, URL: "https://cdn.example/only-preview.jpg", Preview: "https://cdn.example/only-preview.jpg"},
			},
		},
		{
			name: "a photo and a video together",
			content: `{"__typename": "SlideMessageMultiMediaContent", "ordered_photo_video_attachments": [
				{"__typename": "SlideMessagingImageAttachment", "attachment_cdn_url": "https://cdn.example/p.jpg"},
				{"__typename": "SlideMessagingVideoAttachment", "attachment_cdn_url": "https://cdn.example/v.mp4", "preview_cdn_url": "https://cdn.example/v.jpg"}]}`,
			want: []core.Media{
				{Kind: core.MediaImage, URL: "https://cdn.example/p.jpg"},
				{Kind: core.MediaVideo, URL: "https://cdn.example/v.mp4", Preview: "https://cdn.example/v.jpg"},
			},
		},
		{
			name: "a sticker from the animated picker",
			content: `{"__typename": "SlideMessageAnimatedMediaContent", "animated_media": [
				{"is_sticker": true, "attachment_webp_url": "https://cdn.example/s.webp", "attachment_mp4_url": "https://cdn.example/s.mp4", "preview_width": 200, "preview_height": 200}]}`,
			want: []core.Media{{Kind: core.MediaSticker, URL: "https://cdn.example/s.webp", Width: 200, Height: 200}},
		},
		{
			name: "a GIF plays its MP4",
			content: `{"__typename": "SlideMessageAnimatedMediaContent", "animated_media": [
				{"attachment_webp_url": "https://cdn.example/g.webp", "attachment_mp4_url": "https://cdn.example/g.mp4", "preview_cdn_url": "https://cdn.example/g.jpg"}]}`,
			want: []core.Media{{Kind: core.MediaVideo, URL: "https://cdn.example/g.mp4", Preview: "https://cdn.example/g.jpg"}},
		},
		{
			name:    "a view-once photo stays hidden",
			content: `{"__typename": "SlideMessageRavenImageContent", "view_mode": 0, "attachment": {"attachment_cdn_url": "https://cdn.example/secret.jpg"}}`,
		},
		{
			name:    "a photo kept in the chat shows",
			content: `{"__typename": "SlideMessageRavenImageContent", "view_mode": 2, "attachment": {"attachment_cdn_url": "https://cdn.example/kept.jpg"}}`,
			want:    []core.Media{{Kind: core.MediaImage, URL: "https://cdn.example/kept.jpg"}},
		},
		{
			name: "a carousel video known by its file",
			content: `{"__typename": "SlideMessageMultiMediaContent", "ordered_photo_video_attachments": [
				{"attachment_cdn_url": "https://cdn.example/clip.mp4?oe=1", "preview_cdn_url": "https://cdn.example/clip.jpg"}]}`,
			want: []core.Media{{Kind: core.MediaVideo, URL: "https://cdn.example/clip.mp4?oe=1", Preview: "https://cdn.example/clip.jpg"}},
		},
		{
			name:    "a video with only a still is left out, having nothing to play",
			content: `{"__typename": "SlideMessageVideosContent", "videos": [{"preview_cdn_url": "https://cdn.example/v.jpg"}]}`,
		},
		{
			name:    "text has none",
			content: `{"__typename": "SlideMessageText", "text_body": "hi"}`,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var msg slidetypes.Message
			raw := `{"id": "mid.$1", "content_type": "IMAGE", "timestamp_ms": "1767225600000", "content": ` + tt.content + `}`
			if err := json.Unmarshal([]byte(raw), &msg); err != nil {
				t.Fatal(err)
			}
			got, ok := convertMessage(&msg, 1, zerolog.Nop())
			if !ok {
				t.Fatal("message skipped")
			}
			if !reflect.DeepEqual(got.Media, tt.want) {
				t.Errorf("media = %+v, want %+v", got.Media, tt.want)
			}
		})
	}
}

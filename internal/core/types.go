// termeownal — a terminal client for Instagram DMs.
// Copyright (C) 2026 ericliswan
// Modified for dmbar in 2026; its git history has the changes.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// Package core holds dmbar's domain types (taken from termeownal) and the interfaces between
// the app and a chat backend. It imports no other dmbar package.
package core

import "time"

// ThreadID identifies a thread. For Instagram it is the thread key: the other
// user's FBID in a 1:1, or the thread's short ID in a group. The other thread
// IDs Instagram uses stay inside the backend (docs/instagram-ids.md).
type ThreadID int64

// UserID identifies a user. For Instagram it is the FBID.
type UserID int64

// MessageID identifies a message.
type MessageID string

// User is a person, including the logged-in user.
type User struct {
	ID       UserID
	Username string
	Name     string
	// Avatar is the URL of the profile picture, if known. It is signed and
	// expires, so fetch it soon. (Added by dmbar.)
	Avatar string
}

// Thread is a conversation.
type Thread struct {
	ID ThreadID
	// Title is the name to display. The backend fills it in when the
	// service leaves it empty, e.g. with the other person's name in a 1:1.
	Title   string
	IsGroup bool
	// Image is the URL of a group's own picture, if it has one. (Added by
	// dmbar.)
	Image string
	// Members excludes the logged-in user.
	Members      []User
	LastActivity time.Time
	Unread       bool
	// Muted means the user turned off the thread's notifications. Only
	// Snapshot reports it: a ThreadUpdated keeps the known value, and
	// ThreadMuted changes it.
	Muted bool
	// Messages holds the newest messages, oldest first, when the backend
	// returns them with the thread. It may be empty.
	Messages []Message
	// ReadUpTo is how far each member has read, where the backend knows.
	ReadUpTo map[UserID]time.Time
}

// SendState tracks a message the user sent from this client.
type SendState int

// Send states. The zero value is Sent, so messages from a backend need no
// state set.
const (
	Sent SendState = iota
	Sending
	SendFailed
)

// Message is one chat line.
type Message struct {
	ID     MessageID
	Thread ThreadID
	Sender UserID
	At     time.Time
	// Text is empty for non-text messages; show ContentType instead.
	Text        string
	ContentType string
	// OTID is the offline threading ID chosen when sending. The echo of a
	// sent message carries the same OTID, which is how it is matched.
	OTID  string
	State SendState
	// ReplyTo is the message this one replies to; its ID is "" if none.
	ReplyTo Quote
	// Reactions holds at most one reaction per member.
	Reactions []Reaction
	// EditedAt is when Text was last edited; zero if never.
	EditedAt time.Time
	// Unsent means the sender took the message back. Text, ContentType and
	// Reactions are then empty.
	Unsent bool
	// Media holds the photos, videos, GIFs or sticker the message carries,
	// in order. It is empty for text and for media dmbar can't show.
	Media []Media
}

// MediaKind says what a Media is.
type MediaKind string

// Media kinds.
const (
	MediaImage   MediaKind = "image"
	MediaVideo   MediaKind = "video"
	MediaGIF     MediaKind = "gif"
	MediaSticker MediaKind = "sticker"
)

// Media is one attachment the app can show. Its URLs are signed and expire,
// so they are only good until the message is fetched again.
type Media struct {
	Kind MediaKind
	// URL is the full image, or the video or animation; Preview is a still
	// image for it. Either may be "", not both.
	URL     string
	Preview string
	// Width and Height are the preview's size in pixels, 0 if not known.
	Width, Height int
}

// Reaction is a member's reaction to a message.
type Reaction struct {
	User  UserID
	Emoji string
	// ID is the service's ID for the reaction, if it has one. A removal
	// may name only this ID.
	ID string
}

// Quote is the message a reply quotes, as it was when the reply was sent.
// Only ID is set if the service didn't include a copy, e.g. after an unsend.
type Quote struct {
	ID     MessageID
	Sender UserID
	// Text is empty for non-text messages; show ContentType instead.
	Text        string
	ContentType string
}

// AuthData is a backend's saved login: cookies and cached client state. Only
// the backend that produced it reads it. It is secret, so String and GoString
// hide it from fmt and loggers that use them.
type AuthData []byte

// String implements fmt.Stringer without revealing the data.
func (AuthData) String() string { return "[redacted]" }

// GoString implements fmt.GoStringer without revealing the data.
func (AuthData) GoString() string { return "[redacted]" }

// Session is what dmbar saves to resume without logging in again.
type Session struct {
	Auth AuthData
	// SeqID is the last event sequence ID whose events are all in the store,
	// and SeqAt is when it was reached. Zero means none: the backend starts
	// cold.
	SeqID int64
	SeqAt time.Time
}

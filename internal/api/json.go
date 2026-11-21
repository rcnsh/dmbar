// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

package api

import (
	"strconv"
	"time"

	"github.com/rcnsh/dmbar/internal/core"
	"github.com/rcnsh/dmbar/internal/engine"
)

// The wire types. IDs are strings: thread and user IDs are 64-bit and some
// JSON readers lose digits past 2^53. Times are Unix milliseconds, 0 for
// none, which keeps a message's time exact for marking it read.

type userJSON struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Name     string `json:"name"`
	// AvatarURL is empty when unknown.
	AvatarURL string `json:"avatar_url"`
}

type threadJSON struct {
	ID             string           `json:"id"`
	Title          string           `json:"title"`
	IsGroup        bool             `json:"is_group"`
	ImageURL       string           `json:"image_url"`
	Members        []userJSON       `json:"members"`
	LastActivityMS int64            `json:"last_activity_ms"`
	Unread         bool             `json:"unread"`
	Muted          bool             `json:"muted"`
	LastMessage    *messageJSON     `json:"last_message"`
	ReadUpToMS     map[string]int64 `json:"read_up_to_ms"`
}

type messageJSON struct {
	ID          string         `json:"id"`
	ThreadID    string         `json:"thread_id"`
	SenderID    string         `json:"sender_id"`
	AtMS        int64          `json:"at_ms"`
	Text        string         `json:"text"`
	ContentType string         `json:"content_type"`
	OTID        string         `json:"otid"`
	ReplyTo     *quoteJSON     `json:"reply_to"`
	Reactions   []reactionJSON `json:"reactions"`
	EditedAtMS  int64          `json:"edited_at_ms"`
	Unsent      bool           `json:"unsent"`
}

type quoteJSON struct {
	ID          string `json:"id"`
	SenderID    string `json:"sender_id"`
	Text        string `json:"text"`
	ContentType string `json:"content_type"`
}

type reactionJSON struct {
	UserID string `json:"user_id"`
	Emoji  string `json:"emoji"`
	ID     string `json:"id"`
}

type stateJSON struct {
	State   engine.State `json:"state"`
	Error   string       `json:"error"`
	Me      *userJSON    `json:"me"`
	Threads []threadJSON `json:"threads"`
}

type loginStepJSON struct {
	Instructions string           `json:"instructions"`
	Fields       []loginFieldJSON `json:"fields"`
	// Done is true on the final step; Me is then the account.
	Done bool      `json:"done"`
	Me   *userJSON `json:"me"`
}

type loginFieldJSON struct {
	ID       string   `json:"id"`
	Label    string   `json:"label"`
	Secret   bool     `json:"secret"`
	Optional bool     `json:"optional"`
	Options  []string `json:"options"`
}

func id[T ~int64](v T) string { return strconv.FormatInt(int64(v), 10) }

func ms(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}

func toUser(u core.User) userJSON {
	return userJSON{ID: id(u.ID), Username: u.Username, Name: u.Name, AvatarURL: u.Avatar}
}

func toThread(t core.Thread) threadJSON {
	out := threadJSON{
		ID:             id(t.ID),
		Title:          t.Title,
		IsGroup:        t.IsGroup,
		ImageURL:       t.Image,
		Members:        make([]userJSON, len(t.Members)),
		LastActivityMS: ms(t.LastActivity),
		Unread:         t.Unread,
		Muted:          t.Muted,
		ReadUpToMS:     make(map[string]int64, len(t.ReadUpTo)),
	}
	for i, u := range t.Members {
		out.Members[i] = toUser(u)
	}
	for u, at := range t.ReadUpTo {
		out.ReadUpToMS[id(u)] = ms(at)
	}
	if n := len(t.Messages); n > 0 {
		m := toMessage(t.Messages[n-1])
		out.LastMessage = &m
	}
	return out
}

func toMessage(m core.Message) messageJSON {
	out := messageJSON{
		ID:          string(m.ID),
		ThreadID:    id(m.Thread),
		SenderID:    id(m.Sender),
		AtMS:        ms(m.At),
		Text:        m.Text,
		ContentType: m.ContentType,
		OTID:        m.OTID,
		Reactions:   make([]reactionJSON, len(m.Reactions)),
		EditedAtMS:  ms(m.EditedAt),
		Unsent:      m.Unsent,
	}
	if m.ReplyTo.ID != "" {
		out.ReplyTo = &quoteJSON{ID: string(m.ReplyTo.ID), SenderID: id(m.ReplyTo.Sender), Text: m.ReplyTo.Text, ContentType: m.ReplyTo.ContentType}
	}
	for i, r := range m.Reactions {
		out.Reactions[i] = toReaction(r)
	}
	return out
}

func toMessages(msgs []core.Message) []messageJSON {
	out := make([]messageJSON, len(msgs))
	for i, m := range msgs {
		out[i] = toMessage(m)
	}
	return out
}

func toReaction(r core.Reaction) reactionJSON {
	return reactionJSON{UserID: id(r.User), Emoji: r.Emoji, ID: r.ID}
}

func toState(s engine.Snapshot) stateJSON {
	out := stateJSON{State: s.State, Error: s.Error, Threads: make([]threadJSON, len(s.Threads))}
	if s.Me.ID != 0 {
		me := toUser(s.Me)
		out.Me = &me
	}
	for i, t := range s.Threads {
		out.Threads[i] = toThread(t)
	}
	return out
}

func toLoginStep(s core.LoginStep) loginStepJSON {
	out := loginStepJSON{Instructions: s.Instructions, Fields: make([]loginFieldJSON, len(s.Fields))}
	for i, f := range s.Fields {
		out.Fields[i] = loginFieldJSON{ID: f.ID, Label: f.Label, Secret: f.Secret, Optional: f.Optional, Options: append([]string{}, f.Options...)}
	}
	if s.Result != nil {
		me := toUser(s.Result.Me)
		out.Done, out.Me = true, &me
	}
	return out
}

// toEvent returns the SSE event name and body for something the engine
// published, or "" for a value clients aren't told about.
func toEvent(ev any) (string, any) {
	type m = map[string]any
	switch ev := ev.(type) {
	case engine.SnapshotEvent:
		return "state", toState(ev.Snapshot)
	case engine.StatusEvent:
		return "status", m{"state": ev.State, "error": ev.Error}
	case core.MessageAdded:
		return "message_added", m{"message": toMessage(ev.Message)}
	case core.ThreadUpdated:
		return "thread_updated", m{"thread": toThread(ev.Thread)}
	case core.ThreadRead:
		return "thread_read", m{"thread_id": id(ev.Thread), "until_ms": ms(ev.Until)}
	case core.ReadReceipt:
		return "read_receipt", m{"thread_id": id(ev.Thread), "user_id": id(ev.User), "up_to_ms": ms(ev.UpTo)}
	case core.Typing:
		return "typing", m{"thread_id": id(ev.Thread), "user_id": id(ev.User), "active": ev.Active}
	case core.ReactionAdded:
		return "reaction_added", m{"thread_id": id(ev.Thread), "message_id": string(ev.Message), "reaction": toReaction(ev.Reaction)}
	case core.ReactionRemoved:
		return "reaction_removed", m{"thread_id": id(ev.Thread), "message_id": string(ev.Message), "user_id": id(ev.User), "reaction_id": ev.ID}
	case core.MessageEdited:
		return "message_edited", m{"thread_id": id(ev.Thread), "message_id": string(ev.Message), "text": ev.Text, "at_ms": ms(ev.At)}
	case core.MessageUnsent:
		return "message_unsent", m{"thread_id": id(ev.Thread), "message_id": string(ev.Message)}
	case core.ThreadMuted:
		return "thread_muted", m{"thread_id": id(ev.Thread), "muted": ev.Muted}
	}
	return "", nil
}

// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

package fake

import (
	"fmt"
	"time"

	"github.com/rcnsh/dmbar/internal/core"
)

// Demo returns a backend with a made-up inbox, for `dmbard -demo`: the app
// can be built, shown and tested against it with no account and no network.
// Sent messages echo back, and one chat gets a reply a few seconds later.
func Demo() *Backend {
	me := core.User{ID: 1, Username: "you", Name: "You"}
	mara := core.User{ID: 101, Username: "mara.codes", Name: "Mara Lindqvist"}
	theo := core.User{ID: 102, Username: "theo_k", Name: "Theo Kagame"}
	ines := core.User{ID: 103, Username: "ines.draws", Name: "Inès Okafor"}
	sam := core.User{ID: 104, Username: "samwise", Name: "Sam Whitlock"}
	now := time.Now()
	ago := func(d time.Duration) time.Time { return now.Add(-d) }
	n := 0
	msg := func(thread core.ThreadID, from core.User, at time.Time, text string) core.Message {
		n++
		return core.Message{ID: core.MessageID(fmt.Sprintf("demo-%d", n)), Thread: thread, Sender: from.ID, At: at, Text: text, ContentType: "TEXT"}
	}

	maraChat := []core.Message{
		msg(101, mara, ago(26*time.Hour), "did you see the new glass stuff in the beta"),
		msg(101, me, ago(26*time.Hour-2*time.Minute), "yeah it looks unreal on the menu bar"),
		msg(101, mara, ago(25*time.Hour), "I rebuilt my whole settings screen around it"),
		msg(101, me, ago(3*time.Hour), "send a screenshot when it's done"),
		msg(101, mara, ago(12*time.Minute), "ok it's done"),
		{ID: "demo-photo", Thread: 101, Sender: mara.ID, At: ago(11 * time.Minute), ContentType: "IMAGE"},
		msg(101, mara, ago(10*time.Minute), "what do you think? too much blur or just enough"),
	}
	maraChat[2].Reactions = []core.Reaction{{User: me.ID, Emoji: "🔥", ID: "r1"}}
	maraChat[3].ReplyTo = core.Quote{ID: maraChat[2].ID, Sender: mara.ID, Text: maraChat[2].Text, ContentType: "TEXT"}
	// Enough older messages to page through.
	var older []core.Message
	for i := 60; i > 0; i-- {
		from := mara
		if i%3 == 0 {
			from = me
		}
		older = append(older, msg(101, from, ago(48*time.Hour+time.Duration(i)*time.Minute), fmt.Sprintf("older message %d", 61-i)))
	}
	maraChat = append(older, maraChat...)

	group := []core.Message{
		msg(900, theo, ago(5*time.Hour), "saturday still on?"),
		msg(900, ines, ago(4*time.Hour), "yes!! I'll bring the board games"),
		msg(900, me, ago(4*time.Hour-time.Minute), "I'm in. 7pm?"),
		msg(900, sam, ago(95*time.Minute), "7 works. who's on snacks"),
		msg(900, theo, ago(94*time.Minute), "not me, I did it last time"),
	}
	theoChat := []core.Message{
		msg(102, me, ago(30*time.Hour), "running 10 minutes late, sorry"),
		msg(102, theo, ago(30*time.Hour-time.Minute), "no stress, I just got here"),
		msg(102, me, ago(22*time.Hour), "thanks for today, that was fun"),
	}
	inesChat := []core.Message{
		msg(103, ines, ago(3*24*time.Hour), "the print arrived!"),
		{ID: "demo-reel", Thread: 103, Sender: ines.ID, At: ago(2 * 24 * time.Hour), ContentType: "REEL_SHARE"},
	}

	last := func(m []core.Message) []core.Message { return m[len(m)-1:] }
	b := &Backend{
		Me:   me,
		Echo: true,
		Histories: map[core.ThreadID][]core.Message{
			101: maraChat, 900: group, 102: theoChat, 103: inesChat,
		},
		Threads: []core.Thread{
			{ID: 101, Title: mara.Name, Members: []core.User{mara}, LastActivity: ago(10 * time.Minute), Unread: true, Messages: last(maraChat)},
			{ID: 900, Title: "Saturday crew", IsGroup: true, Members: []core.User{theo, ines, sam}, LastActivity: ago(94 * time.Minute), Unread: true, Messages: last(group)},
			{ID: 102, Title: theo.Name, Members: []core.User{theo}, LastActivity: ago(22 * time.Hour), Messages: last(theoChat),
				ReadUpTo: map[core.UserID]time.Time{theo.ID: ago(21 * time.Hour)}},
			{ID: 103, Title: ines.Name, Members: []core.User{ines}, LastActivity: ago(2 * 24 * time.Hour), Muted: true, Messages: last(inesChat)},
		},
	}
	b.init()
	// A little life: Mara types, then writes, after the app has connected.
	go func() {
		select {
		case <-b.done:
			return
		case <-time.After(8 * time.Second):
		}
		b.emit(core.Typing{Thread: 101, User: mara.ID, Active: true})
		select {
		case <-b.done:
			return
		case <-time.After(4 * time.Second):
		}
		m := core.Message{ID: "demo-live", Thread: 101, Sender: mara.ID, At: time.Now(), Text: "also, are you free thursday?", ContentType: "TEXT"}
		b.mu.Lock()
		b.Histories[101] = append(b.Histories[101], m)
		b.mu.Unlock()
		b.emit(core.Typing{Thread: 101, User: mara.ID, Active: false})
		b.emit(core.MessageAdded{Message: m})
	}()
	return b
}

// emit plays ev unless the backend is closed or nobody is reading.
func (b *Backend) emit(ev core.Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return
	}
	select {
	case b.events <- ev:
	default:
	}
}

// DemoSessions returns a store that already holds a login, so the demo
// starts connected.
func DemoSessions() *Sessions {
	return &Sessions{Saved: &core.Session{Auth: core.AuthData("demo")}}
}

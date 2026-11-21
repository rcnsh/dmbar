// dmbar — Instagram DMs in the macOS menu bar.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version. See LICENSE.

package instagram

import (
	"context"
	"fmt"
	"strings"

	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"

	"github.com/rcnsh/dmbar/internal/core"
)

// Cookies logs in with cookies by name, skipping the prompts: what an app
// that ran the login in its own web view has. It needs sessionid, csrftoken
// and ds_user_id; mid, ig_did, rur, shbid and shbts are used if present.
// The returned step has Result set.
func (l *Login) Cookies(ctx context.Context, values map[string]string) (core.LoginStep, error) {
	l.password = nil
	named := make(map[string]string, len(values))
	for name, value := range values {
		if name != pasteField {
			named[name] = value
		}
	}
	var missing []string
	for _, name := range cookies.IGRequiredCookies {
		if strings.TrimSpace(named[string(name)]) == "" {
			missing = append(missing, string(name))
		}
	}
	if len(missing) > 0 {
		return core.LoginStep{}, fmt.Errorf("%w: missing cookies: %s", core.ErrInvalidInput, strings.Join(missing, ", "))
	}
	return l.submitCookies(ctx, named)
}
